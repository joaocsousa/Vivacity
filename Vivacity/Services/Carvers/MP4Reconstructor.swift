import Foundation
import os

/// Represents the header of an ISOBMFF box (atom).
struct MP4BoxHeader: Equatable {
    let type: String
    /// The total size of the box, including the header.
    let size: UInt64
    /// How many bytes this header occupies (8 for standard, 16 for extended size, 24 for uuid).
    let headerLength: UInt64
}

/// Represents a contiguous byte range on disk.
struct FragmentRange: Sendable, Equatable, Codable, Hashable {
    let start: UInt64
    let length: UInt64
}

/// Detailed result from MP4 reconstruction including fragment information.
struct MP4ReconstructionResult: Sendable, Equatable {
    /// Total size of all fragments combined.
    let totalSize: UInt64
    /// Ordered fragment ranges that should be concatenated to produce a playable file.
    /// If `fragments` has more than one entry, the file requires reassembly.
    let fragments: [FragmentRange]
    /// Whether the moov atom was found displaced from the contiguous region.
    let hasDisplacedMoov: Bool
}

protocol MP4Reconstructing: Sendable {
    /// Calculates the contiguous file size by parsing top-level ISOBMFF boxes.
    /// Returns the total size in bytes if parsing succeeds and finds media data, or nil.
    func calculateContiguousSize(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> UInt64?

    /// Performs a detailed layout reconstruction, potentially locating a displaced moov atom.
    func reconstructDetailedLayout(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> MP4ReconstructionResult?
}

struct MP4Reconstructor: MP4Reconstructing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "MP4Reconstructor")

    /// Max boxes to parse before giving up (prevents infinite loops in corrupted structures).
    private let maxBoxesToParse = 5000

    /// Absolute maximum size for `mdat` to prevent out-of-bounds (100 GB).
    private let maxMediaBoxSize: UInt64 = 100 * 1024 * 1024 * 1024

    /// Search radius for locating a displaced `moov` atom past the end of `mdat`.
    private let moovSearchRadius: UInt64 = 64 * 1024 * 1024 // 64 MB

