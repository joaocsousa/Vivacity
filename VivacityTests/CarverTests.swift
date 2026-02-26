import XCTest
@testable import Vivacity

final class CarverTests: XCTestCase {
    func testFatCarverDetectsDeletedEntry() {
        // BPB for FAT32 with bytes/sector=512, sectors/cluster=1, rootDir at cluster 2
        var bootSector = [UInt8](repeating: 0, count: 512)
        bootSector[11] = 0x00; bootSector[12] = 0x02 // 512 bytes/sector
        bootSector[13] = 0x01 // sectors per cluster
        bootSector[21] = 0xF8 // media
        bootSector[32] = 0x01 // number of FATs
        bootSector[36] = 0x20 // FAT size low byte (dummy)

        guard let bpb = BPB(bootSector: bootSector) else {
            XCTFail("BPB failed to parse")
            return
        }
        let carver = FATCarver(bpb: bpb)

        // Craft a directory entry with 0xE5 deleted marker and short name "TEST    JPG"
        var dir = [UInt8](repeating: 0, count: 512)
        dir[0] = 0xE5
        dir[1...7] = Array("TEST    ".utf8.prefix(7))
        dir[8...10] = Array("JPG".utf8)

        let files = dir.withUnsafeBytes { ptr in
            carver.carveChunk(buffer: ptr, baseOffset: 0)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.fileExtension.lowercased(), "jpg")
    }

    func testAPFSCarverSkipsNonNodes() {
        let carver = APFSCarver()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // leave buffer zeros so it is not a valid node
        let files = buffer.withUnsafeBytes { ptr in
            carver.carveChunk(buffer: ptr, baseOffset: 0)
        }
        XCTAssertTrue(files.isEmpty)
    }
}
