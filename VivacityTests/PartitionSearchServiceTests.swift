import XCTest
@testable import Vivacity

final class PartitionSearchServiceTests: XCTestCase {
    
    // We'll use a FakePrivilegedDiskReader to supply the bytes.
    // The Master Boot Record (MBR) is at LBA 0 (bytes 0-511).
    // The GUID Partition Table (GPT) Header is at LBA 1 (bytes 512-1023).
    // The GPT Partition Array is typically at LBA 2 (bytes 1024+).

    func testFindsGPTAlignedPartitions() async throws {
        // Setup a fake disk with a valid protective MBR and a GPT header containing 1 partition
        var diskBytes = [UInt8](repeating: 0, count: 32768)
        
        // --- 1. Fake Protective MBR at LBA 0 (0-511) ---
        // Signature: 0x55 0xAA at offset 510
        diskBytes[510] = 0x55
        diskBytes[511] = 0xAA
        // Partition 1 Type: 0xEE (GPT Protective) at offset 450
        diskBytes[446 + 4] = 0xEE
        
        // --- 2. Fake GPT Header at LBA 1 (512-1023) ---
        // Signature: "EFI PART" (8 bytes)
        let signature = Array("EFI PART".utf8)
        for i in 0..<8 {
            diskBytes[512 + i] = signature[i]
        }
        
        // Revision: 00 00 01 00 (4 bytes)
        diskBytes[512 + 8] = 0x00
        diskBytes[512 + 9] = 0x00
        diskBytes[512 + 10] = 0x01
        diskBytes[512 + 11] = 0x00
        
        // HeaderSize: 92 (4 bytes)
        diskBytes[512 + 12] = 92
        
        // Starting LBA of array of partition entries: typically 2 (8 bytes) at offset 72
        diskBytes[512 + 72] = 2
        
        // Number of partition entries: typically 128 (4 bytes) at offset 80
        diskBytes[512 + 80] = 128
        
        // Size of a single partition entry: typically 128 (4 bytes) at offset 84
        diskBytes[512 + 84] = 128
        
        // --- 3. Fake GPT Partition Entry at LBA 2 (1024-1151) ---
        // Partition Type GUID: e.g. Basic Data (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
        // Stored as little-endian mixed format.
        // We'll just put some bytes and test that it parses the bounds.
        let typeGUID: [UInt8] = [
            0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
            0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7
        ]
        for i in 0..<16 {
            diskBytes[1024 + i] = typeGUID[i]
        }
        
        // Unique Partition GUID (16 bytes) at offset 16
        // Skipping...
        
        // First LBA (8 bytes) at offset 32. Let's say LBA 40
        let firstLBA: UInt64 = 40
        withUnsafeBytes(of: firstLBA.littleEndian) { bytes in
            for (i, byte) in bytes.enumerated() {
                diskBytes[1024 + 32 + i] = byte
            }
        }
        
        // Last LBA (8 bytes) at offset 40. Let's say LBA 2000
        let lastLBA: UInt64 = 2000
        withUnsafeBytes(of: lastLBA.littleEndian) { bytes in
            for (i, byte) in bytes.enumerated() {
                diskBytes[1024 + 40 + i] = byte
            }
        }
        
        let reader = FakePrivilegedDiskReader(buffer: Data(diskBytes))
        let sut = PartitionSearchService()
        
        let partitions = try await sut.findPartitions(on: "/dev/fake", reader: reader)
        
        XCTAssertEqual(partitions.count, 1)
        guard let p = partitions.first else { return }
        XCTAssertEqual(p.partitionOffset, 40 * 512)
        XCTAssertEqual(p.partitionSize, (2000 - 40 + 1) * 512)
        XCTAssertEqual(p.name, "Lost Partition @ 20 KB")
    }
}
