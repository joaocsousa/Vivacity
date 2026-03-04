import Foundation

/// Parses TIFF IFD0 entries to identify camera make/model from raw bytes.
///
/// Many RAW image formats (CR2, ARW, DNG, NEF, RW2) use the TIFF container with
/// identical magic bytes (`49 49 2A 00` for little-endian). By reading the IFD0
/// Make (tag 0x010F) and Model (tag 0x0110) strings, we can accurately promote
/// a generic TIFF signature to its specific RAW format without relying on
/// filesystem-level camera profile detection.
struct TIFFHeaderParser: Sendable {
    /// The result of parsing a TIFF header for camera identification.
    struct CameraIdentification: Sendable, Equatable {
        /// The Make string from IFD0 (tag 0x010F), e.g. "Canon", "SONY", "NIKON CORPORATION".
        let make: String?
        /// The Model string from IFD0 (tag 0x0110), e.g. "Canon EOS R5", "ILCE-7M4".
        let model: String?
    }

    /// Known manufacturer strings mapped to their specific RAW file signatures.
    private static let makeToSignature: [(prefix: String, signature: FileSignature)] = [
        ("canon", .cr2),
        ("sony", .arw),
        ("nikon", .nef),
        ("fujifilm", .raf),
        ("panasonic", .rw2),
    ]

    /// Attempts to identify the camera make/model from TIFF IFD0 entries.
    ///
    /// - Parameter buffer: The first bytes of the file (typically 64 KB is sufficient).
    /// - Returns: Identification result, or `nil` if the buffer is not a valid TIFF.
    func identifyCamera(from buffer: [UInt8]) -> CameraIdentification? {
        guard buffer.count >= 8 else { return nil }

        // Determine byte order
        let isLittleEndian: Bool
        if buffer[0] == 0x49, buffer[1] == 0x49 {
            isLittleEndian = true
        } else if buffer[0] == 0x4D, buffer[1] == 0x4D {
            isLittleEndian = false
        } else {
            return nil
        }

        // Verify TIFF magic
        let magic = readUInt16(buffer, offset: 2, littleEndian: isLittleEndian)
        guard magic == 42 else { return nil }

        // Read IFD0 offset
        let ifd0Offset = Int(readUInt32(buffer, offset: 4, littleEndian: isLittleEndian))
        guard ifd0Offset >= 8, ifd0Offset + 2 <= buffer.count else { return nil }

        // Read number of IFD entries
        let entryCount = Int(readUInt16(buffer, offset: ifd0Offset, littleEndian: isLittleEndian))
        guard entryCount > 0, entryCount < 500 else { return nil } // Sanity check

        var make: String?
        var model: String?

        let entriesStart = ifd0Offset + 2
        for i in 0 ..< entryCount {
            let entryOffset = entriesStart + (i * 12)
            guard entryOffset + 12 <= buffer.count else { break }

            let tag = readUInt16(buffer, offset: entryOffset, littleEndian: isLittleEndian)
            let dataType = readUInt16(buffer, offset: entryOffset + 2, littleEndian: isLittleEndian)
            let count = Int(readUInt32(buffer, offset: entryOffset + 4, littleEndian: isLittleEndian))

            // We only care about ASCII strings (type 2)
            guard dataType == 2, count > 0, count < 256 else { continue }

            if tag == 0x010F {
                make = readASCIIString(
                    buffer, entryOffset: entryOffset, count: count,
                    littleEndian: isLittleEndian
                )
            } else if tag == 0x0110 {
                model = readASCIIString(
                    buffer, entryOffset: entryOffset, count: count,
                    littleEndian: isLittleEndian
                )
            }

            if make != nil, model != nil { break }
        }

        if make == nil, model == nil { return nil }
        return CameraIdentification(make: make, model: model)
    }

    /// Determines the specific RAW file signature based on IFD0 Make string.
    ///
    /// - Parameter buffer: The first bytes of the file.
    /// - Returns: The specific `FileSignature` for the RAW format, or `nil` if unknown.
    func identifyRAWSignature(from buffer: [UInt8]) -> FileSignature? {
        guard let identification = identifyCamera(from: buffer),
              let make = identification.make?.lowercased()
        else {
            return nil
        }

        for entry in Self.makeToSignature {
            if make.contains(entry.prefix) {
                return entry.signature
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    private func readUInt16(_ buffer: [UInt8], offset: Int, littleEndian: Bool) -> UInt16 {
        guard offset + 2 <= buffer.count else { return 0 }
        if littleEndian {
            return UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
        }
        return (UInt16(buffer[offset]) << 8) | UInt16(buffer[offset + 1])
    }

    private func readUInt32(_ buffer: [UInt8], offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= buffer.count else { return 0 }
        if littleEndian {
            return UInt32(buffer[offset])
                | (UInt32(buffer[offset + 1]) << 8)
                | (UInt32(buffer[offset + 2]) << 16)
                | (UInt32(buffer[offset + 3]) << 24)
        }
        return (UInt32(buffer[offset]) << 24)
            | (UInt32(buffer[offset + 1]) << 16)
            | (UInt32(buffer[offset + 2]) << 8)
            | UInt32(buffer[offset + 3])
    }

    /// Reads an ASCII string from a TIFF IFD entry.
    ///
    /// If the string fits in 4 bytes, it's stored inline in the value/offset field.
    /// Otherwise, the field contains an offset to the string data.
    private func readASCIIString(
        _ buffer: [UInt8], entryOffset: Int, count: Int, littleEndian: Bool
    ) -> String? {
        let valueOffset: Int = if count <= 4 {
            // Value stored inline at bytes 8-11 of the entry
            entryOffset + 8
        } else {
            // Value stored at an offset
            Int(readUInt32(buffer, offset: entryOffset + 8, littleEndian: littleEndian))
        }

        guard valueOffset >= 0, valueOffset + count <= buffer.count else { return nil }

        // TIFF ASCII strings include a null terminator
        let stringBytes = Array(buffer[valueOffset ..< (valueOffset + count)])
        let trimmed = stringBytes.prefix(while: { $0 != 0 })
        return String(bytes: trimmed, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
    }
}
