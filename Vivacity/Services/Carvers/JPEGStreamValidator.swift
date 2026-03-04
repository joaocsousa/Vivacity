import Foundation

/// Validates whether a sector of bytes is plausible JPEG entropy-coded data.
///
/// During fragmented JPEG reconstruction, the `ImageReconstructor` appends sequential
/// sectors to recover the image. Without validation, random unrelated disk data gets
/// spliced into the stream, producing garbled images. This validator provides a
/// lightweight heuristic check to reject sectors that are clearly not compressed
/// JPEG (DCT/Huffman) bitstream data.
///
/// ## Technique
/// JPEG entropy-coded data (the SOS segment payload) has specific statistical properties:
/// 1. **Marker stuffing**: Any `0xFF` byte in the coded data is followed by `0x00` (byte stuffing).
///    A raw `0xFF` followed by a non-zero byte indicates a JPEG marker, which shouldn't appear
///    in the middle of scan data unless it's a restart marker (`0xD0`–`0xD7`).
/// 2. **Byte distribution**: Compressed DCT data has moderate-to-high Shannon entropy (>4.5 bits/byte).
///    Data with very low entropy (e.g., all zeros, repeated patterns) is not compressed image data.
/// 3. **Marker density**: Too many JPEG marker-like sequences (`0xFF xx`) suggests this is either
///    a new file header or unrelated data.
struct JPEGStreamValidator: Sendable {
    /// The minimum Shannon entropy for a sector to be considered plausible JPEG scan data.
    ///
    /// Compressed JPEG data typically has entropy >5.0. We use a lower threshold
    /// to allow for low-detail image regions (sky, solid backgrounds).
    private static let minimumEntropy: Double = 3.5

    /// Maximum ratio of unstuffed `0xFF` bytes (markers) to total bytes.
    /// Real JPEG scan data uses byte stuffing, so raw markers are rare.
    private static let maxMarkerRatio: Double = 0.05

    /// Maximum ratio of zero bytes before a sector is considered blank/unused.
    private static let maxZeroRatio: Double = 0.90

    /// Validates whether a sector contains plausible JPEG entropy-coded data.
    ///
    /// This is intentionally conservative — we'd rather include a few bad sectors
    /// than discard legitimate image data.
    ///
    /// - Parameter sectorData: The raw bytes of a single disk sector (typically 512 bytes).
    /// - Returns: `true` if the sector looks like plausible JPEG compressed data.
    func isPlausibleJPEGScanData(_ sectorData: [UInt8]) -> Bool {
        guard !sectorData.isEmpty else { return false }

        let total = sectorData.count

        // 1. Reject sectors dominated by zero bytes (blank/unallocated)
        let zeroCount = sectorData.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        if Double(zeroCount) / Double(total) > Self.maxZeroRatio {
            return false
        }

        // 2. Check for excessive bare JPEG markers (0xFF followed by non-zero, non-0xD0-0xD7)
        var unstuffedMarkerCount = 0
        for i in 0 ..< (total - 1) {
            if sectorData[i] == 0xFF {
                let next = sectorData[i + 1]
                // 0x00 = byte stuffing (normal in scan data)
                // 0xD0-0xD7 = restart markers (normal)
                // 0xFF = padding (normal)
                if next != 0x00, !(0xD0 ... 0xD7).contains(next), next != 0xFF {
                    unstuffedMarkerCount += 1
                }
            }
        }

        if Double(unstuffedMarkerCount) / Double(total) > Self.maxMarkerRatio {
            return false
        }

        // 3. Check Shannon entropy — compressed data should have high entropy
        let entropy = shannonEntropy(of: sectorData)
        if entropy < Self.minimumEntropy {
            return false
        }

        return true
    }

    /// Computes Shannon entropy in bits per byte.
    private func shannonEntropy(of bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in bytes {
            counts[Int(byte)] += 1
        }

        let total = Double(bytes.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }
}
