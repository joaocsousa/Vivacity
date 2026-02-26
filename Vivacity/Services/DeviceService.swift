import AppKit
import Foundation

protocol DeviceServicing: Sendable {
    func discoverDevices() async throws -> [StorageDevice]
    func volumeChanges() -> AsyncStream<Void>
}

/// Service responsible for discovering mounted storage devices (volumes).
struct DeviceService: DeviceServicing {
    // MARK: - Volume Paths to Exclude

    /// Path prefixes for system volumes that should never appear in the device list.
    /// Note: `/System/Volumes/Data` is intentionally *not* excluded — it is the
    /// user's main writable volume on modern macOS (APFS).
    private static let excludedPrefixes: [String] = [
        "/System/Volumes/Preboot",
        "/System/Volumes/Recovery",
        "/System/Volumes/VM",
        "/System/Volumes/Update",
        "/System/Volumes/xarts",
        "/System/Volumes/iSCPreboot",
        "/System/Volumes/Hardware",
        "/private/",
    ]

    /// Exact mount points to exclude (currently none — root `/` is kept as the
    /// internal drive on systems where FileManager doesn't expose `/System/Volumes/Data`).
    private static let excludedPaths: Set<String> = []

    /// Volume names that indicate system partitions.
    private static let excludedNames: Set<String> = [
        "Recovery",
        "Preboot",
        "VM",
        "Update",
    ]

    // MARK: - Public API

    /// Discovers all user-relevant mounted volumes.
    ///
    /// - Returns: An array of ``StorageDevice`` sorted with external devices first,
    ///   then alphabetically by name.
    func discoverDevices() async throws -> [StorageDevice] {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .volumeUUIDStringKey,
        ]

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var devices: [StorageDevice] = []

        for url in volumeURLs {
            guard let device = try? storageDevice(from: url, keys: resourceKeys) else {
                continue
            }
            print(
                "DISCOVERED: [\(device.name)] Ext:\(device.isExternal) " +
                    "UUID:\(device.volumeUUID) Path:\(device.volumePath.path)"
            )
            devices.append(device)
        }

        // Deduplicate by volume UUID — on APFS, `/` and `/System/Volumes/Data`
        // share the same UUID. Keep only the first occurrence per UUID,
        // preferring the internal-flagged entry (i.e. the real mount point).
        var seen = Set<String>()
        devices = devices
            .sorted { !$0.isExternal && $1.isExternal } // internal first for stable dedup
            .filter { device in
                guard seen.insert(device.volumeUUID).inserted else { return false }
                return true
            }

        // Sort: external first, then alphabetical by name.
        devices.sort { lhs, rhs in
            if lhs.isExternal != rhs.isExternal {
                return lhs.isExternal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return devices
    }

    /// Returns an `AsyncStream` that emits a value whenever a volume is mounted or unmounted.
    ///
    /// Use this to trigger a device list refresh automatically.
    func volumeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter

            let mountObserver = center.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield()
            }

            let unmountObserver = center.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield()
            }

            continuation.onTermination = { _ in
                center.removeObserver(mountObserver)
                center.removeObserver(unmountObserver)
            }
        }
    }

    // MARK: - Private Helpers

    private func storageDevice(
        from url: URL,
        keys: Set<URLResourceKey>
    ) throws -> StorageDevice? {
        let path = url.path

        // Filter out system volumes by path.
        if Self.excludedPaths.contains(path) {
            return nil
        }
        for prefix in Self.excludedPrefixes {
            if path.hasPrefix(prefix) {
                return nil
            }
        }

        // Ensure this is an actual mount point. macOS can fire didUnmountNotification
        // while the volume is still unmounting, leaving a "zombie" directory in /Volumes.
        // statfs reads the real filesystem mount point to filter these out.
        var stat = statfs()
        if statfs(path, &stat) == 0 {
            let mountPoint = withUnsafePointer(to: stat.f_mntonname) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                    String(cString: cString)
                }
            }
            // `path` from URL usually drops trailing slashes unless it's `/`
            if path != mountPoint, path != mountPoint + "/" {
                return nil
            }
        } else {
            return nil
        }

        let resourceValues = try url.resourceValues(forKeys: keys)

        let name = resourceValues.volumeName ?? url.lastPathComponent

        // Filter out system volumes by name.
        if Self.excludedNames.contains(name) {
            return nil
        }

        let isInternal = resourceValues.volumeIsInternal ?? true
        let isRemovable = resourceValues.volumeIsRemovable ?? false
        let isExternal = !isInternal || isRemovable

        let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
        let availableCapacity = Int64(resourceValues.volumeAvailableCapacity ?? 0)

        let uuid = resourceValues.volumeUUIDString ?? url.absoluteString

        let volumeInfo = VolumeInfo.detect(for: StorageDevice(
            id: url.absoluteString,
            name: name,
            volumePath: url,
            volumeUUID: uuid,
            filesystemType: .other, // temp
            isExternal: isExternal,
            totalCapacity: totalCapacity,
            availableCapacity: availableCapacity
        ))

        return StorageDevice(
            id: url.absoluteString,
            name: name,
            volumePath: url,
            volumeUUID: uuid,
            filesystemType: volumeInfo.filesystemType,
            isExternal: isExternal,
            totalCapacity: totalCapacity,
            availableCapacity: availableCapacity
        )
    }
}
