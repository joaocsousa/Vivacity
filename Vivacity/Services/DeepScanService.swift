import Foundation
import os

/// Service that performs raw sector-by-sector scanning using magic byte signatures.
///
/// Opens the volume (or its raw device node) for reading and scans sequentially
/// for magic-byte patterns. Generates file names for discovered files and
/// deduplicates against offsets already found by `FastScanService`.
struct DeepScanService: Sendable {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeepScan")

    /// Size of each read block (512 bytes = one disk sector).
    private static let sectorSize = 512

    /// How many sectors to read at once for performance (256 sectors = 128 KB).
    private static let readChunkSectors = 256

    /// Maximum length of bytes we check for a signature header.
    private static let maxSignatureLength = 12

    // MARK: - Signatures to scan for

    /// Pre-built list of (signature, magicBytes) pairs for efficient matching.
    /// Excludes signatures with ambiguous short prefixes that need extra context
    /// (ftyp-based formats are handled separately).
    private static let directSignatures: [(FileSignature, [UInt8])] = {
        // Signatures with unique, unambiguous magic bytes
        let unambiguous: [FileSignature] = [
            .jpeg, .png, .bmp, .gif, .mkv, .wmv, .flv,
        ]
        return unambiguous.map { ($0, $0.magicBytes) }
    }()

    // MARK: - Public API

    /// Scans the given device by reading raw bytes sector-by-sector.
    ///
    /// - Parameters:
    ///   - device: The device to scan.
    ///   - existingOffsets: Offsets already discovered by Fast Scan, used for deduplication.
    /// - Returns: An `AsyncThrowingStream` of ``ScanEvent`` values.
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await performScan(
                        device: device,
                        existingOffsets: existingOffsets,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Scan Logic

    private struct ScanContext {
        let buffer: [UInt8]
        let scanLength: Int
        let readOffset: Int
        let bytesScanned: UInt64
        let existingOffsets: Set<UInt64>
    }

    private func performScan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeInfo = VolumeInfo.detect(for: device)
        let devicePath = volumeInfo.devicePath

        logger.info("Starting deep scan on \(device.name) using device \(devicePath)")

        // Use PrivilegedDiskReader which handles authorization and privilege
        // escalation transparently — tries direct open() first, then falls
        // back to AuthorizationExecuteWithPrivileges for root-level dd.
        let reader = PrivilegedDiskReader(devicePath: devicePath)
        do {
            try reader.start()
        } catch {
            logger.error("Failed to start privileged reader: \(error.localizedDescription)")
            throw DeepScanError.cannotOpenDevice(path: devicePath, reason: error.localizedDescription)
        }
        defer { reader.stop() }

        // Get total size for progress
        let totalBytes = UInt64(device.totalCapacity)
        guard totalBytes > 0 else {
            logger.warning("Device reports 0 capacity, cannot deep scan")
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        let chunkSize = Self.sectorSize * Self.readChunkSectors
        var buffer = [UInt8](repeating: 0, count: chunkSize + Self.maxSignatureLength)
        var bytesScanned: UInt64 = 0
        var filesFound = 0
        var lastProgressReport: Double = -1
        var carryOver = 0 // Bytes carried over from previous read for cross-boundary matching

        logger.info("Deep scanning \(totalBytes) bytes (\(totalBytes / (1024 * 1024)) MB)")

        while bytesScanned < totalBytes {
            try Task.checkCancellation()

            // Read a chunk
            let toRead = min(chunkSize, Int(totalBytes - bytesScanned))
            let readOffset = carryOver // We keep leftover bytes at the start of buffer

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                reader.read(
                    into: rawBuffer.baseAddress! + readOffset,
                    offset: bytesScanned,
                    length: toRead
                )
            }
            guard bytesRead > 0 else { break }

            let scanLength = readOffset + bytesRead
            let context = ScanContext(
                buffer: buffer,
                scanLength: scanLength,
                readOffset: readOffset,
                bytesScanned: bytesScanned,
                existingOffsets: existingOffsets
            )

            scanChunk(
                context: context,
                filesFound: &filesFound,
                continuation: continuation
            )

            bytesScanned += UInt64(bytesRead)

            // Keep the last few bytes for cross-boundary matching
            if scanLength > Self.maxSignatureLength {
                let keepFrom = scanLength - Self.maxSignatureLength
                for j in 0 ..< Self.maxSignatureLength {
                    buffer[j] = buffer[keepFrom + j]
                }
                carryOver = Self.maxSignatureLength
            }

            // Report progress (throttled to avoid spamming — every ~1%)
            let progress = Double(bytesScanned) / Double(totalBytes)
            if progress - lastProgressReport >= 0.01 {
                continuation.yield(.progress(min(progress, 1.0)))
                lastProgressReport = progress

                // Yield to avoid starving the main thread
                await Task.yield()
            }
        }

        logger.info("Deep scan complete: \(filesFound) file(s) found after scanning \(bytesScanned) bytes")
        continuation.yield(.completed)
        continuation.finish()
    }

