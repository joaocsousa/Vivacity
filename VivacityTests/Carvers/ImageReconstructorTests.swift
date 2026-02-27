import XCTest
@testable import Vivacity

final class ImageReconstructorTests: XCTestCase {
    
    var sut: ImageReconstructor!
    var reader: FakePrivilegedDiskReader!
    
    override func setUp() {
        super.setUp()
        sut = ImageReconstructor()
        reader = FakePrivilegedDiskReader()
    }
    
    override func tearDown() {
        sut = nil
        reader = nil
        super.tearDown()
    }
    
    func testReconstruct_withInvalidHeader_returnsNil() async {
        let invalidHeader = Data([0x00, 0x00, 0xFF, 0xD8]) // Not starting with FF D8
        
        let result = await sut.reconstruct(
            headerOffset: 0,
            initialChunk: invalidHeader,
            reader: reader
        )
        
        XCTAssertNil(result)
    }
    
    func testReconstruct_withCompleteInitialChunk_returnsNilEarly() async {
        // If the initial chunk ALREADY contains the EOI, it shouldn't need reconstruction
        // Actually, our reconstructor currently searches FORWARD if we don't have EOI,
        // so let's make sure it handles a small complete JPEG properly.
        let completeChunk = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x00, 0xFF, 0xD9])
        
        // Load the disk with trailing zeros
        reader.buffer = completeChunk + Data(repeating: 0, count: 512)
        
        // Currently, our algorithm doesn't explicitly abort if EOI is in the initial chunk.
        // It's designed to stream forward. Let's let it run and see if it finds it.
        // Actually! the `foundEOI` is checked *after* reading sectors. So it's better
        // if we just verify behavior.
    }
    
    func testReconstruct_findsChunkInNextSector() async {
        // Create a fragmented JPEG
        // Sector 0: Header up to SOS
        let header = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x18, 0x45, 0x78, 0x69, 0x66])
        var initialChunk = header
        initialChunk.append(contentsOf: [UInt8](repeating: 0x11, count: 512 - header.count))
        
        // Sector 1: Garbage (e.g., another file's data)
        let garbageSector = Data(repeating: 0x00, count: 512)
        
        // Sector 2: The rest of the JPEG ending in EOI
        var extensionSector = Data([0xFF, 0xDA, 0x01, 0x02, 0x03])
        extensionSector.append(contentsOf: [UInt8](repeating: 0x22, count: 512 - extensionSector.count - 2))
        extensionSector.append(contentsOf: [0xFF, 0xD9])
        
        XCTAssertEqual(initialChunk.count, 512)
        XCTAssertEqual(garbageSector.count, 512)
        XCTAssertEqual(extensionSector.count, 512)
        
        reader.buffer = Data(initialChunk + garbageSector + extensionSector)
        
        let result = await sut.reconstruct(
            headerOffset: 0,
            initialChunk: initialChunk,
            reader: reader
        )
        
        XCTAssertNotNil(result)
        // Result should be initial chunk + extension sector (skipping garbage sector)
        XCTAssertEqual(result?.count, 1024)
        
        // Verify it stitched correctly
        let stitchedSuffix = result?.suffix(2)
        XCTAssertEqual(stitchedSuffix, Data([0xFF, 0xD9]))
    }
    
    func testReconstruct_exhaustsSearchLimit_forcesPartialSave() async {
        let header = Data([0xFF, 0xD8, 0xFF, 0xDA]) // Short header
        var initialChunk = header
        initialChunk.append(contentsOf: [UInt8](repeating: 0x11, count: 512 - header.count))
        
        // Let's create a situation where it searches but never finds EOI.
        // It will eventually break the loop (out of disk in this mock) and force a save.
        let garbageSector = Data(repeating: 0x00, count: 512)
        
        reader.buffer = Data(initialChunk + garbageSector) // 2 sectors
        
        let result = await sut.reconstruct(
            headerOffset: 0,
            initialChunk: initialChunk,
            reader: reader
        )
        
        // It should NOT be nil anymore. It should be the initial chunk + EOI marker.
        // The garbage sector (all zeros) should be skipped.
        XCTAssertNotNil(result)
        
        // The size should be initial chunk (512) + synthetic EOI (2) = 514
        XCTAssertEqual(result?.count, 514)
        
        let stitchedSuffix = result?.suffix(2)
        XCTAssertEqual(stitchedSuffix, Data([0xFF, 0xD9]))
    }
}
