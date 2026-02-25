import Foundation
import os

// MARK: - Filesystem Type

/// The filesystem format of a mounted volume.
enum FilesystemType: String, Sendable {
    case fat32  = "msdos"   // FAT12/16/32 report as "msdos" on macOS
    case exfat  = "exfat"
    case ntfs   = "ntfs"    // NTFS (via macFUSE, Paragon, or Tuxera)
    case apfs   = "apfs"
    case hfsPlus = "hfs"
    case other  = "other"
}

// MARK: - Volume Info

/// Metadata about a mounted volume, including filesystem type and raw device path.
struct VolumeInfo: Sendable {

    /// The filesystem format.
    let filesystemType: FilesystemType

    /// The raw device path (e.g. `/dev/rdisk2s1`).
    let devicePath: String

    /// The mount point URL (e.g. `/Volumes/USB_DRIVE`).
    let mountPoint: URL

    private static let logger = Logger(subsystem: "com.vivacity.app", category: "VolumeInfo")

    // MARK: - Detection

    /// Detects filesystem type and device path for the given storage device.
    static func detect(for device: StorageDevice) -> VolumeInfo {
        let volumePath = device.volumePath.path

        var stat = statfs()
        guard statfs(volumePath, &stat) == 0 else {
            logger.warning("statfs failed for \(volumePath), defaulting to 'other'")
            return VolumeInfo(
                filesystemType: .other,
                devicePath: volumePath,
                mountPoint: device.volumePath
            )
        }

        // Extract filesystem type name
        let fsTypeName = withUnsafePointer(to: &stat.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { cStr in
                String(cString: cStr)
            }
        }

        // Extract device path
        let devicePath = withUnsafePointer(to: &stat.f_mntfromname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                String(cString: cStr)
            }
        }

        let fsType = FilesystemType(rawValue: fsTypeName) ?? .other

        // Prefer the raw character device (/dev/rdiskXsY) for faster reads
        var resolvedDevicePath = devicePath
        if devicePath.hasPrefix("/dev/disk") {
            let rawPath = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            if access(rawPath, R_OK) == 0 {
                resolvedDevicePath = rawPath
            }
        }

        logger.info("Detected \(fsTypeName) filesystem on \(resolvedDevicePath) at \(volumePath)")

        return VolumeInfo(
            filesystemType: fsType,
            devicePath: resolvedDevicePath,
            mountPoint: device.volumePath
        )
    }
}
