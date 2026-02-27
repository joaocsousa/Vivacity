import Foundation
import os

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
}

struct ImageReconstructor: ImageReconstructing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "ImageReconstructor")
    
    // Configurable parameters
    private let sectorSize = 512
    private let maxSearchDistance: UInt64 = 100 * 1024 * 1024 // 100 MB max distance to search for next chunk
    private let maxImageSize = 25 * 1024 * 1024 // 25 MB max total image size to prevent runaway memory
    
    // JPEG Markers
    private let jpegSOIMarker: [UInt8] = [0xFF, 0xD8]
    private let jpegEOIMarker: [UInt8] = [0xFF, 0xD9]
    private let jpegSOSMarker: [UInt8] = [0xFF, 0xDA]
    
    func reconstruct(
        headerOffset: UInt64,
        initialChunk: Data,
        reader: PrivilegedDiskReading
    ) async -> Data? {
        
        // 1. Validate that this is a JPEG header we can attempt to reconstruct
        guard isJPEGHeader(initialChunk) else {
            logger.debug("Unsupported image type for reconstruction at offset \(headerOffset)")
            return nil
        }
        
        // 2. We need to identify if the initial chunk actually contains the Start of Scan (SOS) marker.
        // If it doesn't, we are looking for the SOS. If it does, we are looking for the continuation of MCU blocks.
        
        let hasSOS = containsMarker(jpegSOSMarker, in: initialChunk)
        
        logger.debug("Starting JPEG reconstruction at offset \(headerOffset). Has SOS: \(hasSOS)")
        
        // In this initial version, we will establish the framework for a sliding window or chunk-based forward scan.
        // This simulates moving forward sector-by-sector to find missing entropy-coded data or the EOI marker.
        
        var reassembledData = Data(initialChunk)
        var currentSearchOffset = headerOffset + UInt64(initialChunk.count)
        let searchEndLimit = currentSearchOffset + maxSearchDistance
        
        // Align search to the next sector boundary
        let remainder = currentSearchOffset % UInt64(sectorSize)
        if remainder > 0 {
            currentSearchOffset += (UInt64(sectorSize) - remainder)
        }
        
        var foundEOI = false
        var consecutiveValidSectors = 0
        let maxSectorsToTry = 1000 // Arbitrary limit for experimental chunk matching
        
        while currentSearchOffset < searchEndLimit && reassembledData.count < maxImageSize && !foundEOI {
            
            // Read next potential sector
            var sectorBuffer = [UInt8](repeating: 0, count: sectorSize)
            let bytesRead = sectorBuffer.withUnsafeMutableBytes { buf in
                reader.read(into: buf.baseAddress!, offset: currentSearchOffset, length: sectorSize)
            }
            
            guard bytesRead == sectorSize else { break } // Reached end of disk
            
            let sectorData = Data(sectorBuffer)
            
            // Heuristic evaluate if this sector belongs to our JPEG stream
            // 1. Is it all zeros? Definitely not our JPEG data.
            // 2. Does it contain another file's signature? (e.g., 'MZ', 'PK', 'ftyp', another 'FF D8') -> Boundary crossed.
            
            if isZeros(sectorBuffer) || isBoundary(sectorBuffer) {
                // Not our chunk. We skip it, assuming fragmentation.
                // In an advanced scenario, we'd log this and look further ahead.
                currentSearchOffset += UInt64(sectorSize)
                continue
            }
            
            // If it passes basic heuristics, append it.
            // (Real reconstruction requires deep entropy validation which we'll stub for now)
            reassembledData.append(sectorData)
            consecutiveValidSectors += 1
            
            // Check if this newly appended sector contained the EOI marker
            if containsMarker(jpegEOIMarker, in: sectorData) {
                foundEOI = true
                logger.debug("Successfully found EOI and reconstructed JPEG starting at \(headerOffset). Total size: \(reassembledData.count)")
                // We could trim the data exactly after FF D9, but keeping the sector alignment is usually fine for decoders.
                break
            }
            
            currentSearchOffset += UInt64(sectorSize)
            
            // Prevent infinite or excessive sequential appending if we aren't finding the end
            if consecutiveValidSectors > maxSectorsToTry && !foundEOI {
                 logger.debug("Exceeded consecutive sector limit without finding EOI. Forcing partial save.")
                 break
            }
        }
        
        if !foundEOI {
            logger.warning("Saving partial/corrupted JPEG starting at \(headerOffset). Appending synthetic EOI marker.")
            reassembledData.append(contentsOf: jpegEOIMarker)
        }
        
        return reassembledData
    }
    
    // MARK: - Helpers
    
    private func isJPEGHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == jpegSOIMarker[0] && data[1] == jpegSOIMarker[1]
    }
    
    private func containsMarker(_ marker: [UInt8], in data: Data) -> Bool {
        guard data.count >= marker.count else { return false }
        for i in 0...(data.count - marker.count) {
            var match = true
            for j in 0..<marker.count {
                if data[i + j] != marker[j] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }
    
    private func isZeros(_ buffer: [UInt8]) -> Bool {
        return buffer.allSatisfy { $0 == 0 }
    }
    
    private func isBoundary(_ buffer: [UInt8]) -> Bool {
        // Simple check to see if we hit a new file cluster
        // FF D8 FF (JPEG), 89 50 4E 47 (PNG), etc.
        if buffer.count >= 4 {
            if buffer[0] == 0xFF && buffer[1] == 0xD8 && buffer[2] == 0xFF { return true }
            if buffer[0] == 0x89 && buffer[1] == 0x50 && buffer[2] == 0x4E && buffer[3] == 0x47 { return true }
            // 'ftyp'
            if buffer[4] == 0x66 && buffer[5] == 0x74 && buffer[6] == 0x79 && buffer[7] == 0x70 { return true }
        }
        return false
    }
}