    private func scanChunk(
        context: ScanContext,
        filesFound: inout Int,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) {
        // Scan the chunk for magic bytes
        var i = 0
        while i < context.scanLength - Self.maxSignatureLength {
            let offset = context.bytesScanned + UInt64(i) - UInt64(context.readOffset)

            // Skip if already found by fast scan
            if context.existingOffsets.contains(offset) {
                i += Self.sectorSize
                continue
            }

            if let match = matchSignatureAt(buffer: context.buffer, position: i) {
                filesFound += 1

                var fileName = "recovered_\(String(format: "%04d", filesFound))"

                // Try to extract an EXIF date for better naming on photos
                if match.category == .image {
                    let availableBytes = context.buffer.count - i
                    let checkLength = min(availableBytes, 65536)
                    let headerSlice = Array(context.buffer[i ..< i + checkLength])

                    if let exifName = EXIFDateExtractor.extractFilenamePrefix(from: headerSlice) {
                        fileName = "\(exifName)_\(String(format: "%04d", filesFound))"
                    }
                }

                let file = RecoverableFile(
                    id: UUID(),
                    fileName: fileName,
                    fileExtension: match.fileExtension,
                    fileType: match.category,
                    sizeInBytes: 0, // Unknown until we find the next header or EOF marker
                    offsetOnDisk: offset,
                    signatureMatch: match,
                    source: .deepScan
                )
                continuation.yield(.fileFound(file))

                // Skip ahead past this header to avoid re-matching
                i += Self.sectorSize
                continue
            }

            // Move forward by sector alignment for efficiency
            i += Self.sectorSize
        }
    }

    // MARK: - Signature Matching

    /// Checks the buffer at the given position for any known file signature.
    private func matchSignatureAt(buffer: [UInt8], position: Int) -> FileSignature? {
        let remaining = buffer.count - position
        guard remaining >= 4 else { return nil }

        if let direct = matchDirectSignatures(buffer: buffer, position: position, remaining: remaining) {
            return direct
        }

        if let tiff = matchTIFFSignatures(buffer: buffer, position: position, remaining: remaining) {
            return tiff
        }

        if let riff = matchRIFFSignatures(buffer: buffer, position: position, remaining: remaining) {
            return riff
        }

        if let ftyp = matchFtypSignatures(buffer: buffer, position: position, remaining: remaining) {
            return ftyp
        }

        return nil
    }

    private func matchDirectSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        for (signature, magic) in Self.directSignatures {
            if remaining >= magic.count {
                var matched = true
                for j in 0 ..< magic.count {
                    if buffer[position + j] != magic[j] {
                        matched = false
                        break
                    }
                }
                if matched { return signature }
            }
        }
        return nil
    }

    private func matchTIFFSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        // Little-endian TIFF: 49 49 2A 00
        if buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x2A, buffer[position + 3] == 0x00
        {
            // Could be TIFF, CR2, ARW, or DNG — default to TIFF
            if remaining >= 10, buffer[position + 8] == 0x43, buffer[position + 9] == 0x52 {
                return .cr2 // "CR" at offset 8
            }
            return .tiff
        }
        // Big-endian TIFF: 4D 4D 00 2A
        if buffer[position] == 0x4D, buffer[position + 1] == 0x4D,
           buffer[position + 2] == 0x00, buffer[position + 3] == 0x2A
        {
            return .tiffBigEndian
        }
        return nil
    }

    private func matchRIFFSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12,
           buffer[position] == 0x52, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x46, buffer[position + 3] == 0x46
        {
            let sub = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
            if sub == "AVI " { return .avi }
            if sub == "WEBP" { return .webp }
        }
        return nil
    }

    private func matchFtypSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12 {
            let ftypStr = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
            if ftypStr == "ftyp" {
                let brand = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
                switch brand.trimmingCharacters(in: .whitespaces).lowercased() {
                case "isom", "iso2", "mp41", "mp42", "avc1":
                    return .mp4
                case "qt":
                    return .mov
                case "heic", "heix":
                    return .heic
                case "mif1":
                    return .heif
                case "m4v":
                    return .m4v
                case "3gp4", "3gp5", "3gp6", "3ge6":
                    return .threeGP
                default:
                    return .mp4 // Default ftyp to mp4
                }
            }
        }
        return nil
    }
}

// MARK: - Errors

/// Errors specific to the deep scan process.
enum DeepScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path) for scanning: \(reason). " +
                "Try running with elevated privileges or granting Full Disk Access in System Settings."
        }
    }
}
