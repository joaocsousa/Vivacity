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

protocol MP4Reconstructing: Sendable {
    /// Calculates the contiguous file size by parsing top-level ISOBMFF boxes.
    /// Returns the total size in bytes if parsing succeeds and finds media data, or nil.
    func calculateContiguousSize(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> UInt64?
}

struct MP4Reconstructor: MP4Reconstructing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "MP4Reconstructor")
    
    /// Max boxes to parse before giving up (prevents infinite loops in corrupted structures).
    private let maxBoxesToParse = 5000
    
    /// Absolute maximum size for `mdat` to prevent out-of-bounds (100 GB).
    private let maxMediaBoxSize: UInt64 = 100 * 1024 * 1024 * 1024
    
    func calculateContiguousSize(startingAt offset: UInt64, reader: PrivilegedDiskReading) -> UInt64? {
        var currentOffset = offset
        var boxesParsed = 0
        var foundMdat = false
        var lastValidSize: UInt64 = 0
        
        while boxesParsed < maxBoxesToParse {
            guard let box = readBoxHeader(at: currentOffset, reader: reader) else {
                break
            }
            
            // Validate the box to prevent runaway parsing on garbage data
            guard isPlausibleBox(box) else {
                break
            }
            
            if box.type == "mdat" {
                foundMdat = true
            }
            
            let nextOffset = currentOffset + box.size
            currentOffset = nextOffset
            boxesParsed += 1
            lastValidSize = currentOffset - offset
            
            // If the box size is 0, it extends to EOF, which we can't bounds-check natively.
            if box.size == 0 {
                return nil
            }
        }
        
        // If we found mdat, we have at least a playable truncated video.
        if foundMdat && lastValidSize > 0 {
            return lastValidSize
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
        let typeData = Array(headerData[4..<8])
        
        guard let typeString = String(bytes: typeData, encoding: .ascii),
              isPrintableASCII(typeString) else {
            return nil
        }
        
        var actualSize: UInt64 = UInt64(size32)
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
        if actualSize != 0 && actualSize < headerLength {
            return nil
        }
        
        return MP4BoxHeader(type: typeString, size: actualSize, headerLength: headerLength)
    }
    
    private func isPrintableASCII(_ str: String) -> Bool {
        return str.utf8.allSatisfy { $0 >= 32 && $0 <= 126 }
    }
    
    private func isPlausibleBox(_ box: MP4BoxHeader) -> Bool {
        let knownTopLevel: Set<String> = [
            "ftyp", "pdin", "moov", "moof", "mfra", "mdat", "free", 
            "skip", "meta", "uuid", "wide"
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
