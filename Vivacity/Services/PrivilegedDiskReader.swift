import Foundation
import os
import Security

/// Provides privileged read access to raw disk devices.
///
/// For direct access, uses `pread()` with a file descriptor. When the
/// device is not directly readable (e.g. `/dev/disk17` owned by root),
/// temporarily grants read access to the device node using `chmod` via
/// AppleScript's `do shell script ... with administrator privileges`.
///
/// After the scan completes, the original permissions are restored.
///
/// This approach works for Developer ID distribution and shows the
/// standard macOS password dialog for authentication.
final class PrivilegedDiskReader: @unchecked Sendable {
    private let devicePath: String
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedDiskReader")

    /// Direct or FIFO file descriptor.
    private var fd: Int32 = -1

    /// FIFO-related state
    private var isFifo = false
    private var fifoPath: String?
    private var ddTaskPID: Int32?
    private var fifoOffset: UInt64 = 0

    init(devicePath: String) {
        self.devicePath = devicePath
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Whether the reader currently supports random access (true for direct access, false for FIFO fallback).
    var isSeekable: Bool {
        fd >= 0 && !isFifo
    }

    /// Opens the device for reading, elevating privileges if needed.
    ///
    /// If the device is already readable, uses direct `open()`.
    /// Otherwise, uses AppleScript to temporarily grant read access
    /// to the device node, then opens it normally.
    func start() throws {
        let devPath = devicePath

        // Try direct access first
        let directFd = open(devPath, O_RDONLY)
        if directFd >= 0 {
            fd = directFd
            logger.info("Direct read access to \(devPath)")
            return
        }

        let err = errno
        logger.info("Direct access denied for \(devPath) (errno: \(err)), requesting privileged access")

        // Direct access failed, try FIFO fallback
        let uuid = UUID().uuidString
        let path = "/tmp/vivacity_reader_\(uuid).pipe"

        // 1. Create FIFO (readable/writable only by user)
        if mkfifo(path, 0o600) != 0 {
            let mkfifoErr = String(cString: strerror(errno))
            throw PrivilegedReadError.cannotStartReader(reason: "Failed to create FIFO: \(mkfifoErr)")
        }

        fifoPath = path
        isFifo = true

        // 2. Use osascript to start dd in background writing to the FIFO.
        // This shows the standard macOS password dialog once.
        // Using "dd ... >/dev/null 2>&1 & echo $!" allows it to run in background
        // and instantly returns the PID of the background process.
        let script = """
        do shell script "dd if=\(devPath) of=\(
            path
        ) bs=131072 >/dev/null 2>&1 & echo $!" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        guard let output = appleScript?.executeAndReturnError(&errorDict) else {
            unlink(path)
            let errorMessage = errorDict?[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            logger.error("Failed to start privileged dd task: \(errorMessage)")
            throw PrivilegedReadError.cannotStartReader(reason: errorMessage)
        }

        if let pidString = output.stringValue, let pid = Int32(pidString) {
            ddTaskPID = pid
            logger.info("Temporarily granted read access via FIFO with dd (PID: \(pid))")
        }

        // 3. Open the FIFO for reading
        // O_NONBLOCK prevents open() from hanging if dd completely fails to start
        let newFd = open(path, O_RDONLY | O_NONBLOCK)
        guard newFd >= 0 else {
            let openErr = String(cString: strerror(errno))
            unlink(path)
            logger.error("Cannot open internal FIFO \(path): \(openErr)")
            throw PrivilegedReadError.cannotStartReader(reason: "Cannot open internal FIFO: \(openErr)")
        }

        // Remove O_NONBLOCK so subsequent read() calls will block properly waiting for dd
        let flags = fcntl(newFd, F_GETFL, 0)
        _ = fcntl(newFd, F_SETFL, flags & ~O_NONBLOCK)

        fd = newFd
        logger.info("Device \(devPath) opened successfully for deep scan")
    }

    /// Reads up to `length` bytes from the device at the given offset.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard fd >= 0 else { return 0 }

        if isFifo {
            // FIFO cannot seek backwards
            if offset < fifoOffset {
                let currentOffset = fifoOffset
                logger.error("Cannot seek backwards in FIFO (requested: \(offset), current: \(currentOffset))")
                return -1
            }

            // Fast-forward by reading and discarding bytes if offset > fifoOffset
            var diff = offset - fifoOffset
            while diff > 0 {
                let skipBytes = min(diff, 65536)
                var skipBuffer = [UInt8](repeating: 0, count: Int(skipBytes))
                let skipped = Darwin.read(fd, &skipBuffer, Int(skipBytes))
                if skipped <= 0 { return -1 } // Error or EOF
                diff -= UInt64(skipped)
                fifoOffset += UInt64(skipped)
            }

            // Read target data
            let bytesRead = Darwin.read(fd, buffer, length)
            if bytesRead > 0 {
                fifoOffset += UInt64(bytesRead)
            }
            return bytesRead
        } else {
            // Direct seekable device node
            return pread(fd, buffer, length, off_t(offset))
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
            logger.info("Closed FIFO, dd (PID \(pid)) should terminate via SIGPIPE")
            ddTaskPID = nil
        }

        if let path = fifoPath {
            unlink(path)
            fifoPath = nil
        }
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
