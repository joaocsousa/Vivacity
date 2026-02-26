import Foundation
import os

/// Scans raw bytes for orphaned FAT32 directory entries (carving).
struct FATCarver {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FATCarver")

    /// The boot parameter block, if successfully parsed at the start of the scan
    let bpb: BPB

    /// State buffer for assembling Long File Names across sector boundaries within a chunk
    private var lfnSegments: [(order: Int, chars: [UInt16])] = []

    /// A file discovered heuristically by the carver.
    struct CarvedFile {
        let fileName: String
        let fileExtension: String
        let sizeInBytes: Int64
        let offsetOnDisk: UInt64
    }

    init(bpb: BPB) {
        self.bpb = bpb
    }

    /// Scan a raw byte buffer for FAT directory sectors.
    /// - Parameters:
    ///   - buffer: The raw byte buffer (expected to be a multiple of sector size).
    ///   - baseOffset: The absolute disk offset of this buffer.
    mutating func carveChunk(
        buffer: UnsafeRawBufferPointer,
        baseOffset: UInt64
    ) -> [CarvedFile] {
        var results: [CarvedFile] = []

        let sectorSize = 512
        var i = 0
        while i <= buffer.count - sectorSize {
            let sectorBytes = UnsafeRawBufferPointer(rebasing: buffer[i ..< i + sectorSize])

            if isPlausibleDirectorySector(sectorBytes) {
                let parsedFiles = parseDirectorySector(
                    sector: sectorBytes,
                    sectorOffset: baseOffset + UInt64(i)
                )
                results.append(contentsOf: parsedFiles)
            } else {
                // If the sector doesn't look like a directory, drop any pending LFN chain.
                lfnSegments.removeAll()
            }

            i += sectorSize
        }

        return results
    }

    private func isPlausibleDirectorySector(_ sector: UnsafeRawBufferPointer) -> Bool {
        var validEntryCount = 0
        var activeFileCount = 0

        for j in stride(from: 0, to: 512, by: 32) {
            let entry = UnsafeRawBufferPointer(rebasing: sector[j ..< j + 32])
            let firstByte = entry[0]

            if firstByte == 0x00 {
                // Must be largely zeroes
                var isZeros = true
                for k in 1 ..< 32 {
                    if entry[k] != 0 {
                        isZeros = false
                        break
                    }
                }
                if isZeros { validEntryCount += 1 }
                continue
            }

            let attributes = entry[11]

            if attributes == 0x0F {
                // LFN
                if entry[12] == 0x00, entry[26] == 0x00, entry[27] == 0x00 {
                    let order = firstByte
                    if (order & 0xBF) >= 1, (order & 0xBF) <= 20 {
                        validEntryCount += 1
                    }
                }
                continue
            }

            // Short Entry
            if (attributes & 0xC0) == 0 {
                var nameValid = true
                for k in 0 ..< 11 {
                    let c = entry[k]
                    if k == 0, c == 0xE5 { continue }
                    // Very simple filter: accept most printing ASCII characters
                    // plus some extended characters. This reduces false positives.
                    if c < 0x20, c != 0x05 {
                        nameValid = false
                        break
                    }
                }

                if nameValid {
                    validEntryCount += 1

                    let isSubdir = (attributes & 0x10) != 0
                    if isSubdir || entry[0] == 0x2E {
                        // "." or ".." or subdirectory
                        activeFileCount += 1
                    } else {
                        let clusterHigh = UInt32(entry[20]) | (UInt32(entry[21]) << 8)
                        let clusterLow = UInt32(entry[26]) | (UInt32(entry[27]) << 8)
                        let cluster = (clusterHigh << 16) | clusterLow
                        let size = UInt32(entry[28]) | (UInt32(entry[29]) << 8) | (UInt32(entry[30]) << 16) |
                            (UInt32(entry[31]) << 24)

                        if cluster >= 2 || size > 0 || firstByte == 0xE5 {
                            activeFileCount += 1
                        }
                    }
                }
            }
        }

        // Require at least 14 "valid" 32-byte slots, and at least 1 actual file/dir entry.
        return validEntryCount >= 14 && activeFileCount > 0
    }

    private mutating func parseDirectorySector(
        sector: UnsafeRawBufferPointer,
        sectorOffset: UInt64
    ) -> [CarvedFile] {
        var files: [CarvedFile] = []

        for j in stride(from: 0, to: 512, by: 32) {
            let entryBytes = Array(sector[j ..< j + 32])
            let firstByte = entryBytes[0]

            if firstByte == 0x00 {
                continue // End of directory or padding
            }

            let attributes = entryBytes[11]
            if attributes == 0x0F {
                let lfnChars = LFNParser.extractLFNCharacters(from: entryBytes)
                let order = Int(firstByte & 0x3F)
                lfnSegments.append((order: order, chars: lfnChars))
                continue
            }

            // Process short entry
            let isDeleted = (firstByte == 0xE5)
            let isSubdirectory = (attributes & 0x10) != 0
            let isVolumeLabel = (attributes & 0x08) != 0

            let longName = LFNParser.reconstructLFN(from: lfnSegments)
            lfnSegments.removeAll()

            if isVolumeLabel { continue } // We don't carve volume labels

            // Reconstruct 8.3 name
            var nameBytes = Array(entryBytes[0 ..< 8])
            if isDeleted { nameBytes[0] = 0x5F } // Replace 0xE5 with '_'
            let shortName = String(bytes: nameBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            let ext = String(bytes: Array(entryBytes[8 ..< 11]), encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""

            // Skip "." and ".." (self/parent dir references)
            if shortName == "." || shortName == ".." || (shortName.isEmpty && ext.isEmpty) {
                continue
            }

            let displayName: String
            if let lfn = longName {
                let lfnURL = URL(fileURLWithPath: lfn)
                let lfnBase = lfnURL.deletingPathExtension().lastPathComponent
                displayName = lfnBase.isEmpty ? shortName : lfnBase
            } else {
                displayName = shortName
            }

            let clusterHigh = UInt32(entryBytes[20]) | (UInt32(entryBytes[21]) << 8)
            let clusterLow = UInt32(entryBytes[26]) | (UInt32(entryBytes[27]) << 8)
            let startingCluster = (clusterHigh << 16) | clusterLow

            let fileSize = UInt32(entryBytes[28]) | (UInt32(entryBytes[29]) << 8) | (UInt32(entryBytes[30]) << 16) |
                (UInt32(entryBytes[31]) << 24)

            // Invalid allocations or completely empty (non-directory) entries
            if startingCluster < 2 { continue }
            if fileSize == 0, !isSubdirectory { continue }

            let fileDiskOffset = bpb.clusterOffset(startingCluster)

            let file = CarvedFile(
                fileName: displayName,
                fileExtension: ext,
                sizeInBytes: Int64(fileSize),
                offsetOnDisk: fileDiskOffset
            )
            files.append(file)
        }

        return files
    }
}
