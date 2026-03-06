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

    init(devicePath: String) {
        self.devicePath = devicePath
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
        let devPath = devicePath
        lastReadFailure = nil

        // Try direct access first
        let directFd = open(devPath, O_RDONLY)
        if directFd >= 0 {
            fd = directFd
            isXPC = false
            logger.info("Direct read access to \(devPath, privacy: .public)")
            return
        }

        let err = errno
        logger.info(
            "Access denied \(devPath, privacy: .public) errno=\(err, privacy: .public); requesting privileged access"
        )

        // Try XPC privileged helper before FIFO fallback.
        helperClient.prepareForPrivilegedAccess()
        if helperClient.isAvailable() {
            isXPC = true
            isFifo = false
            fifoOffset = 0
            hasReadFIFOData = false
            logger.info("Using privileged helper XPC service for \(devPath, privacy: .public)")
            return
        }

        if let installError = helperClient.lastInstallErrorDescription {
            let reason = "Recovery helper install failed: \(installError)"
            logger.error("\(reason, privacy: .public)")
            throw PrivilegedReadError.cannotStartReader(reason: reason)
        }

        logger.info("Privileged helper unavailable, falling back to FIFO dd bridge")

        // Direct access failed, try FIFO fallback
        let uuid = UUID().uuidString
        let path = "/tmp/vivacity_reader_\(uuid).pipe"
        let ddLogPath = "/tmp/vivacity_reader_\(uuid).dd.log"

        // 1. Create FIFO (readable/writable only by user)
        if mkfifo(path, 0o600) != 0 {
            let mkfifoErr = String(cString: strerror(errno))
            throw PrivilegedReadError.cannotStartReader(reason: "Failed to create FIFO: \(mkfifoErr)")
        }

        fifoPath = path
        isFifo = true
        isXPC = false
        ddDiagnosticLogPath = ddLogPath
        fifoOffset = 0
        hasReadFIFOData = false

        // 2. Use osascript to start dd in background writing to the FIFO.
        // This shows the standard macOS password dialog once.
        // Using "dd ... >/dev/null 2>&1 & echo $!" allows it to run in background
        // and instantly returns the PID of the background process.
        let script = """
        do shell script "dd if=\(devPath) of=\(
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

        // 3. Open the FIFO for reading
        // O_NONBLOCK prevents open() from hanging if dd completely fails to start
        let newFd = open(path, O_RDONLY | O_NONBLOCK)
        guard newFd >= 0 else {
            let openErr = String(cString: strerror(errno))
            unlink(path)
            logger.error(
                "Cannot open internal FIFO \(path, privacy: .public): \(openErr, privacy: .public)"
            )
            throw PrivilegedReadError.cannotStartReader(reason: "Cannot open internal FIFO: \(openErr)")
        }

        // Remove O_NONBLOCK so subsequent read() calls will block properly waiting for dd
        let flags = fcntl(newFd, F_GETFL, 0)
        _ = fcntl(newFd, F_SETFL, flags & ~O_NONBLOCK)

        fd = newFd
        logger.info("Device \(devPath, privacy: .public) opened successfully for deep scan")
    }

    /// Reads up to `length` bytes from the device at the given offset.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard fd >= 0 else {
            if isXPC {
                do {
                    let data = try helperClient.read(devicePath: devicePath, offset: offset, length: length)
                    if data.isEmpty {
                        lastReadFailure = "Privileged helper returned EOF"
                        return 0
                    }
                    data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                    lastReadFailure = nil
                    return data.count
                } catch {
                    lastReadFailure = error.localizedDescription
                    return -1
                }
            }
            lastReadFailure = "Reader is not started"
            return 0
        }

        if isFifo {
            // FIFO cannot seek backwards
            if offset < fifoOffset {
                let currentOffset = fifoOffset
                logger.error(
                    "FIFO back-seek req=\(offset, privacy: .public) cur=\(currentOffset, privacy: .public)"
                )
                lastReadFailure =
                    "FIFO back-seek requested at \(offset), current offset is \(currentOffset)"
                return -1
            }

            // Fast-forward by reading and discarding bytes if offset > fifoOffset
            var diff = offset - fifoOffset
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
                    return -1
                }
                diff -= UInt64(skipped)
                fifoOffset += UInt64(skipped)
            }

            // Read target data
            var bytesRead = Darwin.read(fd, buffer, length)
            if bytesRead == 0,
               !hasReadFIFOData,
               waitForFIFOWriterData(maxRetries: 40)
            {
                bytesRead = Darwin.read(fd, buffer, length)
            }

            if bytesRead > 0 {
                fifoOffset += UInt64(bytesRead)
                hasReadFIFOData = true
                lastReadFailure = nil
            } else if bytesRead == 0 {
                lastReadFailure = logFIFOEOF()
            } else {
                lastReadFailure = "FIFO read failed: \(String(cString: strerror(errno)))"
            }
            return bytesRead
        } else {
            // Direct seekable device node
            let bytesRead = pread(fd, buffer, length, off_t(offset))
            if bytesRead > 0 {
                lastReadFailure = nil
            } else if bytesRead < 0 {
                lastReadFailure = "pread failed: \(String(cString: strerror(errno)))"
            } else {
                lastReadFailure = "pread returned EOF"
            }
            return bytesRead
        }
    }

    /// Stops the reader, closes the fd, and cleans up the FIFO.
    func stop() {
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
