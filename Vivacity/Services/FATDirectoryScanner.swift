import Foundation
import os

/// Low-level FAT32 filesystem scanner that reads raw directory entries
/// to discover deleted files (those marked with `0xE5`).
///
/// ## How FAT32 Deletion Works
/// When a file is deleted on FAT32, only the first byte of its directory entry
/// is changed to `0xE5`. The rest of the entry — including the filename, starting
/// cluster, and file size — remains intact until overwritten by a new file.
///
/// ## Scan Strategy
/// 1. Parse the Boot Parameter Block (BPB) from sector 0
/// 2. Read the FAT table to check cluster allocation status
/// 3. Walk directory entry clusters looking for `0xE5` markers
/// 4. For each deleted entry, seek to its starting cluster and verify magic bytes
/// 5. Emit `RecoverableFile` for validated matches
struct FATDirectoryScanner: Sendable {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FATScanner")

    // MARK: - FAT32 Constants

    /// A deleted directory entry starts with this byte.
    private static let deletedMarker: UInt8 = 0xE5

    /// End-of-directory marker.
    private static let endOfDirectory: UInt8 = 0x00

    /// Long File Name entry attribute byte.
    private static let lfnAttribute: UInt8 = 0x0F

    /// Directory entry size in bytes.
    private static let directoryEntrySize = 32

    /// FAT32 free cluster marker.
    private static let fatFreeCluster: UInt32 = 0x0000_0000

    /// FAT32 end-of-chain markers (>= this value).
    private static let fatEndOfChain: UInt32 = 0x0FFF_FFF8

    /// FAT32 bad cluster marker.
    private static let fatBadCluster: UInt32 = 0x0FFF_FFF7

    // MARK: - Recovery Confidence

    /// How confident we are that a deleted file can be recovered.
    enum Confidence: String, Sendable {
        case high // Clusters are marked free in FAT
        case medium // Could not verify cluster status
        case low // Clusters are in use (likely overwritten)
    }

    // MARK: - Public API

