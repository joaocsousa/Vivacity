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

    /// Parses a Boot Parameter Block from a 512-byte boot sector.
    init?(bootSector sector: [UInt8]) {
        guard sector.count >= 512 else { return nil }

        // Verify boot signature
        guard sector[510] == 0x55, sector[511] == 0xAA else {
            return nil
        }

        let bytesPerSector = Int(sector[11]) | (Int(sector[12]) << 8)
        let sectorsPerCluster = Int(sector[13])
        let reservedSectors = Int(sector[14]) | (Int(sector[15]) << 8)
        let numberOfFATs = Int(sector[16])

        // FAT32-specific: sectors per FAT at offset 36 (4 bytes)
        let sectorsPerFAT = Int(sector[36]) | (Int(sector[37]) << 8) |
            (Int(sector[38]) << 16) | (Int(sector[39]) << 24)

        // Root directory cluster at offset 44 (4 bytes)
        let rootCluster = UInt32(sector[44]) | (UInt32(sector[45]) << 8) |
            (UInt32(sector[46]) << 16) | (UInt32(sector[47]) << 24)

        // Total sectors: try 32-bit field first (offset 32), then 16-bit (offset 19)
        var totalSectors = UInt64(sector[32]) | (UInt64(sector[33]) << 8) |
            (UInt64(sector[34]) << 16) | (UInt64(sector[35]) << 24)
        if totalSectors == 0 {
            totalSectors = UInt64(sector[19]) | (UInt64(sector[20]) << 8)
        }

        guard bytesPerSector > 0, sectorsPerCluster > 0,
              reservedSectors > 0, numberOfFATs > 0, sectorsPerFAT > 0
        else {
            return nil
        }

        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.reservedSectors = reservedSectors
        self.numberOfFATs = numberOfFATs
        self.sectorsPerFAT = sectorsPerFAT
        self.rootCluster = rootCluster
        self.totalSectors = totalSectors
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
            "Cannot open \(path): \(reason)"
        case .invalidBootSector:
            "Invalid FAT32 boot sector — this volume may not be FAT32 formatted."
        case .cannotReadFAT:
            "Failed to read the FAT table from the volume."
        }
    }
}

// MARK: - LFN Parser

/// Helper to parse and reconstruct Long File Names from FAT32 entries.
enum LFNParser {
    /// Extracts 13 UCS-2 characters from a single LFN directory entry.
    ///
    /// Characters are stored at three disjoint byte ranges within the 32-byte entry:
    /// - Bytes 1–10: characters 1–5 (5 chars × 2 bytes)
    /// - Bytes 14–25: characters 6–11 (6 chars × 2 bytes)
    /// - Bytes 28–31: characters 12–13 (2 chars × 2 bytes)
    static func extractLFNCharacters(from entry: [UInt8]) -> [UInt16] {
        var chars: [UInt16] = []

        // Chars 1–5 at bytes 1–10
        for j in stride(from: 1, to: 11, by: 2) {
            let ch = UInt16(entry[j]) | (UInt16(entry[j + 1]) << 8)
            if ch == 0x0000 || ch == 0xFFFF { return chars }
            chars.append(ch)
        }

        // Chars 6–11 at bytes 14–25
        for j in stride(from: 14, to: 26, by: 2) {
            let ch = UInt16(entry[j]) | (UInt16(entry[j + 1]) << 8)
            if ch == 0x0000 || ch == 0xFFFF { return chars }
            chars.append(ch)
        }

        // Chars 12–13 at bytes 28–31
        for j in stride(from: 28, to: 32, by: 2) {
            let ch = UInt16(entry[j]) | (UInt16(entry[j + 1]) << 8)
            if ch == 0x0000 || ch == 0xFFFF { return chars }
            chars.append(ch)
        }

        return chars
    }

    /// Reconstructs the full Long File Name from collected LFN segments.
    ///
    /// Segments arrive in reverse order (last segment first), so we sort by
    /// sequence number and concatenate the UCS-2 characters.
    static func reconstructLFN(from segments: [(order: Int, chars: [UInt16])]) -> String? {
        guard !segments.isEmpty else { return nil }

        let sorted = segments.sorted { $0.order < $1.order }
        var allChars: [UInt16] = []
        for segment in sorted {
            allChars.append(contentsOf: segment.chars)
        }

        // Convert UCS-2 to String
        let result = String(utf16CodeUnits: allChars, count: allChars.count)
        return result.isEmpty ? nil : result
    }
}
