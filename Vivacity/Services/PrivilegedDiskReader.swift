import Foundation
import os
import Security

/// Provides privileged read access to raw disk devices.
///
/// - Preferred path: direct `open()`/`pread()` when the device node is readable.
/// - Fallback path: start a privileged `dd` that streams the raw device into a
///   per-run FIFO in `/tmp` (prompting once with the standard macOS password
///   dialog), then read from the FIFO. No device permissions are modified.
///
/// Closing the FIFO causes `dd` to receive SIGPIPE and exit, leaving the system
/// in its original state. This approach works for Developer ID distribution and
/// persistent chmod changes on `/dev/disk*`.
final class PrivilegedDiskReader: PrivilegedDiskReading, @unchecked Sendable {
    private let devicePath: String
    private let privilegedDevicePath: String
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedDiskReader")

    /// Direct or FIFO file descriptor.
    private var fd: Int32 = -1

    /// FIFO-related state
    private var isFifo = false
    private var isXPC = false
    private var fifoPath: String?
    private var ddTaskPID: Int32?
    private var ddDiagnosticLogPath: String?
    private var fifoOffset: UInt64 = 0
    private var hasReadFIFOData = false
    private var lastReadFailure: String?
    private let helperClient = PrivilegedHelperClient()
    private var directReadCount = 0
    private var fifoReadCount = 0
    private var xpcReadCount = 0

    init(devicePath: String) {
        self.devicePath = devicePath
        privilegedDevicePath = Self.preferredPrivilegedDevicePath(for: devicePath)
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Whether the reader currently supports random access (true for direct access, false for FIFO fallback).
    var isSeekable: Bool {
        isXPC || (fd >= 0 && !isFifo)
    }

    var lastReadFailureDescription: String? {
        lastReadFailure
    }

    /// Opens the device for reading, elevating privileges if needed.
    ///
    /// If the device is already readable, uses direct `open()`.
    /// Otherwise, uses AppleScript to temporarily grant read access
    /// to the device node, then opens it normally.
    func start() throws {
        resetReadStateForStart()
        logPrivilegedDeviceSelectionIfNeeded()

        if openDirectAccessIfPossible() {
            return
        }

        // Try XPC privileged helper before FIFO fallback.
        helperClient.prepareForPrivilegedAccess()
        if configureXPCAccessIfAvailable() {
            return
        }

        if let installError = helperClient.lastInstallErrorDescription {
            let reason = "Recovery helper install failed: \(installError)"
            logger.error("\(reason, privacy: .public)")
            throw PrivilegedReadError.cannotStartReader(reason: reason)
        }

        let fallbackMessage =
            "Privileged helper unavailable, falling back to FIFO dd bridge " +
            "device=\(devicePath) privilegedDevice=\(privilegedDevicePath)"
        logger.info("\(fallbackMessage, privacy: .public)")
        try startFIFOBridge()
    }

    /// Reads up to `length` bytes from the device at the given offset.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        if isXPC {
            return performXPCRead(into: buffer, offset: offset, length: length)
        }

        guard fd >= 0 else {
            return logReadBeforeStart(offset: offset, length: length)
        }

