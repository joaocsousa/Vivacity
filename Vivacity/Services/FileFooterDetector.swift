import Foundation

/// Detects likely file end boundaries for carved files using known footers and nearby headers.
protocol FileFooterDetecting: Sendable {
    func estimateSize(
        signature: FileSignature,
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64?
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
                maxScanBytes: maxScanBytes
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

    private func estimatePNGSize(
        startOffset: UInt64,
        reader: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64? {
        // IEND chunk type + fixed CRC bytes.
        let iendTrailer: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

        if let footerEnd = try await findPatternEnd(
            pattern: iendTrailer,
            startOffset: startOffset,
            searchStart: 8,
            reader: reader,
            maxScanBytes: maxScanBytes
        ) {
            return Int64(footerEnd)
        }

        return try await estimateUsingNextHeaderBoundary(
            startOffset: startOffset,
            reader: reader,
            maxScanBytes: maxScanBytes,
            minimumDistance: 1024
        )
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
