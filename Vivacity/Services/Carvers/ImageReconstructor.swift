import Foundation
import os

enum ImageContainerFormat: Sendable, Equatable {
    case jpeg
    case heic
}

struct ImageReconstructionResult: Sendable, Equatable {
    let data: Data
    let isPartial: Bool
    let format: ImageContainerFormat
    /// Optional HEVC Annex-B parameter-set validation, when available.
    let hevcValidation: HEVCNALValidation?
}

/// Handles reassembly of fragmented image files, primarily JPEGs.
protocol ImageReconstructing: Sendable {
    /// Attempts to reconstruct a fragmented image by finding separated chunks on the disk.
    ///
    /// - Parameters:
    ///   - headerOffset: The offset where the first part of the image (e.g., JPEG SOI marker `FF D8`) was found.
    ///   - initialChunk: The contiguous bytes read from the `headerOffset` up until the first fragmentation break.
    ///   - reader: The object providing raw disk access.
    /// - Returns: A complete, reassembled `Data` object if successful, or `nil` if reconstruction was not possible.
    func reconstruct(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> Data?

    /// Returns the reconstructed bytes plus fidelity metadata.
    func reconstructDetailed(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> ImageReconstructionResult?
}

struct ImageReconstructor: ImageReconstructing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "ImageReconstructor")

    // Configurable parameters
    private let sectorSize = 512
    private let maxSearchDistance: UInt64 = 100 * 1024 * 1024 // 100 MB max distance to search for next chunk
    private let maxImageSize = 25 * 1024 * 1024 // 25 MB max total image size to prevent runaway memory

    /// Validates candidate sectors before appending them to the reassembled JPEG stream.
    private let streamValidator = JPEGStreamValidator()
    /// Optional HEVC Annex-B validator for HEIC payload inspection.
    private let hevcParser = HEVCNALParser()

    /// Runtime guardrails to keep HEVC validation lightweight.
    private static let hevcValidationLimits = HEVCNALParser.Limits(
        maxScanBytes: 256 * 1024,
        maxNALUnits: 512
    )

    /// Maximum consecutive implausible sectors before stopping reconstruction.
    private let maxConsecutiveRejects = 10

    // JPEG Markers
    private let jpegSOIMarker: [UInt8] = [0xFF, 0xD8]
    private let jpegEOIMarker: [UInt8] = [0xFF, 0xD9]
    private let jpegSOSMarker: [UInt8] = [0xFF, 0xDA]
    private let jpegDHTMarker: [UInt8] = [0xFF, 0xC4]

