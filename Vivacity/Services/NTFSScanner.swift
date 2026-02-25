import Foundation
import os

/// Low-level NTFS filesystem scanner that reads the Master File Table ($MFT)
/// to discover deleted files.
///
/// ## How NTFS Deletion Works
/// Every file on NTFS has a record in the $MFT (Master File Table). Each MFT
/// record is typically 1024 bytes and contains attributes like filename (0x30),
/// data location (0x80), and standard info (0x10). When a file is deleted, the
/// "in use" flag in the record header is cleared, but the record often remains
/// intact — preserving the filename, size, and data run location.
///
/// ## Scan Strategy
/// 1. Parse the NTFS boot sector to find MFT location and record size
/// 2. Read MFT records sequentially
/// 3. For each record with the "in use" flag cleared, parse filename attribute
/// 4. Seek to the data run and verify magic bytes
/// 5. Emit `RecoverableFile` for validated matches
struct NTFSScanner: Sendable {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "NTFSScanner")

    // MARK: - NTFS Constants

    /// "FILE" signature at the start of every MFT record.
    private static let fileSignature: [UInt8] = [0x46, 0x49, 0x4C, 0x45] // "FILE"

    /// MFT record "in use" flag.
    private static let mftInUseFlag: UInt16 = 0x0001

    /// MFT record "is directory" flag.
    private static let mftDirectoryFlag: UInt16 = 0x0002

    /// Filename attribute type ID.
    private static let filenameAttributeType: UInt32 = 0x0000_0030

    /// Data attribute type ID.
    private static let dataAttributeType: UInt32 = 0x0000_0080

    /// End-of-attributes marker.
    private static let endMarker: UInt32 = 0xFFFF_FFFF

    // MARK: - Boot Sector

    /// Parsed NTFS boot sector parameters.
    private struct NTFSBoot {
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        let mftClusterNumber: UInt64
        let mftRecordSize: Int

        /// Bytes per cluster.
        var clusterSize: Int {
            bytesPerSector * sectorsPerCluster
        }

        /// Byte offset of the $MFT on disk.
        var mftOffset: UInt64 {
            mftClusterNumber * UInt64(clusterSize)
        }
    }

    // MARK: - Public API

    /// Scans an NTFS volume for deleted files by reading MFT records.
    func scan(
        volumeInfo: VolumeInfo,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let devicePath = volumeInfo.devicePath
        logger.info("Opening NTFS device: \(devicePath)")

        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            logger.error("Cannot open \(devicePath): \(err)")
            throw NTFSScanError.cannotOpenDevice(path: devicePath, reason: err)
        }
        defer { close(fd) }

        // Step 1: Parse the boot sector
        let boot = try parseBootSector(fd: fd)
        logger.info(
            """
            NTFS boot: \(boot.bytesPerSector) bytes/sector, \
            \(boot.sectorsPerCluster) sectors/cluster, \
            MFT at cluster \(boot.mftClusterNumber), \
            record size \(boot.mftRecordSize)
            """
        )

        // Step 2: Read MFT records
        var filesFound = 0
        var recordsScanned = 0
        let maxRecords = 100_000 // Safety limit

        var recordBuffer = [UInt8](repeating: 0, count: boot.mftRecordSize)

        for recordIndex in 0 ..< maxRecords {
            try Task.checkCancellation()

            let recordOffset = boot.mftOffset + UInt64(recordIndex) * UInt64(boot.mftRecordSize)

            let bytesRead = recordBuffer.withUnsafeMutableBytes { buf in
                pread(fd, buf.baseAddress!, boot.mftRecordSize, off_t(recordOffset))
            }

            // Stop if we can't read a full record
            guard bytesRead == boot.mftRecordSize else { break }

            // Verify "FILE" signature
            guard recordBuffer[0] == Self.fileSignature[0] &&
                recordBuffer[1] == Self.fileSignature[1] &&
                recordBuffer[2] == Self.fileSignature[2] &&
                recordBuffer[3] == Self.fileSignature[3]
            else {
                // Not a valid MFT record — might be end of MFT
                // Try a few more before giving up
                if recordsScanned > 100 { break }
                continue
            }

            recordsScanned += 1

            // Read flags at offset 22
            let flags = UInt16(recordBuffer[22]) | (UInt16(recordBuffer[23]) << 8)

            // We want records that are NOT in use (deleted) and NOT directories
            let isInUse = flags & Self.mftInUseFlag != 0
            let isDirectory = flags & Self.mftDirectoryFlag != 0

            if isInUse || isDirectory { continue }

            // Parse the record for filename and data attributes
            if let file = parseDeletedRecord(
                record: recordBuffer,
                boot: boot,
                fd: fd
            ) {
                filesFound += 1
                continuation.yield(.fileFound(file))
            }

            // Progress reporting
            if recordsScanned % 500 == 0 {
                let progress = 1.0 - (1.0 / (1.0 + Double(recordsScanned) / 5000.0))
                continuation.yield(.progress(min(progress, 0.90)))
                await Task.yield()
            }
        }

        logger.info("NTFS scan complete: \(filesFound) deleted file(s) found across \(recordsScanned) MFT records")
    }

    // MARK: - Boot Sector Parsing

    private func parseBootSector(fd: Int32) throws -> NTFSBoot {
        var sector = [UInt8](repeating: 0, count: 512)
        let bytesRead = sector.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress!, 512, 0)
        }
        guard bytesRead == 512 else {
            throw NTFSScanError.invalidBootSector
        }

        // Verify NTFS OEM ID at offset 3: "NTFS    "
        let oemID = String(bytes: sector[3 ..< 11], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard oemID == "NTFS" else {
            throw NTFSScanError.invalidBootSector
        }

        let bytesPerSector = Int(sector[11]) | (Int(sector[12]) << 8)
        let sectorsPerCluster = Int(sector[13])

        // MFT cluster number at offset 48 (8 bytes, little-endian)
        var mftCluster: UInt64 = 0
        for i in 0 ..< 8 {
            mftCluster |= UInt64(sector[48 + i]) << (i * 8)
        }

        // MFT record size: stored at offset 64 as a signed byte
        // If positive: clusters per record. If negative: 2^|value| bytes per record.
        let rawRecordSize = Int8(bitPattern: sector[64])
        let mftRecordSize = if rawRecordSize > 0 {
            Int(rawRecordSize) * bytesPerSector * sectorsPerCluster
        } else {
            1 << abs(Int(rawRecordSize))
        }

        guard bytesPerSector > 0, sectorsPerCluster > 0, mftRecordSize > 0 else {
            throw NTFSScanError.invalidBootSector
        }

        return NTFSBoot(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            mftClusterNumber: mftCluster,
            mftRecordSize: mftRecordSize
        )
    }

    // MARK: - MFT Record Parsing
    /// Parses a deleted MFT record to extract filename and verify data.
    private func parseDeletedRecord(
        record: [UInt8],
        boot: NTFSBoot,
        fd: Int32
    ) -> RecoverableFile? {
        let firstAttrOffset = Int(record[20]) | (Int(record[21]) << 8)
        guard firstAttrOffset >= 56, firstAttrOffset < record.count else { return nil }

        var fileName: String?
        var fileExtension: String?
        var fileSize: Int64 = 0
        var dataRunCluster: UInt64?

        var offset = firstAttrOffset
        while offset + 4 < record.count {
            let attrType = UInt32(record[offset]) |
                (UInt32(record[offset + 1]) << 8) |
                (UInt32(record[offset + 2]) << 16) |
                (UInt32(record[offset + 3]) << 24)

            if attrType == Self.endMarker { break }

            let attrLength = parseAttributeLength(record: record, offset: offset)
            guard attrLength > 0, offset + attrLength <= record.count else { break }

            if attrType == Self.filenameAttributeType {
                parseNameAttr(record: record, offset: offset, fileName: &fileName, fileExtension: &fileExtension)
            } else if attrType == Self.dataAttributeType {
                parseDataAttr(record: record, offset: offset, fileSize: &fileSize, dataRunCluster: &dataRunCluster)
            }
            offset += attrLength
        }

        guard let name = fileName, let ext = fileExtension else { return nil }
        guard fileSize > 0 else { return nil }
        guard let expectedSig = FileSignature.from(extension: ext) else { return nil }

        return buildRecoverableFile(
            parsed: ParsedRecord(name: name, ext: ext, fileSize: fileSize, dataRunCluster: dataRunCluster),
            expectedSig: expectedSig,
            boot: boot,
            fd: fd
        )
    }

    private struct ParsedRecord {
        let name: String
        let ext: String
        let fileSize: Int64
        let dataRunCluster: UInt64?
    }

    private func parseAttributeLength(record: [UInt8], offset: Int) -> Int {
        Int(record[offset + 4]) |
            (Int(record[offset + 5]) << 8) |
            (Int(record[offset + 6]) << 16) |
            (Int(record[offset + 7]) << 24)
    }

    private func parseNameAttr(record: [UInt8], offset: Int, fileName: inout String?, fileExtension: inout String?) {
        let parsed = parseFilenameAttribute(record: record, attrOffset: offset)
        if let parsed {
            if fileName == nil || parsed.namespace == 1 || parsed.namespace == 3 {
                fileName = parsed.name
                fileExtension = parsed.ext
            }
        }
    }

    private func parseDataAttr(record: [UInt8], offset: Int, fileSize: inout Int64, dataRunCluster: inout UInt64?) {
        let isResident = record[offset + 8] == 0
        if isResident {
            fileSize = Int64(record[offset + 16]) |
                (Int64(record[offset + 17]) << 8) |
                (Int64(record[offset + 18]) << 16) |
                (Int64(record[offset + 19]) << 24)
        } else {
            if offset + 56 <= record.count {
                fileSize = 0
                for i in 0 ..< 8 {
                    fileSize |= Int64(record[offset + 48 + i]) << (i * 8)
                }
                let dataRunOffset = Int(record[offset + 32]) | (Int(record[offset + 33]) << 8)
                if dataRunOffset > 0, offset + dataRunOffset + 1 < record.count {
                    dataRunCluster = parseFirstDataRun(record: record, runOffset: offset + dataRunOffset)
                }
            }
        }
    }

    private func buildRecoverableFile(
        parsed: ParsedRecord,
        expectedSig: FileSignature,
        boot: NTFSBoot,
        fd: Int32
    ) -> RecoverableFile? {
        if let cluster = parsed.dataRunCluster {
            let byteOffset = cluster * UInt64(boot.clusterSize)
            var header = [UInt8](repeating: 0, count: 16)
            let bytesRead = header.withUnsafeMutableBytes { buf in pread(fd, buf.baseAddress!, 16, off_t(byteOffset)) }
            guard bytesRead == 16 else { return nil }

            var matchedSig: FileSignature?
            if matchesSignature(header, signature: expectedSig) {
                matchedSig = expectedSig
            } else {
                for sig in FileSignature.allCases {
                    if matchesSignature(header, signature: sig) {
                        matchedSig = sig
                        break
                    }
                }
            }
            guard let sig = matchedSig else { return nil }

            return RecoverableFile(
                id: UUID(), fileName: parsed.name, fileExtension: parsed.ext, fileType: sig.category,
                sizeInBytes: parsed.fileSize, offsetOnDisk: byteOffset, signatureMatch: sig, source: .fastScan
            )
        }

        return RecoverableFile(
            id: UUID(), fileName: parsed.name, fileExtension: parsed.ext, fileType: expectedSig.category,
            sizeInBytes: parsed.fileSize, offsetOnDisk: 0, signatureMatch: expectedSig, source: .fastScan
        )
    }

    // MARK: - Filename Attribute

    private struct ParsedFilename {
        let name: String
        let ext: String
        let namespace: UInt8 // 0=POSIX, 1=Win32, 2=DOS, 3=Win32+DOS
    }

    /// Parses an NTFS $FILE_NAME attribute to extract the filename.
    private func parseFilenameAttribute(record: [UInt8], attrOffset: Int) -> ParsedFilename? {
        let isResident = record[attrOffset + 8] == 0
        guard isResident else { return nil }

        // Content offset within the attribute (2 bytes at attrOffset+20)
        let contentOffset = Int(record[attrOffset + 20]) | (Int(record[attrOffset + 21]) << 8)
        let absOffset = attrOffset + contentOffset

        // Filename length in characters at absOffset+64
        guard absOffset + 66 < record.count else { return nil }
        let nameLength = Int(record[absOffset + 64])
        let namespace = record[absOffset + 65]

        // Skip DOS-only names (short 8.3)
        if namespace == 2 { return nil }

        // Filename starts at absOffset+66, UTF-16LE encoded
        let nameStart = absOffset + 66
        guard nameStart + nameLength * 2 <= record.count else { return nil }

        var utf16: [UInt16] = []
        for i in 0 ..< nameLength {
            let ch = UInt16(record[nameStart + i * 2]) | (UInt16(record[nameStart + i * 2 + 1]) << 8)
            utf16.append(ch)
        }

        let fullName = String(utf16CodeUnits: utf16, count: utf16.count)
        let url = URL(fileURLWithPath: fullName)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        guard !name.isEmpty, !ext.isEmpty else { return nil }

        return ParsedFilename(name: name, ext: ext, namespace: namespace)
    }

    // MARK: - Data Run Parsing

    /// Parses the first data run to find the starting cluster.
    ///
    /// Data runs are encoded as variable-length pairs: a header byte specifies
    /// the number of bytes for length and offset fields.
    private func parseFirstDataRun(record: [UInt8], runOffset: Int) -> UInt64? {
        guard runOffset < record.count else { return nil }

        let header = record[runOffset]
        if header == 0 { return nil }

        let lengthBytes = Int(header & 0x0F)
        let offsetBytes = Int(header >> 4)

        guard lengthBytes > 0, offsetBytes > 0 else { return nil }
        guard runOffset + 1 + lengthBytes + offsetBytes <= record.count else { return nil }

        // Skip length field, read offset field
        let offsetStart = runOffset + 1 + lengthBytes
        var cluster: Int64 = 0
        for i in 0 ..< offsetBytes {
            cluster |= Int64(record[offsetStart + i]) << (i * 8)
        }

        // Sign-extend if the highest bit is set
        if offsetBytes > 0, record[offsetStart + offsetBytes - 1] & 0x80 != 0 {
            for i in offsetBytes ..< 8 {
                cluster |= Int64(0xFF) << (i * 8)
            }
        }

        return cluster >= 0 ? UInt64(cluster) : nil
    }

    // MARK: - Signature Matching

    private func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes
        guard header.count >= magic.count else { return false }
        for i in 0 ..< magic.count {
            if header[i] != magic[i] { return false }
        }

        if signature == .avi || signature == .webp {
            guard header.count >= 12 else { return true }
            let sub = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
            switch signature {
            case .avi: return sub == "AVI "
            case .webp: return sub == "WEBP"
            default: break
            }
        }

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

// MARK: - Errors

enum NTFSScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)
    case invalidBootSector

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path): \(reason)"
        case .invalidBootSector:
            "Invalid NTFS boot sector — this volume may not be NTFS formatted."
        }
    }
}
