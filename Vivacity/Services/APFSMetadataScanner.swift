import Foundation
import os

/// A first-pass APFS metadata scanner for image-backed APFS sources.
///
/// This scanner prefers structured APFS metadata recovery when it can resolve:
/// - directory records for names and paths
/// - inode records for file size and stream identifiers
/// - file extent records for physical byte ranges
///
/// When structured metadata is incomplete, it falls back to the earlier hint-based
/// approach that pairs APFS-looking metadata strings with nearby image signatures.
struct APFSMetadataScanner {
    struct MetadataHint: Hashable {
        let absoluteOffset: UInt64
        let path: String
        let fileName: String
        let signature: FileSignature
    }

    struct ImageCandidate {
        let absoluteOffset: UInt64
        let signature: FileSignature
    }

    struct RecoveryMatchState {
        var seenOffsets: Set<UInt64> = []
        var pendingHints: [MetadataHint] = []
    }

    struct StructuredInodeRecord {
        let objectID: UInt64
        let parentID: UInt64
        let privateID: UInt64
        let uncompressedSize: UInt64
        let mode: UInt16

        var isRegularFile: Bool {
            mode & Self.fileTypeMask == Self.regularFileMode
        }

        private static let fileTypeMask: UInt16 = 0xF000
        private static let regularFileMode: UInt16 = 0x8000
    }

    struct StructuredDirectoryRecord: Hashable {
        let parentID: UInt64
        let fileID: UInt64
        let name: String
    }

    struct StructuredExtentRecord: Hashable {
        let ownerID: UInt64
        let logicalAddress: UInt64
        let physicalBlockNumber: UInt64
        let length: UInt64
    }

    struct StructuredRecordBatch {
        var inodes: [StructuredInodeRecord] = []
        var directoryRecords: [StructuredDirectoryRecord] = []
        var extents: [StructuredExtentRecord] = []
    }

    struct StructuredRecoveryState {
        var emittedFileIDs: Set<UInt64> = []
        var inodesByID: [UInt64: StructuredInodeRecord] = [:]
        var directoryRecordsByFileID: [UInt64: [StructuredDirectoryRecord]] = [:]
        var extentsByOwnerID: [UInt64: [StructuredExtentRecord]] = [:]

        mutating func merge(_ batch: StructuredRecordBatch) {
            for inode in batch.inodes {
                inodesByID[inode.objectID] = inode
            }

            for record in batch.directoryRecords {
                var records = directoryRecordsByFileID[record.fileID, default: []]
                if !records.contains(record) {
                    records.append(record)
                    directoryRecordsByFileID[record.fileID] = records
                }
            }

            for extent in batch.extents {
                var extents = extentsByOwnerID[extent.ownerID, default: []]
                if !extents.contains(extent) {
                    extents.append(extent)
                    extentsByOwnerID[extent.ownerID] = extents
                }
            }
        }
    }

    struct KeyValueLocation {
        let keyOffset: Int
        let keyLength: Int
        let valueOffset: Int
        let valueLength: Int
    }

    struct StructuredScanGeometry {
        let blockSize: Int
        let totalBytes: UInt64
    }

    let logger = Logger(subsystem: "com.vivacity.app", category: "APFSMetadata")
    let footerDetector: FileFooterDetecting
    let mp4Reconstructor: MP4Reconstructing
    let signatureMatcher = DeepScanService()
    let chunkSize = 1 * 1024 * 1024
    let overlapSize = 128 * 1024
    let maxHintDistance: UInt64 = 8 * 1024 * 1024

    let objectIDMask: UInt64 = 0x0FFF_FFFF_FFFF_FFFF
    let objectTypeMask: UInt32 = 0x0000_FFFF
    let recordTypeShift: UInt64 = 60
    let btreeNodeObjectType: UInt32 = 3
    let btreeRootFlag: UInt16 = 0x0001
    let btreeLeafFlag: UInt16 = 0x0002
    let fixedNodeHeaderSize = 56
    let kvLocationSize = 8
    let btreeInfoSize = 40
    let inodeRecordType: UInt64 = 3
    let fileExtentRecordType: UInt64 = 8
    let directoryRecordType: UInt64 = 9
    let directoryNameLengthMask: UInt32 = 0x0000_03FF
    let fileExtentLengthMask: UInt64 = 0x00FF_FFFF_FFFF_FFFF
    let readVerificationBytes = 256

    init(
        footerDetector: FileFooterDetecting = FileFooterDetector(),
        mp4Reconstructor: MP4Reconstructing = MP4Reconstructor()
    ) {
        self.footerDetector = footerDetector
        self.mp4Reconstructor = mp4Reconstructor
    }

