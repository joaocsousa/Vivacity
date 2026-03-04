import Foundation

extension DeepScanService {
    func shouldEmit(_ file: RecoverableFile, entropy: Double? = nil) -> Bool {
        let score = file.confidenceScore ?? 0

        if let entropy {
            // Drop obvious low-information false positives from deep scans.
            if entropy < Self.entropyRejectThreshold,
               file.signatureMatch == .jpeg,
               file.sizeInBytes > 0,
               file.sizeInBytes < 256 * 1024
            {
                return false
            }
        }

        return score >= Self.confidenceRejectThreshold
    }

    func confidenceScore(
        signature: FileSignature,
        sizeInBytes: Int64,
        entropy: Double,
        hasStructureSignal: Bool,
        hasInvalidPNGCriticalChunkCRC: Bool = false
    ) -> Double {
        let signatureStrength = signatureStrength(for: signature)
        let structureScore = hasStructureSignal ? 1.0 : 0.35
        let sizeScore = sizePlausibilityScore(signature: signature, sizeInBytes: sizeInBytes)
        let entropyScore = normalizedEntropyScore(entropy)

        let weighted =
            (signatureStrength * 0.30) +
            (structureScore * 0.30) +
            (sizeScore * 0.20) +
            (entropyScore * 0.20)
        let pngCRCPenalty = signature == .png && hasInvalidPNGCriticalChunkCRC ? 0.25 : 0
        return min(max(weighted - pngCRCPenalty, 0), 1)
    }

    func signatureStrength(for signature: FileSignature) -> Double {
        switch signature {
        case .jpeg, .png, .gif, .bmp, .tiff, .tiffBigEndian, .heic, .heif, .avif:
            0.95
        case .mp4, .mov, .m4v, .threeGP, .mkv, .avi:
            0.85
        case .webp, .wmv, .flv:
            0.75
        case .cr2, .cr3, .nef, .arw, .dng, .raf, .rw2:
            0.8
        }
    }

    func sizePlausibilityScore(signature: FileSignature, sizeInBytes: Int64) -> Double {
        guard sizeInBytes > 0 else { return 0.2 }
        let minimum = minimumPlausibleSize(for: signature)
        if sizeInBytes < minimum {
            return 0.35
        }
        if sizeInBytes < minimum * 2 {
            return 0.7
        }
        return 1.0
    }

    func minimumPlausibleSize(for signature: FileSignature) -> Int64 {
        switch signature.category {
        case .image: 4 * 1024
        case .video: 64 * 1024
        }
    }

    func normalizedEntropyScore(_ entropy: Double) -> Double {
        // Typical compressed media data tends to be >5 bits/byte in local windows.
        switch entropy {
        case ..<2.2:
            0
        case 2.2 ..< 4.0:
            0.35
        case 4.0 ..< 5.0:
            0.65
        case 5.0 ..< 8.5:
            1.0
        default:
            0.8
        }
    }

    func shannonEntropy(of bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in bytes {
            counts[Int(byte)] += 1
        }

        let total = Double(bytes.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let probability = Double(count) / total
            entropy -= probability * log2(probability)
        }
        return entropy
    }
}
