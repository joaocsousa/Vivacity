import Foundation
import Security
import os

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

    /// Direct file descriptor.
    private var fd: Int32 = -1

    /// Whether we modified the device permissions and need to restore them.
    private var needsPermissionRestore = false
    private var originalPermissions: mode_t = 0

    init(devicePath: String) {
        self.devicePath = devicePath
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Opens the device for reading, elevating privileges if needed.
    ///
    /// If the device is already readable, uses direct `open()`.
    /// Otherwise, uses AppleScript to temporarily grant read access
    /// to the device node, then opens it normally.
    func start() throws {
        // Try direct access first
        let directFd = open(devicePath, O_RDONLY)
        if directFd >= 0 {
            fd = directFd
            logger.info("Direct read access to \(self.devicePath)")
            return
        }

        let err = errno
        logger.info("Direct access denied for \(self.devicePath) (errno: \(err)), requesting privileged access")

        // Save original permissions for later restoration
        var statBuf = Darwin.stat()
        if stat(devicePath, &statBuf) == 0 {
            originalPermissions = statBuf.st_mode
        }

        // Use osascript to temporarily add world-readable permission to the device.
        // This shows the standard macOS password dialog.
        // We use chmod o+r rather than changing ownership, as it's less invasive.
        let script = "do shell script \"chmod o+r \(devicePath)\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            logger.error("Failed to grant read access: \(errorMessage)")
            throw PrivilegedReadError.cannotStartReader(reason: errorMessage)
        }

        needsPermissionRestore = true
        logger.info("Temporarily granted read access to \(self.devicePath)")

        // Now try opening again
        let newFd = open(devicePath, O_RDONLY)
        guard newFd >= 0 else {
            let openErr = String(cString: strerror(errno))
            logger.error("Still cannot open \(self.devicePath) after chmod: \(openErr)")
            restorePermissions()
            throw PrivilegedReadError.cannotStartReader(reason: "Cannot open device after granting access: \(openErr)")
        }

        fd = newFd
        logger.info("Device \(self.devicePath) opened successfully for deep scan")
    }

    /// Reads up to `length` bytes from the device at the given offset.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard fd >= 0 else { return 0 }
        return pread(fd, buffer, length, off_t(offset))
    }

    /// Stops the reader, closes the fd, and restores device permissions.
    func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }

        if needsPermissionRestore {
            restorePermissions()
        }
    }

    // MARK: - Private

    /// Restores the original device node permissions.
    private func restorePermissions() {
        guard needsPermissionRestore else { return }
        needsPermissionRestore = false

        logger.info("Restoring original permissions on \(self.devicePath)")

        // Use AppleScript to restore — no password dialog needed since
        // we're within the same authorization session.
        let script = "do shell script \"chmod o-r \(devicePath)\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown"
            logger.warning("Failed to restore permissions: \(msg)")
        } else {
            logger.info("Permissions restored on \(self.devicePath)")
        }
    }
}

// MARK: - Errors

enum PrivilegedReadError: LocalizedError {
    case cannotStartReader(reason: String)

    var errorDescription: String? {
        switch self {
        case .cannotStartReader(let reason):
            return "Cannot access disk device: \(reason)"
        }
    }
}
