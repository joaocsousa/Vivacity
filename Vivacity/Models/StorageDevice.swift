import Foundation

/// Represents a mounted storage device (volume) that can be scanned for recoverable files.
struct StorageDevice: Identifiable, Hashable, Sendable {
    /// Unique identifier — uses the volume URL's absolute string.
    let id: String

    /// User-visible volume name (e.g. "Macintosh HD", "USB Drive").
    let name: String

    /// Mount-point URL for the volume (e.g. `/Volumes/MyDrive`).
    let volumePath: URL

    /// Stable volume UUID — used to deduplicate APFS volumes that appear
    /// at multiple mount points (e.g. `/` and `/System/Volumes/Data`).
    let volumeUUID: String

    /// The filesystem type of the volume (e.g. APFS, HFS+, ExFAT, FAT32).
    let filesystemType: FilesystemType

    /// Whether the volume is on an external (removable) device.
    let isExternal: Bool

    /// Whether this device is actually an unmounted raw disk image file.
    var isDiskImage: Bool = false

    /// The offset in bytes from the start of the physical disk where this partition begins.
    /// If non-nil, this device represents a virtual "lost" partition found by a raw disk scan.
    let partitionOffset: UInt64?

    /// The total size of the partition in bytes, as defined by its boot sector or partition table.
    let partitionSize: Int64?

    /// Total capacity of the volume in bytes.
    let totalCapacity: Int64

    /// Currently available (free) capacity in bytes.
    let availableCapacity: Int64

    // MARK: - Computed Helpers

    /// Total capacity formatted as a human-readable string (e.g. "500 GB").
    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
    }

    /// Available capacity formatted as a human-readable string (e.g. "120 GB").
    var formattedAvailable: String {
        ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
    }

    /// Usage fraction (0–1) representing how full the volume is.
    var usageFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(totalCapacity - availableCapacity) / Double(totalCapacity)
    }
}