        return isFifo
            ? performFIFORead(into: buffer, offset: offset, length: length)
            : performDirectRead(into: buffer, offset: offset, length: length)
    }

    /// Stops the reader, closes the fd, and cleans up the FIFO.
    func stop() {
        let stopMessage =
            "Stopping reader device=\(devicePath) mode=\(readerModeDescription) " +
            "directReads=\(directReadCount) fifoReads=\(fifoReadCount) xpcReads=\(xpcReadCount) " +
            "lastReadFailure=\(lastReadFailure ?? "nil")"
        logger.info("\(stopMessage, privacy: .public)")

        if fd >= 0 {
            close(fd)
            fd = -1
        }

        // Closing the read end of the FIFO causes `dd` to receive SIGPIPE
        // the next time it writes, which terminates it cleanly without
        // needing another root authorization.
        if let pid = ddTaskPID {
            logger.info("Closed FIFO, dd (PID \(pid, privacy: .public)) should terminate via SIGPIPE")
            ddTaskPID = nil
        }

        if let path = fifoPath {
            unlink(path)
            fifoPath = nil
        }

        if let logPath = ddDiagnosticLogPath {
            try? FileManager.default.removeItem(atPath: logPath)
            ddDiagnosticLogPath = nil
        }

        isXPC = false
        hasReadFIFOData = false
        fifoOffset = 0
        lastReadFailure = nil
    }

    // MARK: - FIFO Diagnostics

    private func waitForFIFOWriterData(maxRetries: Int) -> Bool {
        guard let pid = ddTaskPID else { return false }
        for _ in 0 ..< maxRetries {
            if kill(pid, 0) != 0 {
                return false
            }
            usleep(50000) // 50ms
        }
        return kill(pid, 0) == 0
    }

    @discardableResult
    private func logFIFOEOF() -> String {
        let pidState: String = if let pid = ddTaskPID {
            kill(pid, 0) == 0 ? "alive(\(pid))" : "dead(\(pid))"
        } else {
            "none"
        }

        var ddStderrTail = "unavailable"
        if let logPath = ddDiagnosticLogPath,
           let data = FileManager.default.contents(atPath: logPath),
           let content = String(data: data, encoding: .utf8),
           !content.isEmpty
        {
            let lines = content.split(separator: "\n")
            ddStderrTail = lines.suffix(3).joined(separator: " | ")
        }

        logger.error(
            "FIFO EOF (pid=\(pidState, privacy: .public), dd-stderr=\(ddStderrTail, privacy: .public))"
        )
        return "FIFO EOF (pid=\(pidState), dd-stderr=\(ddStderrTail))"
    }

    private var readerModeDescription: String {
        if isXPC {
            "xpc"
        } else if isFifo {
            "fifo"
        } else if fd >= 0 {
            "direct"
        } else {
            "stopped"
        }
    }

    private func shouldLogSuccessfulRead(count: Int) -> Bool {
        count <= 3 || count.isMultiple(of: 128)
    }

    private static func describeErrno(_ err: Int32) -> String {
        "errno=\(err) message=\(String(cString: strerror(err)))"
    }

    private static func userContextDescription() -> String {
        "uid=\(getuid()) euid=\(geteuid()) gid=\(getgid()) egid=\(getegid())"
    }

    static func preferredPrivilegedDevicePath(
        for devicePath: String,
        diskInfoProvider: (String) -> [String: Any]? = diskutilInfoPlist(for:)
    ) -> String {
        guard let rawPath = rawDevicePath(for: devicePath) else { return devicePath }

        guard let diskInfo = diskInfoProvider(devicePath),
              shouldPreferAPFSContainer(for: diskInfo),
              let containerReference = diskInfo["APFSContainerReference"] as? String,
              !containerReference.isEmpty
        else {
            return rawPath
        }

        let containerDevicePath = "/dev/\(containerReference)"
        return rawDevicePath(for: containerDevicePath) ?? containerDevicePath
    }

    private static func rawDevicePath(for devicePath: String) -> String? {
        if devicePath.hasPrefix("/dev/rdisk") {
            return devicePath
        }
        if devicePath.hasPrefix("/dev/disk") {
            return devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        }
        return nil
    }

    private static func shouldPreferAPFSContainer(for diskInfo: [String: Any]) -> Bool {
        guard (diskInfo["FilesystemType"] as? String) == "apfs" else { return false }

        if (diskInfo["APFSSnapshot"] as? Bool) == true {
            return true
        }

        let mountPoint = diskInfo["MountPoint"] as? String
        return mountPoint == "/System/Volumes/Data" &&
            (diskInfo["Internal"] as? Bool ?? false) &&
            (diskInfo["FileVault"] as? Bool ?? false) &&
            (diskInfo["Bootable"] as? Bool ?? false)
    }

    private static func diskutilInfoPlist(for path: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let plistData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any]
        else {
            return nil
        }
        return dict
    }
}

extension PrivilegedDiskReader {
    private func resetReadStateForStart() {
        lastReadFailure = nil
        directReadCount = 0
        fifoReadCount = 0
        xpcReadCount = 0
    }

    private func logPrivilegedDeviceSelectionIfNeeded() {
        let defaultPrivilegedDevice = Self.rawDevicePath(for: devicePath) ?? devicePath
        guard privilegedDevicePath != defaultPrivilegedDevice else { return }

        let remapMessage =
            "Privileged device remapped for raw access " +
            "device=\(devicePath) privilegedDevice=\(privilegedDevicePath)"
        logger.info("\(remapMessage, privacy: .public)")
    }

    private func openDirectAccessIfPossible() -> Bool {
        let directFd = open(devicePath, O_RDONLY)
        if directFd >= 0 {
            fd = directFd
            isXPC = false
            let successMessage =
                "Direct read access established device=\(devicePath) " +
                "mode=direct user=\(Self.userContextDescription())"
            logger.info("\(successMessage, privacy: .public)")
            return true
        }

        let directFailureMessage =
            "Direct open failed device=\(devicePath) " +
            "\(Self.describeErrno(errno)) user=\(Self.userContextDescription())"
        logger.info("\(directFailureMessage, privacy: .public)")
        return false
    }

