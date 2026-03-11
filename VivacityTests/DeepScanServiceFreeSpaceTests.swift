import XCTest
@testable import Vivacity

final class DeepScanServiceFreeSpaceTests: XCTestCase {
    
    // We can simulate a FAT volume with a mock FAT table to test that DeepScanService
    // successfully skips scanning the allocated clusters and only scans the free clusters.
    
    private func createMockFATVolumeWithFile(totalSectors: UInt64, bytesPerSector: UInt16 = 512, sectorsPerCluster: UInt8 = 8) -> Data {
        var data = Data(repeating: 0, count: Int(totalSectors) * Int(bytesPerSector))
        
        // --- Boot Sector (BPB) ---
        data[11] = UInt8(bytesPerSector & 0xFF)
        data[12] = UInt8((bytesPerSector >> 8) & 0xFF)
        data[13] = sectorsPerCluster
        data[14] = 32 // reserved
        data[15] = 0
        data[16] = 2 // 2 FATs
        
        let sectorsPerFAT: UInt32 = 100
        writeUInt32(&data, at: 36, value: sectorsPerFAT) // sectorsPerFAT32
        
        data[44] = 2
        data[510] = 0x55
        data[511] = 0xAA
        writeUInt32(&data, at: 32, value: UInt32(totalSectors)) // totalSectors32
        
        // --- FAT Table ---
        let fatStart = 32 * Int(bytesPerSector)
        
        writeUInt32(&data, at: fatStart, value: 0x0FFFFFF8)
        writeUInt32(&data, at: fatStart + 4, value: 0xFFFFFFFF)
        
        // Cluster 2: Allocated (Start of data region)
        writeUInt32(&data, at: fatStart + 8, value: 0x0FFFFFFF)
        // Cluster 3: Free
        writeUInt32(&data, at: fatStart + 12, value: 0x00000000)
        // Cluster 4: Free
        writeUInt32(&data, at: fatStart + 16, value: 0x00000000)
        // Cluster 5: Allocated
        writeUInt32(&data, at: fatStart + 20, value: 0x0FFFFFFF)
        
        // --- Data Region ---
        let dataStart = (32 + 2 * Int(sectorsPerFAT)) * Int(bytesPerSector)
        let clusterSize = Int(bytesPerSector) * Int(sectorsPerCluster)
        
        // Cluster 2 (Allocated): Put a JPEG here. It should NOT be emitted!
        writeJPEG(into: &data, at: dataStart)
        
        // Cluster 3 (Free): Put a JPEG here. It SHOULD be emitted!
        writeJPEG(into: &data, at: dataStart + clusterSize)
        
        // Cluster 5 (Allocated): Put a JPEG here. It should NOT be emitted!
        writeJPEG(into: &data, at: dataStart + 3 * clusterSize)
        
        return data
    }
    
    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset+1] = UInt8((value >> 8) & 0xFF)
        data[offset+2] = UInt8((value >> 16) & 0xFF)
        data[offset+3] = UInt8((value >> 24) & 0xFF)
    }
    
    private func writeJPEG(into data: inout Data, at offset: Int) {
        let magic: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        for i in 0..<magic.count {
            data[offset + i] = magic[i]
        }
        // Fill some entropy so confidence score is high
        for i in 4..<2048 {
            data[offset + i] = UInt8.random(in: 1...255)
        }
        data[offset + 2048] = 0xFF
        data[offset + 2049] = 0xD9
    }

    func testDeepScanServiceSkipsAllocatedSpaceUsingMap() async throws {
        // Build mock volume
        let volumeData = createMockFATVolumeWithFile(totalSectors: 600000)
        let fakeReader = FakePrivilegedDiskReader(buffer: volumeData)
        
        // Let's print the free space ranges natively parsed
        let mapper = FATAllocationTable(reader: fakeReader)
        var parsedRanges = [FreeSpaceRange]()
        for try await r in mapper.freeSpaceRanges() {
            print("FAT MAPPER RANGE: \(r)")
            parsedRanges.append(r)
        }
        
        let deepScanService = DeepScanService { _ in fakeReader }
        
        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .fat32, isExternal: true, isDiskImage: true,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(volumeData.count), availableCapacity: 0
        )
        
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)
        
        // Let's print the actual ranges resolved by the scanner if we could, or just the events.
        
        var foundFiles: [RecoverableFile] = []
        for try await event in stream {
            if case let .fileFound(file) = event {
                print("DEBUG: found file: \(file)")
                if file.signatureMatch == .jpeg && file.recoveryConfidence != .low {
                    foundFiles.append(file)
                }
            }
        }
        
        // We injected 3 JPEGs:
        // C2 (Allocated) -> Should be skipped
        // C3 (Free) -> Should be scanned/recovered
        // C5 (Allocated) -> Should be skipped
        XCTAssertEqual(foundFiles.count, 1, "Should only recover the 1 JPEG that resided in free space")
        
        let clusterSize = 512 * 8
        let dataStart = (32 + 2 * 100) * 512
        let expectedOffset = UInt64(dataStart + clusterSize) // Offset of Cluster 3
        
        XCTAssertEqual(foundFiles[0].offsetOnDisk, expectedOffset, "Recovered JPEG should originate from the free cluster")
    }
}
