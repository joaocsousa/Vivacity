import Foundation

// MARK: - BPB (Boot Parameter Block)

/// Parsed FAT32 Boot Parameter Block with layout information.
struct BPB {
    let bytesPerSector: Int
    let sectorsPerCluster: Int
    let reservedSectors: Int
    let numberOfFATs: Int
    let sectorsPerFAT: Int
    let rootCluster: UInt32
    let totalSectors: UInt64

    /// Bytes per cluster.
    var clusterSize: Int {
        bytesPerSector * sectorsPerCluster
    }

    /// Byte offset where the FAT table starts.
    var fatOffset: Int {
        reservedSectors * bytesPerSector
    }

    /// Size of one FAT table in bytes.
    var fatSize: Int {
        sectorsPerFAT * bytesPerSector
    }

    /// Byte offset where the data region starts.
    var dataRegionOffset: Int {
        (reservedSectors + numberOfFATs * sectorsPerFAT) * bytesPerSector
    }

    /// Converts a cluster number to its byte offset on disk.
    func clusterOffset(_ cluster: UInt32) -> UInt64 {
        // Clusters start at 2, so subtract 2
        UInt64(dataRegionOffset) + UInt64(cluster - 2) * UInt64(clusterSize)
    }
}

// MARK: - Directory Entry Parsing

/// A parsed FAT32 directory entry with optional Long File Name.
struct FATDirectoryEntry {
    let rawBytes: [UInt8]
    let isDeleted: Bool
    let isEndOfDirectory: Bool
    let isSubdirectory: Bool
    let isVolumeLabel: Bool
    /// The best available file name (LFN if available, otherwise 8.3).
    let fileName: String
    /// File extension from the 8.3 entry (lowercased).
    let fileExtension: String
    let startingCluster: UInt32
    let fileSize: UInt32
}

// MARK: - Errors

/// Errors specific to FAT32 directory scanning.
enum FATScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)
    case invalidBootSector
    case cannotReadFAT

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            return "Cannot open \(path): \(reason)"
        case .invalidBootSector:
            return "Invalid FAT32 boot sector — this volume may not be FAT32 formatted."
        case .cannotReadFAT:
            return "Failed to read the FAT table from the volume."
        }
    }
}
