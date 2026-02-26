import Foundation
import os

// MARK: - Filesystem Type

/// The filesystem format of a mounted volume.
enum FilesystemType: String, Sendable {
    case fat32 = "msdos" // FAT12/16/32 report as "msdos" on macOS
    case exfat
    case ntfs // NTFS (via macFUSE, Paragon, or Tuxera)
    case apfs
    case hfsPlus = "hfs"
    case other

    /// Human-readable label shown in the device list.
    var displayName: String {
        switch self {
        case .fat32: "FAT32"
        case .exfat: "ExFAT"
        case .ntfs: "NTFS"
        case .apfs: "APFS"
        case .hfsPlus: "HFS+"
        case .other: "Unknown FS"
        }
    }
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

        // Prefer the raw character device (/dev/rdiskXsY) for faster reads.
        // Fall back to the block device (/dev/diskXsY) if the raw device isn't
        // accessible — macOS often allows user-level read on block devices for
        // external volumes, even when the raw device requires admin privileges.
        var resolvedDevicePath = devicePath
        if devicePath.hasPrefix("/dev/disk") {
            let rawPath = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            if access(rawPath, R_OK) == 0 {
                resolvedDevicePath = rawPath
            } else if access(devicePath, R_OK) == 0 {
                resolvedDevicePath = devicePath // block device is readable
            }
            // else: neither is accessible without elevation — Deep Scan or Catalog Scan
            //        will prompt for permissions via PrivilegedDiskReader
        }

        logger.info("Detected \(fsTypeName) filesystem on \(resolvedDevicePath) at \(volumePath)")

        return VolumeInfo(
            filesystemType: fsType,
            devicePath: resolvedDevicePath,
            mountPoint: device.volumePath
        )
    }
}