    private func configureXPCAccessIfAvailable() -> Bool {
        let helperAvailable = helperClient.isAvailable()
        let helperInstallError = helperClient.lastInstallErrorDescription ?? "nil"
        let helperDecisionMessage =
            "Privileged access probe device=\(devicePath) privilegedDevice=\(privilegedDevicePath) " +
            "helperAvailable=\(helperAvailable) " +
            "lastInstallError=\(helperInstallError)"
        logger.info("\(helperDecisionMessage, privacy: .public)")
        guard helperAvailable else { return false }

        isXPC = true
        isFifo = false
        fifoOffset = 0
        hasReadFIFOData = false
        let xpcMessage =
            "Using privileged helper XPC service for \(devicePath) " +
            "privilegedDevice=\(privilegedDevicePath) mode=xpc"
        logger.info("\(xpcMessage, privacy: .public)")
        return true
    }

    private func startFIFOBridge() throws {
        let uuid = UUID().uuidString
        let path = "/tmp/vivacity_reader_\(uuid).pipe"
        let ddLogPath = "/tmp/vivacity_reader_\(uuid).dd.log"

        try createFIFO(at: path)
        configureFIFOState(path: path, ddLogPath: ddLogPath)
        try launchPrivilegedDD(path: path, ddLogPath: ddLogPath)
        try openFIFOForReading(path: path)
    }

    private func createFIFO(at path: String) throws {
        if mkfifo(path, 0o600) != 0 {
            let mkfifoErr = String(cString: strerror(errno))
            throw PrivilegedReadError.cannotStartReader(reason: "Failed to create FIFO: \(mkfifoErr)")
        }
    }

    private func configureFIFOState(path: String, ddLogPath: String) {
        fifoPath = path
        isFifo = true
        isXPC = false
        ddDiagnosticLogPath = ddLogPath
        fifoOffset = 0
        hasReadFIFOData = false
    }

