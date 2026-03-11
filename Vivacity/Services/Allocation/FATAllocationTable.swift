import Foundation
import os

/// Parses a FAT32 Allocation Table to provide an iterative map of contiguous free space.
actor FATAllocationTable: FreeSpaceMapping {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FATAllocationTable")
    
    private let reader: any PrivilegedDiskReading
    private let bpbOffset: UInt64
    
    private var reservedSectors: UInt16 = 0
    private var bytesPerSector: UInt16 = 0
    private var sectorsPerCluster: UInt8 = 0
    private var numberOfFATs: UInt8 = 0
    private var fatSize32: UInt32 = 0
    private var clusterCount: UInt32 = 0
    
    private var isInitialized = false
    private var initializationError: Error?
    
    enum FATError: Error, LocalizedError {
        case invalidBPB
        case notFAT32
        case readError
        
        var errorDescription: String? {
            switch self {
            case .invalidBPB: return "Invalid FAT BPB (Boot Parameter Block)."
            case .notFAT32: return "Volume is not FAT32."
            case .readError: return "Failed to read FAT data from disk."
            }
        }
    }
    
    init(reader: any PrivilegedDiskReading, bpbOffset: UInt64 = 0) {
        self.reader = reader
        self.bpbOffset = bpbOffset
    }
    
    private func initializeIfNeeded() throws {
        if let error = initializationError {
            throw error
        }
        guard !isInitialized else { return }
        
        do {
            try parseBPB()
            isInitialized = true
            logger.info("Successfully parsed FAT32 BPB. Cluster count: \(self.clusterCount)")
        } catch {
            initializationError = error
            logger.error("Failed to parse FAT32 BPB: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func parseBPB() throws {
        var bpbData = Data(count: 512)
        let bytesRead = try bpbData.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: bpbOffset, length: 512)
        }
        guard bytesRead == 512 else { throw FATError.readError }
        
        let bytes = [UInt8](bpbData)
        
        // Basic BPB validation: Check boot signature 0xAA55 at the end
        guard bytes[510] == 0x55 && bytes[511] == 0xAA else {
            throw FATError.invalidBPB
        }
        
        bytesPerSector = readLittleEndianUInt16(bytes, at: 11)
        sectorsPerCluster = bytes[13]
        reservedSectors = readLittleEndianUInt16(bytes, at: 14)
        numberOfFATs = bytes[16]
        
        // FAT32 specific fields
        let fatSize16 = readLittleEndianUInt16(bytes, at: 22)
        if fatSize16 != 0 {
            throw FATError.notFAT32 // It's FAT12/FAT16
        }
        
        fatSize32 = readLittleEndianUInt32(bytes, at: 36)
        
        let totalSectors16 = readLittleEndianUInt16(bytes, at: 19)
        let totalSectors32 = readLittleEndianUInt32(bytes, at: 32)
        let totalSectors = totalSectors16 == 0 ? totalSectors32 : UInt32(totalSectors16)
        
        let rootDirSectors: UInt32 = 0 // For FAT32 this is always 0
        let dataSectors = totalSectors - (UInt32(reservedSectors) + (UInt32(numberOfFATs) * fatSize32) + rootDirSectors)
        
        guard sectorsPerCluster > 0 else { throw FATError.invalidBPB }
        clusterCount = dataSectors / UInt32(sectorsPerCluster)
        
        if clusterCount < 65525 {
            throw FATError.notFAT32
        }
    }
    
    private var dataRegionOffset: UInt64 {
        bpbOffset + UInt64(reservedSectors) * UInt64(bytesPerSector) + UInt64(numberOfFATs) * UInt64(fatSize32) * UInt64(bytesPerSector)
    }
    
    private var fatRegionOffset: UInt64 {
        bpbOffset + UInt64(reservedSectors) * UInt64(bytesPerSector)
    }
    
    private func bytesPerCluster() -> UInt64 {
        UInt64(bytesPerSector) * UInt64(sectorsPerCluster)
    }
    
    private func _populateStream(continuation: AsyncThrowingStream<FreeSpaceRange, Error>.Continuation) async {
        do {
            try await self.initializeIfNeeded()
            
            let fatStart = fatRegionOffset
            let clusterSize = bytesPerCluster()
            let dataStart = dataRegionOffset
            
            // FAT entries are 4 bytes each (FAT32)
            let fatEntriesPerRead = 4096 // 16KB reads = 4096 entries
            let bytesPerRead = fatEntriesPerRead * 4
            
            var currentFreeStartCluster: UInt32? = nil
            var currentFreeLengthClusters: UInt32 = 0
            
            // Valid cluster numbers start at 2
            var clusterIndex: UInt32 = 2
            
            while clusterIndex < clusterCount + 2 {
                try Task.checkCancellation()
                
                let readOffset = fatStart + UInt64(clusterIndex * 4)
                let entriesToRead = min(UInt32(fatEntriesPerRead), clusterCount + 2 - clusterIndex)
                let lengthToRead = Int(entriesToRead * 4)
                
                var chunkData = Data(count: lengthToRead)
                let bytesRead = chunkData.withUnsafeMutableBytes { buffer in
                    self.reader.read(into: buffer.baseAddress!, offset: readOffset, length: lengthToRead)
                }
                
                guard bytesRead == lengthToRead else {
                    throw FATError.readError
                }
                
                let bytes = [UInt8](chunkData)
                
                for i in 0..<Int(entriesToRead) {
                    let entryOffset = i * 4
                    // For FAT32, the upper 4 bits of the 32-bit entry are reserved and should be masked.
                    let entryValue = self.readLittleEndianUInt32(bytes, at: entryOffset) & 0x0FFFFFFF
                    
                    if entryValue == 0x00000000 {
                        // Free cluster
                        if currentFreeStartCluster == nil {
                            currentFreeStartCluster = clusterIndex + UInt32(i)
                            currentFreeLengthClusters = 1
                        } else {
                            currentFreeLengthClusters += 1
                        }
                    } else {
                        // Allocated cluster
                        if let startCluster = currentFreeStartCluster {
                            let physicalOffset = dataStart + UInt64(startCluster - 2) * clusterSize
                            let physicalLength = UInt64(currentFreeLengthClusters) * clusterSize
                            
                            continuation.yield(FreeSpaceRange(startOffset: physicalOffset, length: physicalLength))
                            currentFreeStartCluster = nil
                            currentFreeLengthClusters = 0
                        }
                    }
                }
                
                clusterIndex += entriesToRead
            }
            
            // Yield any remaining free range
            if let startCluster = currentFreeStartCluster {
                let physicalOffset = dataStart + UInt64(startCluster - 2) * clusterSize
                let physicalLength = UInt64(currentFreeLengthClusters) * clusterSize
                continuation.yield(FreeSpaceRange(startOffset: physicalOffset, length: physicalLength))
            }
            
            continuation.finish()
            
        } catch {
            continuation.finish(throwing: error)
        }
    }

    nonisolated func freeSpaceRanges() -> AsyncThrowingStream<FreeSpaceRange, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self._populateStream(continuation: continuation)
            }
        }
    }
    
    private func readLittleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    
    private func readLittleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
