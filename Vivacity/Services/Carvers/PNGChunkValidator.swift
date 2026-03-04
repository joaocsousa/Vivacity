import Foundation

/// Summary of critical PNG chunk CRC validation.
struct PNGCriticalChunkValidation: Sendable, Equatable {
    /// Number of critical chunks whose CRC was validated.
    let validatedCriticalChunkCount: Int
    /// Number of critical chunks that failed CRC validation.
    let invalidCriticalChunkCount: Int

    var hasInvalidCriticalChunkCRC: Bool {
        invalidCriticalChunkCount > 0
    }
}

/// Validates PNG chunk CRC-32 checksums.
///
/// PNG CRC is computed over `chunkType + chunkData` (not including length/CRC fields).
struct PNGChunkValidator: Sendable {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let iendType: [UInt8] = [0x49, 0x45, 0x4E, 0x44] // IEND

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var c = UInt32(index)
        for _ in 0 ..< 8 {
            if (c & 1) != 0 {
                c = 0xEDB8_8320 ^ (c >> 1)
            } else {
                c >>= 1
            }
        }
        return c
    }

    /// Validates CRCs for all *critical* chunks until IEND.
    ///
    /// Returns `nil` when bytes are not a parseable PNG stream with a complete IEND chunk.
    func validateCriticalChunkCRCs(in bytes: [UInt8]) -> PNGCriticalChunkValidation? {
        guard bytes.count >= Self.pngSignature.count, Array(bytes.prefix(8)) == Self.pngSignature else {
            return nil
        }

        var offset = 8
        var validated = 0
        var invalid = 0
        var reachedIEND = false

        while offset + 12 <= bytes.count {
            let length = readUInt32BE(bytes, at: offset)
            let chunkTypeStart = offset + 4
            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + Int(length)
            let chunkCRCEnd = chunkDataEnd + 4
            guard chunkDataEnd >= chunkDataStart, chunkCRCEnd <= bytes.count else {
                return nil
            }

            let typeBytes = Array(bytes[chunkTypeStart ..< chunkTypeStart + 4])
            let chunkData = Array(bytes[chunkDataStart ..< chunkDataEnd])
            let expectedCRC = readUInt32BE(bytes, at: chunkDataEnd)

            if Self.isCriticalChunk(typeBytes: typeBytes) {
                validated += 1
                if !Self.hasValidCRC(typeBytes: typeBytes, chunkData: chunkData, expectedCRC: expectedCRC) {
                    invalid += 1
                }
            }

            if typeBytes == Self.iendType {
                reachedIEND = true
                break
            }
            offset = chunkCRCEnd
        }

        guard reachedIEND else { return nil }
        return PNGCriticalChunkValidation(
            validatedCriticalChunkCount: validated,
            invalidCriticalChunkCount: invalid
        )
    }

    /// Returns true for critical PNG chunks (uppercase first letter in type code).
    static func isCriticalChunk(typeBytes: [UInt8]) -> Bool {
        guard let first = typeBytes.first else { return false }
        return (first & 0x20) == 0
    }

    /// Calculates PNG CRC-32 over `chunkType + chunkData`.
    static func calculateCRC(typeBytes: [UInt8], chunkData: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typeBytes {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        for byte in chunkData {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Compares provided CRC against calculated CRC.
    static func hasValidCRC(typeBytes: [UInt8], chunkData: [UInt8], expectedCRC: UInt32) -> Bool {
        calculateCRC(typeBytes: typeBytes, chunkData: chunkData) == expectedCRC
    }

    private func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