    func scan(
        volumeInfo: VolumeInfo,
        reader: any PrivilegedDiskReading,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        guard totalBytes > 0 else {
            continuation.yield(.progress(1.0))
            return
        }
        guard reader.isSeekable else {
            logger.warning("APFS metadata scan skipped because reader is not seekable")
            continuation.yield(.progress(1.0))
            return
        }

        let blockSize = detectAPFSBlockSize(reader: reader) ?? max(volumeInfo.blockSize, 4096)
        let geometry = StructuredScanGeometry(blockSize: blockSize, totalBytes: totalBytes)
        let startMessage =
            "APFS metadata scan started path=\(volumeInfo.devicePath) " +
            "blockSize=\(blockSize) totalBytes=\(totalBytes)"
        logger.info("\(startMessage, privacy: .public)")

        var recoveryState = RecoveryMatchState()
        var structuredState = StructuredRecoveryState()
        var carry = Data()
        var offset: UInt64 = 0

        while offset < totalBytes {
            try Task.checkCancellation()

            let bytesToRead = min(UInt64(chunkSize), totalBytes - offset)
            guard let chunk = readChunk(reader: reader, offset: offset, length: Int(bytesToRead)) else {
                break
            }
            if chunk.isEmpty {
                break
            }

            let combined = carry + chunk
            let combinedStart = offset >= UInt64(carry.count) ? offset - UInt64(carry.count) : 0
            let dedupeFloor = offset

            let structuredRecords = extractStructuredRecords(
                from: combined,
                absoluteStart: combinedStart,
                blockSize: blockSize,
                minimumOffset: dedupeFloor
            )
            structuredState.merge(structuredRecords)

            try emitStructuredRecoveredFiles(
                geometry: geometry,
                structuredState: &structuredState,
                recoveryState: &recoveryState,
                reader: reader,
                continuation: continuation
            )

            let newHints = extractMetadataHints(
                from: combined,
                absoluteStart: combinedStart,
                blockSize: blockSize
            )
            .filter { $0.absoluteOffset >= dedupeFloor }

            recoveryState.pendingHints.append(contentsOf: newHints)
            recoveryState.pendingHints = pruneHints(
                recoveryState.pendingHints,
                minimumOffset: dedupeFloor
            )

            let candidates = detectImageCandidates(
                in: combined,
                absoluteStart: combinedStart,
                dedupeFloor: dedupeFloor
            )

            try await emitRecoveredFiles(
                from: candidates,
                totalBytes: totalBytes,
                recoveryState: &recoveryState,
                reader: reader,
                continuation: continuation
            )

            offset += UInt64(chunk.count)
            carry = Data(combined.suffix(min(overlapSize, combined.count)))
            continuation.yield(.progress(min(Double(offset) / Double(totalBytes), 1.0)))
            await Task.yield()
        }

        continuation.yield(.progress(1.0))
        let completionMessage =
            "APFS metadata scan completed structuredHits=\(structuredState.emittedFileIDs.count) " +
            "fallbackHits=\(recoveryState.seenOffsets.count)"
        logger.info("\(completionMessage, privacy: .public)")
    }

    private func readChunk(
        reader: any PrivilegedDiskReading,
        offset: UInt64,
        length: Int
    ) -> Data? {
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            reader.read(
                into: buffer.baseAddress!,
                offset: offset,
                length: length
            )
        }
        guard bytesRead > 0 else { return nil }
        data.removeSubrange(bytesRead ..< data.count)
        return data
    }

    private func detectAPFSBlockSize(reader: any PrivilegedDiskReading) -> Int? {
        guard let header = readChunk(reader: reader, offset: 0, length: 4096), header.count >= 40 else {
            return nil
        }
        let bytes = [UInt8](header)
        guard magic(in: bytes, at: 32) == "BSXN" else { return nil }
        let blockSize = Int(readLittleEndianUInt32(bytes, at: 36))
        return blockSize >= 4096 ? blockSize : nil
    }

    func estimateSize(
        for signature: FileSignature,
        at offset: UInt64,
        reader: any PrivilegedDiskReading
    ) async throws -> Int64? {
        switch signature {
        case .heic, .heif, .avif, .cr3:
            guard let size = mp4Reconstructor.calculateContiguousSize(startingAt: offset, reader: reader) else {
                return nil
            }
            return Int64(size)
        default:
            return try await footerDetector.estimateSize(
                signature: signature,
                startOffset: offset,
                reader: reader,
                maxScanBytes: 64 * 1024 * 1024
            )
        }
    }

    func baseName(from fileName: String, fallbackOffset: UInt64) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "Recovered_APFS_\(fallbackOffset)" : base
    }

    func signature(forFileName fileName: String) -> FileSignature? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return signature(forExtension: ext)
    }

    func signature(forExtension ext: String) -> FileSignature? {
        switch ext {
        case "jpeg":
            .jpeg
        case "tif":
            .tiff
        default:
            FileSignature.from(extension: ext)
        }
    }

    func magic(in bytes: [UInt8], at offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset ..< offset + 4], encoding: .utf8) ?? ""
    }

    func readLittleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset])
            | UInt16(bytes[offset + 1]) << 8
    }

    func readLittleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    func readLittleEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        return UInt64(bytes[offset])
            | UInt64(bytes[offset + 1]) << 8
            | UInt64(bytes[offset + 2]) << 16
            | UInt64(bytes[offset + 3]) << 24
            | UInt64(bytes[offset + 4]) << 32
            | UInt64(bytes[offset + 5]) << 40
            | UInt64(bytes[offset + 6]) << 48
            | UInt64(bytes[offset + 7]) << 56
    }
}
