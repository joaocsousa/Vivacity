import Foundation

/// Detects likely file end boundaries for carved files using known footers and nearby headers.
protocol FileFooterDetecting: Sendable {
    func estimateSize(
        signature: FileSignature,
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64?

    func estimatePNGSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int,
        validateCriticalChunkCRCs: Bool
    ) async throws -> PNGSizeEstimation?
}

/// PNG size estimate with optional critical-chunk CRC validation details.
struct PNGSizeEstimation: Sendable, Equatable {
    let sizeInBytes: Int64
    let criticalChunkValidation: PNGCriticalChunkValidation?

    var hasInvalidCriticalChunkCRC: Bool {
        criticalChunkValidation?.hasInvalidCriticalChunkCRC == true
    }
}

struct FileFooterDetector: FileFooterDetecting {
    /// Conservative cap so deep scan does not read the full disk to estimate one file.
    private static let defaultMaxScanBytes = 32 * 1024 * 1024
    private static let readChunkSize = 4096

    /// Header signatures used as fallback boundaries when a footer is not found.
    private static let boundaryHeaders: [[UInt8]] = [
        [0xFF, 0xD8, 0xFF], // JPEG
        [0x89, 0x50, 0x4E, 0x47], // PNG
        [0x47, 0x49, 0x46, 0x38], // GIF
        [0x42, 0x4D], // BMP
        [0x52, 0x49, 0x46, 0x46], // RIFF
        [0x49, 0x49, 0x2A, 0x00], // TIFF little-endian
        [0x4D, 0x4D, 0x00, 0x2A], // TIFF big-endian
    ]

    func estimateSize(
        signature: FileSignature,
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int = defaultMaxScanBytes
    ) async throws -> Int64? {
        guard maxScanBytes > 0 else { return nil }

        switch signature {
        case .jpeg:
            return try await estimateJPEGSize(
                startOffset: startOffset,
                reader: reader,
                maxScanBytes: maxScanBytes
            )
        case .png:
            return try await estimatePNGSize(
                startOffset: startOffset,
                reader: reader,
                maxScanBytes: maxScanBytes,
                validateCriticalChunkCRCs: false
            )?.sizeInBytes
        case .gif:
            return try await estimateGIFSize(
                startOffset: startOffset,
                reader: reader,
                maxScanBytes: maxScanBytes
            )
        case .bmp:
            return estimateBMPSize(
                startOffset: startOffset,
                reader: reader
            )
        case .webp:
            return estimateWebPSize(
                startOffset: startOffset,
                reader: reader
            )
        default:
            return nil
        }
    }

    private func estimateJPEGSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64? {
        if let segmentedSize = try await estimateJPEGSizeUsingSOFAndEOI(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) {
            return segmentedSize
        }

        let footer: [UInt8] = [0xFF, 0xD9]

        if let footerEnd = try await findPatternEnd(
            pattern: footer,
            startOffset: startOffset,
            searchStart: 2,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) {
            return Int64(footerEnd)
        }

        return try await estimateUsingNextHeaderBoundary(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: maxScanBytes,
            minimumDistance: 512
        )
    }

    private func estimateJPEGSizeUsingSOFAndEOI(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64? {
        guard let bytes = try await readWindow(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) else {
            return nil
        }
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var index = 2
        var sawSOF = false
        while index + 3 < bytes.count {
            if bytes[index] != 0xFF {
                index += 1
                continue
            }
            var markerIndex = index + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF {
                markerIndex += 1
            }
            guard markerIndex < bytes.count else { break }
            let marker = bytes[markerIndex]

            if marker == 0xD9 {
                let fileEnd = markerIndex + 1
                if sawSOF, fileEnd > 4 {
                    return Int64(fileEnd)
                }
                return nil
            }

            if marker == 0xD8 || marker == 0x01 || (0xD0 ... 0xD7).contains(marker) {
                index = markerIndex + 1
                continue
            }

            guard markerIndex + 2 < bytes.count else { break }
            let segmentLength = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            if segmentLength < 2 { return nil }
            if (0xC0 ... 0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                sawSOF = true
            }
            index = markerIndex + 1 + segmentLength
        }

        return nil
    }

    private func readWindow(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> [UInt8]? {
        guard maxScanBytes > 0 else { return nil }
        var scanned = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxScanBytes, 256 * 1024))

        while scanned < maxScanBytes {
            try Task.checkCancellation()

            let toRead = min(Self.readChunkSize, maxScanBytes - scanned)
            var chunk = [UInt8](repeating: 0, count: toRead)
            let offset = startOffset + UInt64(scanned)
            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                reader.read(into: buffer.baseAddress!, offset: offset, length: toRead)
            }
            guard bytesRead > 0 else { break }
            bytes.append(contentsOf: chunk.prefix(bytesRead))
            scanned += bytesRead
            await Task.yield()
        }

