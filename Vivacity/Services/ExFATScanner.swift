import Foundation
import os

/// Low-level ExFAT filesystem scanner that reads directory entries
/// to discover deleted files.
///
/// ## How ExFAT Deletion Works
/// ExFAT uses typed directory entries (32 bytes each). A file has three entries:
/// - **File Entry** (type 0x85): contains timestamps and attribute count
/// - **Stream Extension** (type 0xC0): contains file size and starting cluster
/// - **File Name** (type 0xC1): contains the UTF-16 filename
///
/// When deleted, the "InUse" bit (bit 7) in each entry's type byte is cleared:
/// - 0x85 → 0x05 (deleted file entry)
/// - 0xC0 → 0x40 (deleted stream extension)
/// - 0xC1 → 0x41 (deleted file name)
///
/// The rest of the entry content remains intact.
struct ExFATScanner: Sendable {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "ExFATScanner")

    // MARK: - ExFAT Constants

    /// InUse bit mask in directory entry type byte.
    private static let inUseBit: UInt8 = 0x80

    /// File entry type (in use).
    private static let fileEntryType: UInt8 = 0x85
    /// Deleted file entry type.
    private static let deletedFileEntryType: UInt8 = 0x05

    /// Stream extension type (in use).
    private static let streamExtType: UInt8 = 0xC0
    /// Deleted stream extension type.
    private static let deletedStreamExtType: UInt8 = 0x40

    /// File name entry type (in use).
    private static let fileNameType: UInt8 = 0xC1
    /// Deleted file name entry type.
    private static let deletedFileNameType: UInt8 = 0x41

    /// End of directory marker.
    private static let endOfDirectory: UInt8 = 0x00

    /// Directory entry size.
    private static let entrySize = 32

    // MARK: - Boot Sector

    private struct ExFATBoot {
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        let clusterHeapOffset: UInt32 // Sector offset of cluster 2
        let rootDirCluster: UInt32
        let totalClusters: UInt32

        var clusterSize: Int {
            bytesPerSector * sectorsPerCluster
        }

        func clusterOffset(_ cluster: UInt32) -> UInt64 {
            UInt64(clusterHeapOffset) * UInt64(bytesPerSector) +
                UInt64(cluster - 2) * UInt64(clusterSize)
        }
    }

    // MARK: - Public API

    /// Scans an ExFAT volume for deleted files.
    func scan(
        volumeInfo: VolumeInfo,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let devicePath = volumeInfo.devicePath
        logger.info("Opening ExFAT device: \(devicePath)")

        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            logger.error("Cannot open \(devicePath): \(err)")
            throw ExFATScanError.cannotOpenDevice(path: devicePath, reason: err)
        }
        defer { close(fd) }

        // Step 1: Parse boot sector
        let boot = try parseBootSector(fd: fd)
        logger.info(
            // swiftlint:disable:next line_length
            "ExFAT boot: \(boot.bytesPerSector) bytes/sector, \(boot.sectorsPerCluster) sectors/cluster, root cluster \(boot.rootDirCluster)"
        )

        // Step 2: Scan directory tree starting from root
        var filesFound = 0
        var directoriesScanned = 0
        var clustersToScan: [UInt32] = [boot.rootDirCluster]
        var visitedClusters: Set<UInt32> = []

        while let cluster = clustersToScan.first {
            clustersToScan.removeFirst()

            guard !visitedClusters.contains(cluster) else { continue }
            visitedClusters.insert(cluster)

            try Task.checkCancellation()

            let results = try scanDirectoryCluster(
                fd: fd,
                cluster: cluster,
                boot: boot
            )

            for result in results.files {
                filesFound += 1
                continuation.yield(.fileFound(result))
            }

            // Queue subdirectories
            for subDir in results.subdirectories {
                if !visitedClusters.contains(subDir) {
                    clustersToScan.append(subDir)
                }
            }

            directoriesScanned += 1

            if directoriesScanned % 10 == 0 {
                let progress = 1.0 - (1.0 / (1.0 + Double(directoriesScanned) / 100.0))
                continuation.yield(.progress(min(progress, 0.90)))
                await Task.yield()
            }
        }

        logger.info("ExFAT scan complete: \(filesFound) deleted file(s) across \(directoriesScanned) directories")
    }

    // MARK: - Boot Sector

    private func parseBootSector(fd: Int32) throws -> ExFATBoot {
        var sector = [UInt8](repeating: 0, count: 512)
        let bytesRead = sector.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress!, 512, 0)
        }
        guard bytesRead == 512 else {
            throw ExFATScanError.invalidBootSector
        }

        // Verify ExFAT signature at offset 3: "EXFAT   "
        let sig = String(bytes: sector[3 ..< 11], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard sig == "EXFAT" else {
            throw ExFATScanError.invalidBootSector
        }

        // Bytes per sector: 2^(value at offset 108)
        let sectorShift = Int(sector[108])
        let bytesPerSector = 1 << sectorShift

        // Sectors per cluster: 2^(value at offset 109)
        let clusterShift = Int(sector[109])
        let sectorsPerCluster = 1 << clusterShift

        // Cluster heap offset at offset 88 (4 bytes)
        let heapOffset = UInt32(sector[88]) | (UInt32(sector[89]) << 8) |
            (UInt32(sector[90]) << 16) | (UInt32(sector[91]) << 24)

        // Root directory cluster at offset 96 (4 bytes)
        let rootCluster = UInt32(sector[96]) | (UInt32(sector[97]) << 8) |
            (UInt32(sector[98]) << 16) | (UInt32(sector[99]) << 24)

        // Total clusters at offset 92 (4 bytes)
        let totalClusters = UInt32(sector[92]) | (UInt32(sector[93]) << 8) |
            (UInt32(sector[94]) << 16) | (UInt32(sector[95]) << 24)

        guard bytesPerSector > 0, sectorsPerCluster > 0 else {
            throw ExFATScanError.invalidBootSector
        }

        return ExFATBoot(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            clusterHeapOffset: heapOffset,
            rootDirCluster: rootCluster,
            totalClusters: totalClusters
        )
    }

    // MARK: - Directory Scanning

    private struct ScanResults {
        var files: [RecoverableFile] = []
        var subdirectories: [UInt32] = []
    }

    private func scanDirectoryCluster(
        fd: Int32,
        cluster: UInt32,
        boot: ExFATBoot
    ) throws -> ScanResults {
        let offset = boot.clusterOffset(cluster)
        let clusterSize = boot.clusterSize
        var buffer = [UInt8](repeating: 0, count: clusterSize)

        let bytesRead = buffer.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress!, clusterSize, off_t(offset))
        }
        guard bytesRead == clusterSize else { return ScanResults() }

        var results = ScanResults()
        let entryCount = clusterSize / Self.entrySize
        var i = 0

        while i < entryCount {
            let entryOffset = i * Self.entrySize
            let typeByte = buffer[entryOffset]

            if typeByte == Self.endOfDirectory { break }

            // Look for deleted file entry sets
            if typeByte == Self.deletedFileEntryType {
                // Read the secondary count from the file entry
                let secondaryCount = Int(buffer[entryOffset + 1])

                // We need at least a stream extension and a file name entry
                guard secondaryCount >= 2, i + secondaryCount < entryCount else {
                    i += 1
                    continue
                }

                // Parse the deleted entry set
                if let file = parseDeletedEntrySet(
                    buffer: buffer,
                    startIndex: i,
                    secondaryCount: secondaryCount,
                    boot: boot,
                    fd: fd
                ) {
                    results.files.append(file)
                }

                i += 1 + secondaryCount
                continue
            }

            // Track live subdirectories for recursive scanning
            if typeByte == Self.fileEntryType {
                let attrs = UInt16(buffer[entryOffset + 4]) | (UInt16(buffer[entryOffset + 5]) << 8)
                let isDir = attrs & 0x10 != 0
                let secondaryCount = Int(buffer[entryOffset + 1])

                if isDir, secondaryCount >= 2, i + 1 < entryCount {
                    // Stream extension is the next entry
                    let streamOffset = (i + 1) * Self.entrySize
                    if buffer[streamOffset] == Self.streamExtType {
                        let dirCluster = UInt32(buffer[streamOffset + 20]) |
                            (UInt32(buffer[streamOffset + 21]) << 8) |
                            (UInt32(buffer[streamOffset + 22]) << 16) |
                            (UInt32(buffer[streamOffset + 23]) << 24)
                        if dirCluster >= 2 {
                            results.subdirectories.append(dirCluster)
                        }
                    }
                }

                i += 1 + secondaryCount
                continue
            }

            i += 1
        }

        return results
    }

    /// Parses a deleted ExFAT directory entry set (file + stream ext + file name).
    private func parseDeletedEntrySet(
        buffer: [UInt8],
        startIndex: Int,
        secondaryCount: Int,
        boot: ExFATBoot,
        fd: Int32
    ) -> RecoverableFile? {
        var startingCluster: UInt32 = 0
        var fileSize: Int64 = 0
        var fileName = ""

        for j in 1 ... secondaryCount {
            let offset = (startIndex + j) * Self.entrySize
            guard offset + Self.entrySize <= buffer.count else { break }

            let type = buffer[offset]

            if type == Self.deletedStreamExtType {
                // Stream extension: starting cluster at offset 20, file size at offset 24
                startingCluster = UInt32(buffer[offset + 20]) |
                    (UInt32(buffer[offset + 21]) << 8) |
                    (UInt32(buffer[offset + 22]) << 16) |
                    (UInt32(buffer[offset + 23]) << 24)

                fileSize = 0
                for k in 0 ..< 8 {
                    fileSize |= Int64(buffer[offset + 24 + k]) << (k * 8)
                }
            } else if type == Self.deletedFileNameType {
                // File name: UTF-16LE characters starting at offset 2
                let nameLen = Int(buffer[offset + 1]) // General secondary flags has name length
                // Actually in ExFAT, the name length is in the stream extension entry
                // File name entries contain up to 15 UTF-16 chars starting at offset 2
                var chars: [UInt16] = []
                for k in stride(from: 2, to: 30, by: 2) {
                    let ch = UInt16(buffer[offset + k]) | (UInt16(buffer[offset + k + 1]) << 8)
                    if ch == 0x0000 { break }
                    chars.append(ch)
                }
                let namePart = String(utf16CodeUnits: chars, count: chars.count)
                fileName += namePart
                _ = nameLen // Suppress unused warning
            }
        }

        guard !fileName.isEmpty, fileSize > 0, startingCluster >= 2 else { return nil }

        let url = URL(fileURLWithPath: fileName)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        guard let expectedSig = FileSignature.from(extension: ext) else { return nil }

        // Verify magic bytes at starting cluster
        let clusterOffset = boot.clusterOffset(startingCluster)
        var header = [UInt8](repeating: 0, count: 16)
        let headerRead = header.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress!, 16, off_t(clusterOffset))
        }
        guard headerRead == 16 else { return nil }

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
            id: UUID(),
            fileName: name,
            fileExtension: ext,
            fileType: sig.category,
            sizeInBytes: fileSize,
            offsetOnDisk: clusterOffset,
            signatureMatch: sig,
            source: .fastScan
        )
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

enum ExFATScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)
    case invalidBootSector

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path): \(reason)"
        case .invalidBootSector:
            "Invalid ExFAT boot sector — this volume may not be ExFAT formatted."
        }
    }
}
