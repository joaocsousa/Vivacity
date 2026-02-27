import XCTest
@testable import Vivacity

final class CarverTests: XCTestCase {
    func testFatCarverDetectsDeletedEntry() {
        // BPB for FAT32 with bytes/sector=512, sectors/cluster=1, rootDir at cluster 2
        var bootSector = [UInt8](repeating: 0, count: 512)
        bootSector[11] = 0x00
        bootSector[12] = 0x02 // bytesPerSector = 512
        bootSector[13] = 0x01 // sectorsPerCluster = 1
        bootSector[14] = 0x20
        bootSector[15] = 0x00 // reservedSectors = 32
        bootSector[16] = 0x02 // numberOfFATs = 2
        bootSector[32] = 0x00
        bootSector[33] = 0x20 // totalSectors
        bootSector[36] = 0x20 // sectorsPerFAT
        bootSector[510] = 0x55
        bootSector[511] = 0xAA // Signature

        guard let bpb = BPB(bootSector: bootSector) else {
            XCTFail("BPB failed to parse")
            return
        }
        var carver = FATCarver(bpb: bpb)

        // Craft a directory entry with 0xE5 deleted marker and short name "TEST    JPG"
        var dir = [UInt8](repeating: 0, count: 512)
        dir[0] = 0xE5
        let nameRest = Array("TEST   JPG".utf8)
        for i in 0 ..< 10 {
            dir[i + 1] = nameRest[i]
        }
        dir[26] = 0x02 // Starting cluster = 2
        dir[29] = 0x04 // File size = 1024

        let files = dir.withUnsafeBytes { ptr in
            carver.carveChunk(buffer: ptr, baseOffset: 0)
        }

        XCTAssertEqual(files.count, 1)
        let ext = files.first?.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        XCTAssertEqual(ext, "jpg")
    }

    func testAPFSCarverSkipsNonNodes() {
        var carver = APFSCarver()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // leave buffer zeros so it is not a valid node
        let files = buffer.withUnsafeBytes { ptr in
            carver.carveChunk(buffer: ptr, baseOffset: 0)
        }
        XCTAssertTrue(files.isEmpty)
    }
}