    private func launchPrivilegedDD(path: String, ddLogPath: String) throws {
        let script = """
        do shell script "dd if=\(privilegedDevicePath) of=\(
            path
        ) bs=131072 2>\(ddLogPath) & echo $!" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        guard let output = appleScript?.executeAndReturnError(&errorDict) else {
            unlink(path)
            let errorMessage = errorDict?[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            logger.error("Failed to start privileged dd task: \(errorMessage, privacy: .public)")
            throw PrivilegedReadError.cannotStartReader(reason: errorMessage)
        }

        if let pidString = output.stringValue, let pid = Int32(pidString) {
            ddTaskPID = pid
            logger.info("FIFO dd started pid=\(pid, privacy: .public) log=\(ddLogPath, privacy: .public)")
        }
    }

    private func openFIFOForReading(path: String) throws {
        let newFd = open(path, O_RDONLY | O_NONBLOCK)
        guard newFd >= 0 else {
            let openErr = String(cString: strerror(errno))
            unlink(path)
            logger.error(
                "Cannot open internal FIFO \(path, privacy: .public): \(openErr, privacy: .public)"
            )
            throw PrivilegedReadError.cannotStartReader(reason: "Cannot open internal FIFO: \(openErr)")
        }

        let flags = fcntl(newFd, F_GETFL, 0)
        _ = fcntl(newFd, F_SETFL, flags & ~O_NONBLOCK)

        fd = newFd
        let fifoOpenMessage =
            "Device opened successfully for deep scan device=\(devicePath) mode=fifo fifoPath=\(path)"
        logger.info("\(fifoOpenMessage, privacy: .public)")
    }

    private func performXPCRead(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        do {
            let data = try helperClient.read(devicePath: privilegedDevicePath, offset: offset, length: length)
            guard !data.isEmpty else {
                lastReadFailure = "Privileged helper returned EOF"
                let eofMessage =
                    "XPC read returned EOF device=\(devicePath) privilegedDevice=\(privilegedDevicePath) " +
                    "offset=\(offset) requested=\(length)"
                logger.error("\(eofMessage, privacy: .public)")
                return 0
            }

            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
            xpcReadCount += 1
            lastReadFailure = nil
            if shouldLogSuccessfulRead(count: xpcReadCount) {
                let successMessage =
                    "XPC read succeeded device=\(devicePath) " +
                    "privilegedDevice=\(privilegedDevicePath) offset=\(offset) " +
                    "requested=\(length) bytesRead=\(data.count) readCount=\(xpcReadCount)"
                logger.debug("\(successMessage, privacy: .public)")
            }
            return data.count
        } catch {
            lastReadFailure = error.localizedDescription
            let failureMessage =
                "XPC read failed device=\(devicePath) privilegedDevice=\(privilegedDevicePath) offset=\(offset) " +
                "requested=\(length) error=\(error.localizedDescription)"
            logger.error("\(failureMessage, privacy: .public)")
            return -1
        }
    }

    private func logReadBeforeStart(offset: UInt64, length: Int) -> Int {
        lastReadFailure = "Reader is not started"
        let notStartedMessage =
            "Read requested before reader start device=\(devicePath) " +
            "offset=\(offset) requested=\(length) mode=\(readerModeDescription)"
        logger.error("\(notStartedMessage, privacy: .public)")
        return 0
    }

    private func performFIFORead(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard offset >= fifoOffset else {
            let currentOffset = fifoOffset
            logger.error(
                "FIFO back-seek req=\(offset, privacy: .public) cur=\(currentOffset, privacy: .public)"
            )
            lastReadFailure =
                "FIFO back-seek requested at \(offset), current offset is \(currentOffset)"
            return -1
        }

        guard fastForwardFIFO(to: offset) else {
            return -1
        }

        var bytesRead = Darwin.read(fd, buffer, length)
        if bytesRead == 0,
           !hasReadFIFOData,
           waitForFIFOWriterData(maxRetries: 40)
        {
            bytesRead = Darwin.read(fd, buffer, length)
        }

        if bytesRead > 0 {
            return finishSuccessfulFIFORead(bytesRead, offset: offset, length: length)
        }
        if bytesRead == 0 {
            lastReadFailure = logFIFOEOF()
            return 0
        }

        lastReadFailure = "FIFO read failed: \(String(cString: strerror(errno)))"
        let failureMessage =
            "FIFO read failed device=\(devicePath) offset=\(offset) " +
            "requested=\(length) error=\(lastReadFailure ?? "unknown")"
        logger.error("\(failureMessage, privacy: .public)")
        return bytesRead
    }

    private func fastForwardFIFO(to targetOffset: UInt64) -> Bool {
        var diff = targetOffset - fifoOffset
        while diff > 0 {
            let skipBytes = min(diff, 65536)
            var skipBuffer = [UInt8](repeating: 0, count: Int(skipBytes))
            let skipped = Darwin.read(fd, &skipBuffer, Int(skipBytes))
            if skipped <= 0 {
                if skipped == 0 {
                    lastReadFailure = logFIFOEOF()
                } else {
                    lastReadFailure = "FIFO skip read failed: \(String(cString: strerror(errno)))"
                }
                return false
            }
            diff -= UInt64(skipped)
            fifoOffset += UInt64(skipped)
        }
        return true
    }

    private func finishSuccessfulFIFORead(_ bytesRead: Int, offset: UInt64, length: Int) -> Int {
        fifoOffset += UInt64(bytesRead)
        hasReadFIFOData = true
        fifoReadCount += 1
        lastReadFailure = nil
        if shouldLogSuccessfulRead(count: fifoReadCount) {
            let successMessage =
                "FIFO read succeeded device=\(devicePath) offset=\(offset) " +
                "requested=\(length) bytesRead=\(bytesRead) readCount=\(fifoReadCount)"
            logger.debug("\(successMessage, privacy: .public)")
        }
        return bytesRead
    }

    private func performDirectRead(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        let bytesRead = pread(fd, buffer, length, off_t(offset))
        if bytesRead > 0 {
            directReadCount += 1
            lastReadFailure = nil
            if shouldLogSuccessfulRead(count: directReadCount) {
                let successMessage =
                    "Direct pread succeeded device=\(devicePath) offset=\(offset) " +
                    "requested=\(length) bytesRead=\(bytesRead) readCount=\(directReadCount)"
                logger.debug("\(successMessage, privacy: .public)")
            }
            return bytesRead
        }

        if bytesRead < 0 {
            let errorDescription = Self.describeErrno(errno)
            lastReadFailure = "pread failed: \(errorDescription)"
            let failureMessage =
                "Direct pread failed device=\(devicePath) offset=\(offset) " +
                "requested=\(length) error=\(errorDescription)"
            logger.error("\(failureMessage, privacy: .public)")
            return bytesRead
        }

        lastReadFailure = "pread returned EOF"
        let eofMessage =
            "Direct pread returned EOF device=\(devicePath) offset=\(offset) requested=\(length)"
        logger.error("\(eofMessage, privacy: .public)")
        return 0
    }
}

// MARK: - Errors

enum PrivilegedReadError: LocalizedError {
    case cannotStartReader(reason: String)

    var errorDescription: String? {
        switch self {
        case let .cannotStartReader(reason):
            "Cannot access disk device: \(reason)"
        }
    }
}