    func reconstruct(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> Data? {
        await reconstructDetailed(
            headerOffset: headerOffset,
            initialChunk: initialChunk,
            reader: reader
        )?.data
    }

    func reconstructDetailed(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> ImageReconstructionResult? {
        if isJPEGHeader(initialChunk) {
            return await reconstructJPEG(
                headerOffset: headerOffset,
                initialChunk: initialChunk,
                reader: reader
            )
        }
        if isHEICHeader(initialChunk) {
            return await reconstructHEIC(
                headerOffset: headerOffset,
                initialChunk: initialChunk,
                reader: reader
            )
        }

        logger.debug("Unsupported image type for reconstruction at offset \(headerOffset)")
        return nil
    }

    private func reconstructJPEG(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> ImageReconstructionResult? {
        // 1. Validate that this is a JPEG header we can attempt to reconstruct
        guard isJPEGHeader(initialChunk) else {
            logger.debug("Unsupported image type for reconstruction at offset \(headerOffset)")
            return nil
        }

        var reassembledData = Data(initialChunk)
        var currentSearchOffset = headerOffset + UInt64(initialChunk.count)
        let searchEndLimit = currentSearchOffset + maxSearchDistance

        // Align search to the next sector boundary
        let remainder = currentSearchOffset % UInt64(sectorSize)
        if remainder > 0 {
            currentSearchOffset += (UInt64(sectorSize) - remainder)
        }

        var foundEOI = containsMarker(jpegEOIMarker, in: initialChunk)
        var consecutiveValidSectors = 0
        var consecutiveRejects = 0
        let maxSectorsToTry = 1000 // Arbitrary limit for experimental chunk matching

        while currentSearchOffset < searchEndLimit, reassembledData.count < maxImageSize, !foundEOI {
            // Read next potential sector
            var sectorBuffer = [UInt8](repeating: 0, count: sectorSize)
            let bytesRead = sectorBuffer.withUnsafeMutableBytes { buf in
                reader.read(into: buf.baseAddress!, offset: currentSearchOffset, length: sectorSize)
            }

            guard bytesRead == sectorSize else { break } // Reached end of disk

            let sectorData = Data(sectorBuffer)

            if isZeros(sectorBuffer) || isBoundary(sectorBuffer) {
                currentSearchOffset += UInt64(sectorSize)
                consecutiveRejects += 1
                if consecutiveRejects >= maxConsecutiveRejects {
                    break
                }
                continue
            }

            // Validate that this sector contains plausible JPEG entropy data
            if !streamValidator.isPlausibleJPEGScanData(sectorBuffer) {
                currentSearchOffset += UInt64(sectorSize)
                consecutiveRejects += 1
                if consecutiveRejects >= maxConsecutiveRejects {
                    break
                }
                continue
            }

            reassembledData.append(sectorData)
            consecutiveValidSectors += 1
            consecutiveRejects = 0

            // Check if this newly appended sector contained the EOI marker
            if containsMarker(jpegEOIMarker, in: sectorData) {
                foundEOI = true
                break
            }

            currentSearchOffset += UInt64(sectorSize)

            // Prevent infinite or excessive sequential appending if we aren't finding the end
            if consecutiveValidSectors > maxSectorsToTry, !foundEOI {
                break
            }
        }

        var isPartial = false
        if !foundEOI {
            logger.warning("Saving partial/corrupted JPEG starting at \(headerOffset). Appending synthetic EOI marker.")
            reassembledData.append(contentsOf: jpegEOIMarker)
            isPartial = true
        }

        // Re-seed a baseline Huffman table if the stream has SOS but no DHT.
        reassembledData = reseedHuffmanTablesIfNeeded(reassembledData)

        return ImageReconstructionResult(
            data: reassembledData,
            isPartial: isPartial,
            format: .jpeg,
            hevcValidation: nil
        )
    }

    private func reconstructHEIC(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> ImageReconstructionResult? {
        var result = Data(initialChunk)
        var currentSearchOffset = headerOffset + UInt64(initialChunk.count)
        let searchEndLimit = currentSearchOffset + maxSearchDistance

        var seenBoxes = extractTopLevelBoxTypes(from: initialChunk)

        let aligned = currentSearchOffset % UInt64(sectorSize)
        if aligned > 0 {
            currentSearchOffset += UInt64(sectorSize) - aligned
        }

        while currentSearchOffset < searchEndLimit, result.count < maxImageSize {
            var sectorBuffer = [UInt8](repeating: 0, count: sectorSize)
            let bytesRead = sectorBuffer.withUnsafeMutableBytes { buf in
                reader.read(into: buf.baseAddress!, offset: currentSearchOffset, length: sectorSize)
            }
            guard bytesRead == sectorSize else { break }

            if let boxType = parseISOBoxType(sectorBuffer),
               isHEICRelevantBox(boxType)
            {
                seenBoxes.insert(boxType)
                result.append(contentsOf: sectorBuffer)
            }

            if seenBoxes.contains("mdat"), seenBoxes.contains("moov") || seenBoxes.contains("moof") {
                return ImageReconstructionResult(
                    data: result,
                    isPartial: false,
                    format: .heic,
                    hevcValidation: optionalHEVCValidation(in: result)
                )
            }

            currentSearchOffset += UInt64(sectorSize)
            await Task.yield()
        }

        return ImageReconstructionResult(
            data: result,
            isPartial: true,
            format: .heic,
            hevcValidation: optionalHEVCValidation(in: result)
        )
    }

    // MARK: - Helpers

    private func isJPEGHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == jpegSOIMarker[0] && data[1] == jpegSOIMarker[1]
    }

    private func containsMarker(_ marker: [UInt8], in data: Data) -> Bool {
        guard data.count >= marker.count else { return false }
        for i in 0 ... (data.count - marker.count) {
            var match = true
            for j in 0 ..< marker.count {
                if data[i + j] != marker[j] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }

    private func firstMarkerIndex(_ marker: [UInt8], in data: Data) -> Int? {
        guard data.count >= marker.count else { return nil }
        for i in 0 ... (data.count - marker.count) {
            var match = true
            for j in 0 ..< marker.count where data[i + j] != marker[j] {
                match = false
                break
            }
            if match { return i }
        }
        return nil
    }

    private func isZeros(_ buffer: [UInt8]) -> Bool {
        buffer.allSatisfy { $0 == 0 }
    }

    private func isBoundary(_ buffer: [UInt8]) -> Bool {
        // Simple check to see if we hit a new file cluster
        // FF D8 FF (JPEG), 89 50 4E 47 (PNG), etc.
        if buffer.count >= 4 {
            if buffer[0] == 0xFF, buffer[1] == 0xD8, buffer[2] == 0xFF { return true }
            if buffer[0] == 0x89, buffer[1] == 0x50, buffer[2] == 0x4E, buffer[3] == 0x47 { return true }
            // 'ftyp'
            if buffer.count >= 8,
               buffer[4] == 0x66, buffer[5] == 0x74, buffer[6] == 0x79, buffer[7] == 0x70
            {
                return true
            }
        }
        return false
    }

    private func reseedHuffmanTablesIfNeeded(_ data: Data) -> Data {
        guard containsMarker(jpegSOSMarker, in: data), !containsMarker(jpegDHTMarker, in: data) else {
            return data
        }
        guard let sosIndex = firstMarkerIndex(jpegSOSMarker, in: data) else {
            return data
        }

        var patched = Data()
        patched.append(data.prefix(sosIndex))
        patched.append(defaultJPEGDHTSegment)
        patched.append(data.suffix(data.count - sosIndex))
        return patched
    }

    private var defaultJPEGDHTSegment: Data {
        // Baseline standard Huffman tables (minimal set sufficient for many decoders).
        Data([
            0xFF, 0xC4, 0x01, 0xA2, 0x00,
            0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B,
            0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04,
            0x04, 0x00, 0x00, 0x01, 0x7D,
        ] + Array(repeating: 0x00, count: 365))
    }

    private func isHEICHeader(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp = String(bytes: data[4 ..< 8], encoding: .ascii) ?? ""
        guard ftyp == "ftyp" else { return false }
        let brand = (String(bytes: data[8 ..< 12], encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return ["heic", "heix", "mif1", "avif", "avis"].contains(brand)
    }

    private func parseISOBoxType(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 8 else { return nil }
        return String(bytes: bytes[4 ..< 8], encoding: .ascii)
    }

    private func isHEICRelevantBox(_ boxType: String) -> Bool {
        ["moov", "moof", "mdat", "meta", "trak", "free", "wide"].contains(boxType)
    }

    private func extractTopLevelBoxTypes(from data: Data) -> Set<String> {
        var found: Set<String> = []
        guard data.count >= 8 else { return found }
        var index = 0
        while index + 8 <= data.count {
            let size = (Int(data[index]) << 24)
                | (Int(data[index + 1]) << 16)
                | (Int(data[index + 2]) << 8)
                | Int(data[index + 3])
            guard size >= 8, index + size <= data.count else {
                break
            }
            let box = String(bytes: data[(index + 4) ..< (index + 8)], encoding: .ascii) ?? ""
            found.insert(box)
            index += size
        }
        return found
    }

    private func optionalHEVCValidation(in data: Data) -> HEVCNALValidation? {
        let validation = hevcParser.validateParameterSets(
            in: data,
            limits: Self.hevcValidationLimits
        )
        return validation.hasAnnexBData ? validation : nil
    }
}
