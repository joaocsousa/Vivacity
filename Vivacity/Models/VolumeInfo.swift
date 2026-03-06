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

    /// Filesystem block size reported by statfs.
    let blockSize: Int

    private static let logger = Logger(subsystem: "com.vivacity.app", category: "VolumeInfo")

    private static func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private static func logWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    // MARK: - Detection

    /// Detects filesystem type and device path for the given storage device.
    static func detect(for device: StorageDevice) -> VolumeInfo {
        let volumePath = device.volumePath.path

        if device.isDiskImage {
            logInfo("Skipping statfs for disk image file at \(volumePath)")
            return VolumeInfo(
                filesystemType: .other,
                devicePath: volumePath,
                mountPoint: device.volumePath,
                blockSize: 4096
            )
        }

        var stat = statfs()
        guard statfs(volumePath, &stat) == 0 else {
            logWarning("statfs failed for \(volumePath), defaulting to 'other'")
            return VolumeInfo(
                filesystemType: .other,
                devicePath: volumePath,
                mountPoint: device.volumePath,
                blockSize: 4096
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
        let remappedDevicePath = remapAPFSSnapshotDeviceIfNeeded(
            currentDevicePath: devicePath,
            fsType: fsType,
            mountPath: volumePath
        )
        let resolvedDevicePath = preferRawDevicePathIfReadable(remappedDevicePath)

        logInfo("Detected \(fsTypeName) filesystem on \(resolvedDevicePath) at \(volumePath)")

        return VolumeInfo(
            filesystemType: fsType,
            devicePath: resolvedDevicePath,
            mountPoint: device.volumePath,
            blockSize: max(Int(stat.f_bsize), 512)
        )
    }

    // MARK: - Helpers

    private static func remapAPFSSnapshotDeviceIfNeeded(
        currentDevicePath: String,
        fsType: FilesystemType,
        mountPath: String
    ) -> String {
        guard fsType == .apfs,
              let sourceInfo = diskutilInfoPlist(for: mountPath),
              let isSnapshot = sourceInfo["APFSSnapshot"] as? Bool,
              isSnapshot
        else {
            return currentDevicePath
        }

        let groupID = sourceInfo["APFSVolumeGroupID"] as? String
        guard let dataInfo = diskutilInfoPlist(for: "/System/Volumes/Data"),
              let dataIsSnapshot = dataInfo["APFSSnapshot"] as? Bool,
              dataIsSnapshot == false,
              let dataDeviceNode = dataInfo["DeviceNode"] as? String
        else {
            logWarning("APFS snapshot \(currentDevicePath) detected, but Data volume mapping is unavailable")
            return currentDevicePath
        }

        if let groupID,
           let dataGroupID = dataInfo["APFSVolumeGroupID"] as? String,
           dataGroupID != groupID
        {
            logWarning(
                "APFS snapshot \(currentDevicePath) group mismatch " +
                    "(\(groupID) vs \(dataGroupID)); keeping snapshot device"
            )
            return currentDevicePath
        }

        logInfo("APFS snapshot \(currentDevicePath) remapped to Data volume \(dataDeviceNode)")
        return dataDeviceNode
    }

    private static func preferRawDevicePathIfReadable(_ devicePath: String) -> String {
        // Prefer the raw character device (/dev/rdiskXsY) for faster reads.
        // Fall back to the block device (/dev/diskXsY) if the raw device isn't
        // accessible — macOS often allows user-level read on block devices for
        // external volumes, even when the raw device requires admin privileges.
        guard devicePath.hasPrefix("/dev/disk") else { return devicePath }

        let rawPath = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        if access(rawPath, R_OK) == 0 {
            return rawPath
        }
        if access(devicePath, R_OK) == 0 {
            return devicePath
        }
        // Neither path is readable without elevation; keep block path and let
        // PrivilegedDiskReader request elevated access.
        return devicePath
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
            logWarning("diskutil info failed to run for \(path): \(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "unknown"
            logWarning("diskutil info failed for \(path): \(stderrText)")
            return nil
        }

        let plistData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any]
        else {
            logWarning("diskutil info returned invalid plist for \(path)")
            return nil
        }
        return dict
    }
}
