import Foundation
import os
import Security

/// Service that checks and requests disk access permissions for raw device I/O.
///
/// The app needs to open `/dev/rdiskXsY` (or `/dev/diskXsY`) for low-level
/// scanning (FAT32/ExFAT/NTFS catalog parsing and Deep Scan byte carving).
///
/// - External USB/SD drives often allow read access without elevation.
/// - Internal drives typically require elevated privileges.
///
/// This service probes silently first. If access is denied, it uses
/// `AuthorizationServices` to show the native macOS password dialog.
struct PermissionService: Sendable {
    private static let logger = Logger(subsystem: "com.vivacity.app", category: "Permissions")

    /// Result of a permission check or request.
    enum Status: Sendable {
        case granted
        case denied
    }

    // MARK: - Public API

    /// Silently probes whether we can open the raw disk device for reading.
    ///
    /// This does NOT show any UI — it just attempts `open()` + `close()`.
    func checkRawDiskAccess(for device: StorageDevice) -> Status {
        let volumeInfo = VolumeInfo.detect(for: device)
        let path = volumeInfo.devicePath

        Self.logger.info("Probing raw disk access for \(path)")

        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            Self.logger.info("Raw disk access granted for \(path)")
            return .granted
        }

        let err = errno
        Self.logger.info("Raw disk access denied for \(path) (errno: \(err) — \(String(cString: strerror(err))))")
        return .denied
    }

    /// Requests elevated privileges via the native macOS password dialog.
    ///
    /// Uses `AuthorizationServices` to show the system authentication prompt.
    /// The user sees a standard macOS dialog asking for their password.
    /// Returns `.granted` if authentication succeeds, `.denied` if the user cancels.
    @MainActor
    func requestElevatedAccess() -> Status {
        Self.logger.info("Requesting elevated disk access via AuthorizationServices")

        var authRef: AuthorizationRef?

        // Create an authorization reference
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else {
            Self.logger.warning("AuthorizationCreate failed: \(status)")
            return .denied
        }

        defer {
            AuthorizationFree(auth, [.destroyRights])
        }

        // Define the right we need — system.privilege.admin triggers password prompt
        var rightName = "system.privilege.admin"

        return rightName.withCString { cString in
            var item = AuthorizationItem(
                name: cString,
                valueLength: 0,
                value: nil,
                flags: 0
            )

            var rights = withUnsafeMutablePointer(to: &item) { itemPtr in
                AuthorizationRights(count: 1, items: itemPtr)
            }

            let flags: AuthorizationFlags = [
                .interactionAllowed, // Show the password dialog
                .preAuthorize, // Actually verify the password
                .extendRights, // Extend existing rights
            ]

            status = AuthorizationCopyRights(auth, &rights, nil, flags, nil)

            if status == errAuthorizationSuccess {
                Self.logger.info("Elevated access granted by user")
                return .granted
            } else if status == errAuthorizationCanceled {
                Self.logger.info("User cancelled the authorization dialog")
                return .denied
            } else {
                Self.logger.warning("AuthorizationCopyRights failed: \(status)")
                return .denied
            }
        }
    }
}
