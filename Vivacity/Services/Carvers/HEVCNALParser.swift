import Foundation

/// Summary of HEVC Annex-B NAL parsing and parameter-set detection.
struct HEVCNALValidation: Sendable, Equatable {
    let scannedByteCount: Int
    let annexBStartCodeCount: Int
    let parsedNALUnitCount: Int
    let vpsCount: Int
    let spsCount: Int
    let ppsCount: Int
    let reachedNALUnitLimit: Bool

    var hasAnnexBData: Bool {
        annexBStartCodeCount > 0
    }

    var hasRequiredParameterSets: Bool {
        vpsCount > 0 && spsCount > 0 && ppsCount > 0
    }

    /// Returns true when Annex-B data was found but the VPS/SPS/PPS triad is incomplete.
    var hasInvalidParameterSetSignal: Bool {
        hasAnnexBData && !hasRequiredParameterSets
    }
}

/// Lightweight parser for HEVC/H.265 Annex-B NAL streams.
///
/// Supports both start-code forms:
/// - `00 00 01`
/// - `00 00 00 01`
struct HEVCNALParser: Sendable {
    struct Limits: Sendable, Equatable {
        let maxScanBytes: Int
        let maxNALUnits: Int

        static let `default` = Limits(
            maxScanBytes: 512 * 1024,
            maxNALUnits: 1024
        )
    }

    func validateParameterSets(
        in data: Data,
        limits: Limits = .default
    ) -> HEVCNALValidation {
        let scannedBytes = [UInt8](data.prefix(max(0, limits.maxScanBytes)))
        guard !scannedBytes.isEmpty else {
            return HEVCNALValidation(
                scannedByteCount: 0,
                annexBStartCodeCount: 0,
                parsedNALUnitCount: 0,
                vpsCount: 0,
                spsCount: 0,
                ppsCount: 0,
                reachedNALUnitLimit: false
            )
        }

        var searchIndex = 0
        var startCodeCount = 0
        var parsedNALUnits = 0
        var vpsCount = 0
        var spsCount = 0
        var ppsCount = 0
        var reachedLimit = false

        while parsedNALUnits < limits.maxNALUnits,
              let startCode = findStartCode(in: scannedBytes, from: searchIndex)
        {
            startCodeCount += 1
            let nalStart = startCode.index + startCode.length
            guard nalStart + 1 < scannedBytes.count else { break }

            let nextStart = findStartCode(in: scannedBytes, from: nalStart)
            let nalEnd = nextStart?.index ?? scannedBytes.count

            if nalEnd - nalStart >= 2 {
                let headerFirstByte = scannedBytes[nalStart]
                let forbiddenZeroBit = (headerFirstByte & 0x80) >> 7
                if forbiddenZeroBit == 0 {
                    let nalUnitType = Int((headerFirstByte >> 1) & 0x3F)
                    switch nalUnitType {
                    case 32: vpsCount += 1
                    case 33: spsCount += 1
                    case 34: ppsCount += 1
                    default: break
                    }
                    parsedNALUnits += 1
                }
            }

            searchIndex = nextStart?.index ?? scannedBytes.count
        }

        if parsedNALUnits >= limits.maxNALUnits {
            reachedLimit = true
        }

        return HEVCNALValidation(
            scannedByteCount: scannedBytes.count,
            annexBStartCodeCount: startCodeCount,
            parsedNALUnitCount: parsedNALUnits,
            vpsCount: vpsCount,
            spsCount: spsCount,
            ppsCount: ppsCount,
            reachedNALUnitLimit: reachedLimit
        )
    }

    private func findStartCode(in bytes: [UInt8], from startIndex: Int) -> (index: Int, length: Int)? {
        guard bytes.count >= 3, startIndex <= bytes.count - 3 else { return nil }

        var i = startIndex
        while i <= bytes.count - 3 {
            if bytes[i] == 0x00, bytes[i + 1] == 0x00 {
                if i + 3 < bytes.count, bytes[i + 2] == 0x00, bytes[i + 3] == 0x01 {
                    return (i, 4)
                }
                if bytes[i + 2] == 0x01 {
                    return (i, 3)
                }
            }
            i += 1
        }
        return nil
    }
}