    /// Scans a FAT32 volume for deleted files by reading raw directory entries.
    ///
    /// - Parameters:
    ///   - volumeInfo: Volume metadata including device path and mount point.
    ///   - reader: PrivilegedDiskReading for raw sector access.
    ///   - continuation: Stream continuation to yield scan events.
    func scan(
        volumeInfo: VolumeInfo,
        reader: any PrivilegedDiskReading,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let devicePath = volumeInfo.devicePath
        logger.info("Starting FAT32 raw catalog scan on: \(devicePath)")

        // Step 1: Parse the BPB
        let bpb = try parseBPB(reader: reader)
        logger.info(
            """
            BPB: \(bpb.bytesPerSector) bytes/sector, \
            \(bpb.sectorsPerCluster) sectors/cluster, \
            root cluster \(bpb.rootCluster)
            """
        )

        // Step 2: Read the FAT table (first copy)
        let fat = try readFATTable(reader: reader, bpb: bpb)
        logger.info("FAT table loaded: \(fat.count) entries")

        // Step 3: Scan directory entries starting from root
        var filesFound = 0
        var directoriesScanned = 0
        var clustersToScan: [UInt32] = [bpb.rootCluster]
        var visitedClusters: Set<UInt32> = []

        while let cluster = clustersToScan.first {
            clustersToScan.removeFirst()

            try Task.checkCancellation()

            // Follow the cluster chain for this directory
            var currentCluster = cluster
            while currentCluster >= 2, currentCluster < Self.fatEndOfChain {
                guard !visitedClusters.contains(currentCluster) else { break }
                visitedClusters.insert(currentCluster)

                try Task.checkCancellation()

                let entries = try readDirectoryEntries(
                    reader: reader,
                    cluster: currentCluster,
                    bpb: bpb
                )

                let result = processEntries(
                    entries: entries,
                    bpb: bpb,
                    fat: fat,
                    reader: reader,
                    continuation: continuation
                )

                clustersToScan.append(contentsOf: result.newClusters)
                filesFound += result.filesFoundDelta

                if result.endOfDir { break }

                directoriesScanned += 1

                // Report progress periodically
                if directoriesScanned % 10 == 0 {
                    let heuristicProgress = 1.0 - (1.0 / (1.0 + Double(directoriesScanned) / 100.0))
                    continuation.yield(.progress(min(heuristicProgress, 0.90)))
                    await Task.yield()
                }

                // Follow the chain to the next cluster of this directory
                if Int(currentCluster) < fat.count {
                    let nextCluster = fat[Int(currentCluster)]
                    if nextCluster >= 2, nextCluster < Self.fatEndOfChain {
                        currentCluster = nextCluster
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }

        logger.info(
            "FAT scan complete: \(filesFound) deleted file(s) found across \(directoriesScanned) directory cluster(s)"
        )
    }

    private struct ProcessResult {
        let newClusters: [UInt32]
        let filesFoundDelta: Int
        let endOfDir: Bool
    }

    private func processEntries(
        entries: [FATDirectoryEntry],
        bpb: BPB,
        fat: [UInt32],
        reader: any PrivilegedDiskReading,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) -> ProcessResult {
        var newClusters: [UInt32] = []
        var filesFoundDelta = 0
        var endOfDir = false

        for entry in entries {
            if entry.isEndOfDirectory {
                endOfDir = true
                break
            }

            // If this is a subdirectory (not deleted), queue it for scanning
            if entry.isSubdirectory, !entry.isDeleted, entry.startingCluster >= 2 {
                newClusters.append(entry.startingCluster)
            }

            guard entry.isDeleted, !entry.isSubdirectory, !entry.isVolumeLabel else {
                continue
            }
            guard entry.startingCluster >= 2 else { continue }
            guard entry.fileSize > 0 else { continue }

            let confidence = checkClusterStatus(cluster: entry.startingCluster, fat: fat)
            guard confidence != .low else { continue }

            let signature = verifyMagicBytes(
                reader: reader,
                cluster: entry.startingCluster,
                bpb: bpb,
                expectedExtension: entry.fileExtension
            )

            guard let sig = signature else { continue }

            filesFoundDelta += 1
            let file = RecoverableFile(
                id: UUID(),
                fileName: entry.fileName,
                fileExtension: entry.fileExtension,
                fileType: sig.category,
                sizeInBytes: Int64(entry.fileSize),
                offsetOnDisk: bpb.clusterOffset(entry.startingCluster),
                signatureMatch: sig,
                source: .fastScan
            )
            continuation.yield(.fileFound(file))
        }

        return ProcessResult(newClusters: newClusters, filesFoundDelta: filesFoundDelta, endOfDir: endOfDir)
    }

    // MARK: - BPB Parsing

    private func parseBPB(reader: any PrivilegedDiskReading) throws -> BPB {
        var sector = [UInt8](repeating: 0, count: 512)
        let bytesRead = sector.withUnsafeMutableBytes { buf in
            reader.read(into: buf.baseAddress!, offset: 0, length: 512)
        }
        guard bytesRead == 512 else {
            throw FATScanError.invalidBootSector
        }

        guard let bpb = BPB(bootSector: sector) else {
            throw FATScanError.invalidBootSector
        }
        return bpb
    }

    // MARK: - FAT Table

    /// Reads the entire first FAT table into memory as an array of UInt32 cluster values.
    private func readFATTable(reader: any PrivilegedDiskReading, bpb: BPB) throws -> [UInt32] {
        let fatByteSize = bpb.fatSize
        var fatData = [UInt8](repeating: 0, count: fatByteSize)

        let bytesRead = fatData.withUnsafeMutableBytes { buf in
            reader.read(into: buf.baseAddress!, offset: UInt64(bpb.fatOffset), length: fatByteSize)
        }
        guard bytesRead == fatByteSize else {
            throw FATScanError.cannotReadFAT
        }

        // Convert bytes to UInt32 entries (each FAT32 entry is 4 bytes, little-endian)
        let entryCount = fatByteSize / 4
        var entries = [UInt32](repeating: 0, count: entryCount)
        for i in 0 ..< entryCount {
            let offset = i * 4
            entries[i] = UInt32(fatData[offset]) |
                (UInt32(fatData[offset + 1]) << 8) |
                (UInt32(fatData[offset + 2]) << 16) |
                (UInt32(fatData[offset + 3]) << 24)
            entries[i] &= 0x0FFF_FFFF // Mask to 28 bits (FAT32 uses 28-bit entries)
        }

        return entries
    }

    // MARK: - Directory Entry Parsing

    /// Reads all directory entries from a single cluster, reconstructing LFN names.
    ///
    /// FAT32 Long File Names work as follows:
    /// - LFN entries appear *before* the 8.3 short entry they belong to
    /// - They are stored in reverse order (last segment first)
    /// - Each LFN entry carries 13 UCS-2 characters across three byte ranges
    /// - The 8.3 entry that follows contains the actual file metadata
    private func readDirectoryEntries(
        reader: any PrivilegedDiskReading,
        cluster: UInt32,
        bpb: BPB
    ) throws -> [FATDirectoryEntry] {
        let offset = bpb.clusterOffset(cluster)
        let clusterSize = bpb.clusterSize
        var buffer = [UInt8](repeating: 0, count: clusterSize)

        let bytesRead = buffer.withUnsafeMutableBytes { buf in
            reader.read(into: buf.baseAddress!, offset: offset, length: clusterSize)
        }
        guard bytesRead == clusterSize else {
            return []
        }

        let entryCount = clusterSize / Self.directoryEntrySize
        var entries: [FATDirectoryEntry] = []

        // Accumulate LFN segments as we encounter them
        var lfnSegments: [(order: Int, chars: [UInt16])] = []

        for i in 0 ..< entryCount {
            let entryOffset = i * Self.directoryEntrySize
            let entryBytes = Array(buffer[entryOffset ..< (entryOffset + Self.directoryEntrySize)])

            let firstByte = entryBytes[0]

            // End of directory
            if firstByte == Self.endOfDirectory {
                entries.append(FATDirectoryEntry(
                    rawBytes: entryBytes,
                    isDeleted: false,
                    isEndOfDirectory: true,
                    isSubdirectory: false,
                    isVolumeLabel: false,
                    fileName: "",
                    fileExtension: "",
                    startingCluster: 0,
                    fileSize: 0
                ))
                break
            }

            let attributes = entryBytes[11]

            // Collect LFN entry
            if attributes == Self.lfnAttribute {
                let lfnChars = LFNParser.extractLFNCharacters(from: entryBytes)
                let order = Int(firstByte & 0x3F) // Sequence number (1-based)
                lfnSegments.append((order: order, chars: lfnChars))
                continue
            }

            // This is a short (8.3) entry — attach accumulated LFN if present
            let isDeleted = firstByte == Self.deletedMarker
            let isSubdirectory = attributes & 0x10 != 0
            let isVolumeLabel = attributes & 0x08 != 0

            // Reconstruct LFN if we have segments
            let longName = LFNParser.reconstructLFN(from: lfnSegments)
            lfnSegments.removeAll() // Reset for next file

            // Parse 8.3 filename as fallback
            var nameBytes = Array(entryBytes[0 ..< 8])
            if isDeleted {
                nameBytes[0] = 0x5F // Replace 0xE5 with '_' for display
            }
            let shortName = String(bytes: nameBytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let ext = String(bytes: Array(entryBytes[8 ..< 11]), encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""

            // Use LFN if available, otherwise use 8.3 name
            let displayName: String
            if let lfn = longName {
                // LFN includes the extension — split it
                let lfnURL = URL(fileURLWithPath: lfn)
                let lfnBase = lfnURL.deletingPathExtension().lastPathComponent
                displayName = lfnBase.isEmpty ? shortName : lfnBase
            } else {
                displayName = shortName
            }

            // Starting cluster: high word at offset 20, low word at offset 26
            let clusterHigh = UInt32(entryBytes[20]) | (UInt32(entryBytes[21]) << 8)
            let clusterLow = UInt32(entryBytes[26]) | (UInt32(entryBytes[27]) << 8)
            let startingCluster = (clusterHigh << 16) | clusterLow

            // File size at offset 28 (4 bytes, little-endian)
            let fileSize = UInt32(entryBytes[28]) | (UInt32(entryBytes[29]) << 8) |
                (UInt32(entryBytes[30]) << 16) | (UInt32(entryBytes[31]) << 24)

            entries.append(FATDirectoryEntry(
                rawBytes: entryBytes,
                isDeleted: isDeleted,
                isEndOfDirectory: false,
                isSubdirectory: isSubdirectory,
                isVolumeLabel: isVolumeLabel,
                fileName: displayName,
                fileExtension: ext,
                startingCluster: startingCluster,
                fileSize: fileSize
            ))
        }

        return entries
    }

    // MARK: - Cluster Validation

    /// Checks whether the starting cluster of a deleted file is marked as free.
    private func checkClusterStatus(cluster: UInt32, fat: [UInt32]) -> Confidence {
        guard Int(cluster) < fat.count else { return .medium }

        let fatEntry = fat[Int(cluster)]
        if fatEntry == Self.fatFreeCluster {
            return .high // Cluster is free — data likely intact
        } else if fatEntry == Self.fatBadCluster {
            return .low // Bad cluster
        } else {
            return .low // Cluster is in use — data likely overwritten
        }
    }

    // MARK: - Magic Byte Verification

    /// Reads the first 16 bytes at the given cluster and checks for a known signature.
    private func verifyMagicBytes(
        reader: any PrivilegedDiskReading,
        cluster: UInt32,
        bpb: BPB,
        expectedExtension: String
    ) -> FileSignature? {
        let offset = bpb.clusterOffset(cluster)
        var header = [UInt8](repeating: 0, count: 16)

        let bytesRead = header.withUnsafeMutableBytes { buf in
            reader.read(into: buf.baseAddress!, offset: offset, length: 16)
        }
        guard bytesRead == 16 else { return nil }

        // First try to match against the expected extension
        if let expectedSig = FileSignature.from(extension: expectedExtension) {
            if matchesSignature(header, signature: expectedSig) {
                return expectedSig
            }
        }

        // If extension didn't match, try all signatures (filename might be wrong)
        for signature in FileSignature.allCases {
            if matchesSignature(header, signature: signature) {
                return signature
            }
        }

        return nil
    }

    /// Checks whether the header bytes match a file signature.
    private func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes
        guard header.count >= magic.count else { return false }

        for i in 0 ..< magic.count {
            if header[i] != magic[i] { return false }
        }

        // Disambiguate RIFF-based formats
        if signature == .avi || signature == .webp {
            guard header.count >= 12 else { return true }
            let sub = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
            switch signature {
            case .avi: return sub == "AVI "
            case .webp: return sub == "WEBP"
            default: break
            }
        }

        // Disambiguate ftyp-based formats
        switch signature {
        case .mp4, .mov, .heic, .heif, .m4v, .threeGP:
            guard header.count >= 8 else { return true }
            let ftyp = String(bytes: header[4 ..< 8], encoding: .ascii) ?? ""
            return ftyp == "ftyp"
        default:
            return true
        }
    }
}