        return bytes.isEmpty ? nil : bytes
    }

    func estimatePNGSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int,
        validateCriticalChunkCRCs: Bool = false
    ) async throws -> PNGSizeEstimation? {
        // IEND chunk type + fixed CRC bytes.
        let iendTrailer: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

        if let footerEnd = try await findPatternEnd(
            pattern: iendTrailer,
            startOffset: startOffset,
            searchStart: 8,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) {
            var criticalChunkValidation: PNGCriticalChunkValidation?
            if validateCriticalChunkCRCs,
               let pngBytes = try await readWindow(
                   startOffset: startOffset,
                   reader: reader,
                   maxScanBytes: Int(footerEnd)
               )
            {
                criticalChunkValidation = PNGChunkValidator().validateCriticalChunkCRCs(in: pngBytes)
            }

            return PNGSizeEstimation(
                sizeInBytes: Int64(footerEnd),
                criticalChunkValidation: criticalChunkValidation
            )
        }

        if let fallbackSize = try await estimateUsingNextHeaderBoundary(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: maxScanBytes,
            minimumDistance: 1024
        ) {
            return PNGSizeEstimation(sizeInBytes: fallbackSize, criticalChunkValidation: nil)
        }

        return nil
    }

    // MARK: - GIF Size Estimation

    /// Estimates GIF file size by scanning for the GIF trailer byte `0x3B`.
    ///
    /// GIF files always end with a single trailer byte. This is reliable because
    /// the byte is expected to appear after all image data and extension blocks.
    private func estimateGIFSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64? {
        // The GIF trailer is a single byte: 0x3B
        // We can't just search for any 0x3B — it could appear in compressed data.
        // Instead, walk the GIF block structure to find the true trailer.
        guard let bytes = try await readWindow(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: min(maxScanBytes, 32 * 1024 * 1024)
        ) else {
            return nil
        }

        // Verify GIF header: "GIF87a" or "GIF89a"
        guard bytes.count >= 13,
              bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, // "GIF"
              bytes[3] == 0x38, // "8"
              bytes[4] == 0x37 || bytes[4] == 0x39, // "7" or "9"
              bytes[5] == 0x61 // "a"
        else {
            return nil
        }

        // Parse Logical Screen Descriptor (7 bytes after header)
        let packed = bytes[10]
        let hasGlobalColorTable = (packed & 0x80) != 0
        let globalColorTableSize = hasGlobalColorTable ? 3 * (1 << ((packed & 0x07) + 1)) : 0
        var index = 13 + globalColorTableSize

        // Walk through GIF blocks
        while index < bytes.count {
            let introducer = bytes[index]

            if introducer == 0x3B {
                // Trailer found
                return Int64(index + 1)
            }

            if introducer == 0x2C {
                // Image Descriptor
                guard index + 10 < bytes.count else { break }
                let imgPacked = bytes[index + 9]
                let hasLocalColorTable = (imgPacked & 0x80) != 0
                let localColorTableSize = hasLocalColorTable ? 3 * (1 << ((imgPacked & 0x07) + 1)) : 0
                index += 10 + localColorTableSize

                // Skip LZW Minimum Code Size byte
                guard index < bytes.count else { break }
                index += 1

                // Skip sub-blocks
                index = skipGIFSubBlocks(bytes: bytes, from: index)
                continue
            }

            if introducer == 0x21 {
                // Extension block
                guard index + 2 < bytes.count else { break }
                index += 2 // Skip introducer + label
                index = skipGIFSubBlocks(bytes: bytes, from: index)
                continue
            }

            // Unknown block type — bail out
            break
        }

        // Fallback: search for trailer in the last portion of the read window
        let trailer: [UInt8] = [0x3B]
        if let footerEnd = try await findPatternEnd(
            pattern: trailer,
            startOffset: startOffset,
            searchStart: 13,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) {
            return Int64(footerEnd)
        }

        return nil
    }

    /// Skips GIF sub-blocks starting at `from`. Returns the index after the block terminator (0x00).
    private func skipGIFSubBlocks(bytes: [UInt8], from index: Int) -> Int {
        var pos = index
        while pos < bytes.count {
            let blockSize = Int(bytes[pos])
            if blockSize == 0 {
                return pos + 1 // Past the block terminator
            }
            pos += 1 + blockSize
        }
        return pos
    }

    // MARK: - BMP Size Estimation

    /// Extracts exact BMP file size from the BMP header.
    ///
    /// The BMP file header stores the total file size as a 32-bit little-endian
    /// integer at bytes 2–5. This gives an exact, authoritative size.
    func estimateBMPSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading
    ) -> Int64? {
        var header = [UInt8](repeating: 0, count: 14)
        let bytesRead = header.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: startOffset, length: 14)
        }

        guard bytesRead >= 6,
              header[0] == 0x42, header[1] == 0x4D // "BM"
        else {
            return nil
        }

        // Bytes 2-5: file size (little-endian uint32)
        let fileSize = UInt32(header[2])
            | (UInt32(header[3]) << 8)
            | (UInt32(header[4]) << 16)
            | (UInt32(header[5]) << 24)

        guard fileSize >= 14 else { return nil } // Minimum BMP header size
        return Int64(fileSize)
    }

    // MARK: - WebP Size Estimation

    /// Extracts exact WebP file size from the RIFF container header.
    ///
    /// WebP uses the RIFF container. Bytes 4–7 contain the chunk size
    /// (little-endian uint32). The total file size is chunk size + 8.
    func estimateWebPSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading
    ) -> Int64? {
        var header = [UInt8](repeating: 0, count: 12)
        let bytesRead = header.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: startOffset, length: 12)
        }

        guard bytesRead >= 12,
              header[0] == 0x52, header[1] == 0x49, // "RI"
              header[2] == 0x46, header[3] == 0x46, // "FF"
              header[8] == 0x57, header[9] == 0x45, // "WE"
              header[10] == 0x42, header[11] == 0x50 // "BP"
        else {
            return nil
        }

        // Bytes 4-7: RIFF chunk size (little-endian uint32)
        let chunkSize = UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24)

        let totalSize = Int64(chunkSize) + 8
        guard totalSize >= 12 else { return nil }
        return totalSize
    }

    private func findPatternEnd(
        pattern: [UInt8],
        startOffset: UInt64,
        searchStart: Int,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> UInt64? {
        guard !pattern.isEmpty, maxScanBytes >= pattern.count else { return nil }

        var scanned = 0
        var overlap: [UInt8] = []
        let overlapSize = max(pattern.count - 1, 0)

        while scanned < maxScanBytes {
            try Task.checkCancellation()

            let toRead = min(Self.readChunkSize, maxScanBytes - scanned)
            var chunk = [UInt8](repeating: 0, count: toRead)
            let offset = startOffset + UInt64(scanned)

            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                reader.read(into: buffer.baseAddress!, offset: offset, length: toRead)
            }
            guard bytesRead > 0 else { break }

            if bytesRead < chunk.count {
                chunk.removeSubrange(bytesRead ..< chunk.count)
            }

            var window = overlap
            window.append(contentsOf: chunk)

            let begin = max(0, searchStart - overlap.count)
            if let matchIndex = indexOf(pattern, in: window, from: begin) {
                return UInt64(scanned) - UInt64(overlap.count) + UInt64(matchIndex + pattern.count)
            }

            if overlapSize > 0 {
                overlap = Array(window.suffix(overlapSize))
            } else {
                overlap.removeAll(keepingCapacity: true)
            }

            scanned += bytesRead
            await Task.yield()
        }

        return nil
    }

    private func estimateUsingNextHeaderBoundary(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int,
        minimumDistance: Int
    ) async throws -> Int64? {
        var scanned = 0
        var overlap: [UInt8] = []
        let overlapSize = 12

        while scanned < maxScanBytes {
            try Task.checkCancellation()

            let toRead = min(Self.readChunkSize, maxScanBytes - scanned)
            var chunk = [UInt8](repeating: 0, count: toRead)
            let offset = startOffset + UInt64(scanned)

            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                reader.read(into: buffer.baseAddress!, offset: offset, length: toRead)
            }
            guard bytesRead > 0 else { break }

            if bytesRead < chunk.count {
                chunk.removeSubrange(bytesRead ..< chunk.count)
            }

            var window = overlap
            window.append(contentsOf: chunk)

            let begin = max(0, minimumDistance - overlap.count)
            if let boundary = firstBoundaryIndex(in: window, from: begin) {
                let absolute = UInt64(scanned) - UInt64(overlap.count) + UInt64(boundary)
                return Int64(absolute)
            }

            overlap = Array(window.suffix(overlapSize))
            scanned += bytesRead
            await Task.yield()
        }

        return nil
    }
}

extension FileFooterDetector {
    private func firstBoundaryIndex(in bytes: [UInt8], from startIndex: Int) -> Int? {
        guard startIndex < bytes.count else { return nil }

        var bestIndex: Int?
        for header in Self.boundaryHeaders {
            if let index = indexOf(header, in: bytes, from: startIndex) {
                if bestIndex == nil || index < bestIndex! {
                    bestIndex = index
                }
            }
        }
        return bestIndex
    }

    private func indexOf(_ needle: [UInt8], in haystack: [UInt8], from startIndex: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }

        let start = max(0, startIndex)
        guard start <= haystack.count - needle.count else { return nil }

        for i in start ... (haystack.count - needle.count) {
            var match = true
            for j in 0 ..< needle.count {
                if haystack[i + j] != needle[j] {
                    match = false
                    break
                }
            }
            if match { return i }
        }
        return nil
    }
}