    func calculateContiguousSize(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> UInt64? {
        let layout = parseTopLevelBoxes(startingAt: offset, reader: reader)
        return layout.contiguousSize
    }

    func reconstructDetailedLayout(
        startingAt offset: UInt64,
        reader: PrivilegedDiskReading
    ) -> MP4ReconstructionResult? {
        let layout = parseTopLevelBoxes(startingAt: offset, reader: reader)

        // Case 1: Fully contiguous file with moov
        if let contiguousSize = layout.contiguousSize, layout.foundMoov || layout.foundMoof {
            return MP4ReconstructionResult(
                totalSize: contiguousSize,
                fragments: [FragmentRange(start: offset, length: contiguousSize)],
                hasDisplacedMoov: false
            )
        }

        // Case 2: Has ftyp + mdat but no moov — search for displaced moov
        if layout.foundFtyp, layout.foundMdat, !layout.foundMoov, layout.highestMediaEnd > 0 {
            let mdatEnd = offset + layout.highestMediaEnd
            if let moovBox = scanForDisplacedMoov(afterOffset: mdatEnd, reader: reader) {
                let ftypAndMdatRange = FragmentRange(start: offset, length: layout.highestMediaEnd)
                let moovRange = FragmentRange(start: moovBox.offset, length: moovBox.size)
                let totalSize = layout.highestMediaEnd + moovBox.size

                return MP4ReconstructionResult(
                    totalSize: totalSize,
                    fragments: [ftypAndMdatRange, moovRange],
                    hasDisplacedMoov: true
                )
            }
        }

        // Case 3: Partial file (ftyp + mdat, no moov found nearby)
        if let contiguousSize = layout.contiguousSize {
            return MP4ReconstructionResult(
                totalSize: contiguousSize,
                fragments: [FragmentRange(start: offset, length: contiguousSize)],
                hasDisplacedMoov: false
            )
        }

        return nil
    }

    // MARK: - Box Layout

    private struct BoxLayout {
        var foundFtyp = false
        var foundMoov = false
        var foundMoof = false
        var foundMdat = false
        var lastValidSize: UInt64 = 0
        var highestMediaEnd: UInt64 = 0
        /// Set when a box with size 0 (extends to EOF) is encountered — bounds are not known.
        var hasEOFBox = false

        var contiguousSize: UInt64? {
            // Cannot determine size when an EOF-extending box was encountered
            guard !hasEOFBox else { return nil }

            if foundMdat, foundMoov || foundMoof, highestMediaEnd > 0 {
                return highestMediaEnd
            }
            if foundMdat, foundFtyp, lastValidSize > 0 {
                return lastValidSize
            }
            return nil
        }
    }

    private func parseTopLevelBoxes(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> BoxLayout {
        var layout = BoxLayout()
        var currentOffset = offset
        var boxesParsed = 0

        while boxesParsed < maxBoxesToParse {
            guard let box = readBoxHeader(at: currentOffset, reader: reader) else {
                break
            }
            guard isPlausibleBox(box) else {
                break
            }

            if box.type == "ftyp" { layout.foundFtyp = true }
            if box.type == "moov" { layout.foundMoov = true }
            if box.type == "moof" { layout.foundMoof = true }
            if box.type == "mdat" { layout.foundMdat = true }

            if box.size == 0 {
                layout.hasEOFBox = true
                return layout
            }

            let nextOffset = currentOffset + box.size
            currentOffset = nextOffset
            boxesParsed += 1
            layout.lastValidSize = currentOffset - offset
            layout.highestMediaEnd = max(layout.highestMediaEnd, layout.lastValidSize)
        }

        return layout
    }

    // MARK: - Displaced Moov Search

    private struct LocatedBox {
        let offset: UInt64
        let size: UInt64
    }

    /// Scans the disk after `afterOffset` looking for a `moov` box within the search radius.
    ///
    /// Many cameras write `ftyp | mdat | moov`. When files are fragmented, the `moov` may
    /// not be adjacent to `mdat`. This method scans sector-by-sector looking for a valid
    /// `moov` box header.
    private func scanForDisplacedMoov(afterOffset: UInt64, reader: PrivilegedDiskReading) -> LocatedBox? {
        let searchEnd = afterOffset + moovSearchRadius
        var currentOffset = afterOffset
        let stride: UInt64 = 512 // Sector-aligned

        while currentOffset < searchEnd {
            guard let box = readBoxHeader(at: currentOffset, reader: reader) else {
                currentOffset += stride
                continue
            }

            if box.type == "moov", box.size >= 8, box.size <= 4 * 1024 * 1024 * 1024 {
                logger.info("Found displaced moov at offset \(currentOffset), size \(box.size)")
                return LocatedBox(offset: currentOffset, size: box.size)
            }

            // If we found another valid top-level box, skip over it
            if isPlausibleBox(box), box.size > 0 {
                currentOffset += box.size
            } else {
                currentOffset += stride
            }
        }

        return nil
    }

    /// Reads and parses an ISOBMFF box header at the given offset.
    func readBoxHeader(at offset: UInt64, reader: PrivilegedDiskReading) -> MP4BoxHeader? {
        var headerData = [UInt8](repeating: 0, count: 32)
        let bytesRead = headerData.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: offset, length: 32)
        }

        guard bytesRead >= 8 else { return nil }

        let size32 = UInt32(bigEndian: headerData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        let typeData = Array(headerData[4 ..< 8])

        guard let typeString = String(bytes: typeData, encoding: .ascii),
              isPrintableASCII(typeString)
        else {
            return nil
        }

        var actualSize = UInt64(size32)
        var headerLength: UInt64 = 8

        if size32 == 1 {
            // Extended size (64-bit)
            guard bytesRead >= 16 else { return nil }
            actualSize = UInt64(bigEndian: headerData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) })
            headerLength = 16
        }

        if typeString == "uuid" {
            // UUID occupies the next 16 bytes
            headerLength += 16
        }

        // Cannot be smaller than the header unless it's 0 (extends to EOF)
        if actualSize != 0, actualSize < headerLength {
            return nil
        }

        return MP4BoxHeader(type: typeString, size: actualSize, headerLength: headerLength)
    }

    private func isPrintableASCII(_ str: String) -> Bool {
        str.utf8.allSatisfy { $0 >= 32 && $0 <= 126 }
    }

    private func isPlausibleBox(_ box: MP4BoxHeader) -> Bool {
        let knownTopLevel: Set<String> = [
            "ftyp", "pdin", "moov", "moof", "mfra", "mdat", "free",
            "skip", "meta", "uuid", "wide",
        ]

        if box.type == "mdat" {
            return box.size <= maxMediaBoxSize
        }

        if knownTopLevel.contains(box.type) {
            // Other standard boxes (like moov) shouldn't be larger than a few GBs
            return box.size <= 4 * 1024 * 1024 * 1024 // 4 GB
        } else {
            // Unrecognized proprietary boxes (e.g., GUMI, CNCV) are usually small metadata.
            // If it claims to be massive, it's likely a false positive.
            return box.size <= 50 * 1024 * 1024 // 50 MB limit for unknown boxes
        }
    }
}
