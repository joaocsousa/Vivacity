import XCTest
@testable import Vivacity

final class FATAllocationTableTests: XCTestCase {
    
    private func createMockFATVolume(totalSectors: UInt64, bytesPerSector: UInt16 = 512, sectorsPerCluster: UInt8 = 8) -> Data {
        var data = Data(repeating: 0, count: Int(totalSectors) * Int(bytesPerSector))
        
        // --- Boot Sector (BPB) ---
        // bytesPerSector
        data[11] = UInt8(bytesPerSector & 0xFF)
        data[12] = UInt8((bytesPerSector >> 8) & 0xFF)
        // sectorsPerCluster
        data[13] = sectorsPerCluster
        // reservedSectorCount (e.g. 32)
        data[14] = 32
        data[15] = 0
        // numberOfFATs
        data[16] = 2
        
        // sectorsPerFAT32 (e.g. 100)
        let sectorsPerFAT: UInt32 = 100
        data[36] = UInt8(sectorsPerFAT & 0xFF)
        data[37] = UInt8((sectorsPerFAT >> 8) & 0xFF)
        data[38] = UInt8((sectorsPerFAT >> 16) & 0xFF)
        data[39] = UInt8((sectorsPerFAT >> 24) & 0xFF)
        
        // rootCluster
        data[44] = 2
        data[45] = 0
        data[46] = 0
        data[47] = 0
        
        // Signature
        data[510] = 0x55
        data[511] = 0xAA
        
        // totalSectors32
        data[32] = UInt8(totalSectors & 0xFF)
        data[33] = UInt8((totalSectors >> 8) & 0xFF)
        data[34] = UInt8((totalSectors >> 16) & 0xFF)
        data[35] = UInt8((totalSectors >> 24) & 0xFF)
        
        // --- FAT Table ---
        let fatStart = 32 * Int(bytesPerSector)
        
        // Set cluster 2 and 3 as allocated (0x0FFFFFFF), cluster 4 as free (0x00000000)
        // FAT entries are 32 bits (4 bytes).
        
        // Cluster 0 and 1 are reserved, usually 0x0FFFFFF8 and 0xFFFFFFFF
        writeUInt32(&data, at: fatStart, value: 0x0FFFFFF8)
        writeUInt32(&data, at: fatStart + 4, value: 0xFFFFFFFF)
        
        // Cluster 2: Allocated
        writeUInt32(&data, at: fatStart + 8, value: 0x0FFFFFFF)
        // Cluster 3: Allocated
        writeUInt32(&data, at: fatStart + 12, value: 0x0FFFFFFF)
        // Cluster 4: Free (Explicitly 0)
        writeUInt32(&data, at: fatStart + 16, value: 0x00000000)
        // Cluster 5: Free (Explicitly 0)
        writeUInt32(&data, at: fatStart + 20, value: 0x00000000)
        // Cluster 6: Allocated
        writeUInt32(&data, at: fatStart + 24, value: 0x0FFFFFFF)
        
        return data
    }
    
    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset+1] = UInt8((value >> 8) & 0xFF)
        data[offset+2] = UInt8((value >> 16) & 0xFF)
        data[offset+3] = UInt8((value >> 24) & 0xFF)
    }

    func testFATAllocationTableParsesValidMap() async throws {
        let volumeData = createMockFATVolume(totalSectors: 600000)
        let reader = FakePrivilegedDiskReader(buffer: volumeData)
        let mapper = FATAllocationTable(reader: reader)
        
        var ranges: [FreeSpaceRange] = []
        for try await range in mapper.freeSpaceRanges() {
            ranges.append(range)
        }
        
        // We know cluster 4 and 5 are free. Valid clusters start at 2.
        // Data region starts after reserved (32) + 2 FATs * sectorsPerFat (100) = 232 sectors.
        // Cluster 4 is (4 - 2) = 2 clusters into data region.
        // Cluster size = 8 sectors * 512 bytes = 4096 bytes.
        // Thus, cluster 4 is offset: 232 * 512 + 2 * 4096 = 118784 + 8192 = 126976
        
        XCTAssertFalse(ranges.isEmpty, "Should find free space ranges")
        
        // First contiguous free range is clusters 4 and 5 (length 2 clusters = 8192 bytes)
        XCTAssertEqual(ranges[0].startOffset, 126976)
        XCTAssertEqual(ranges[0].length, 8192)
        XCTAssertEqual(ranges[0].endOffset, 126976 + 8192)
    }
}
