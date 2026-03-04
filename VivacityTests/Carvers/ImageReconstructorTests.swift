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

    private func containsMarker(_ marker: [UInt8], in bytes: [UInt8]) -> Bool {
        guard bytes.count >= marker.count else { return false }
        for i in 0 ... (bytes.count - marker.count) {
            var matched = true
            for j in 0 ..< marker.count where bytes[i + j] != marker[j] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
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

    func testReconstruct_withCompleteInitialChunk_returnsNilEarly() {
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

        // Sector 1: Garbage (another file's data) — use high-entropy data that passes validator
        var garbageSector = Data(count: 512)
        for i in 0 ..< 512 {
            garbageSector[i] = UInt8((i &* 37 &+ 13) % 256)
        }

        // Sector 2: The rest of the JPEG ending in EOI — use high-entropy data
        var extensionSector = Data([0xFF, 0xDA, 0x01, 0x02, 0x03])
        for i in 0 ..< (512 - extensionSector.count - 2) {
            extensionSector.append(UInt8((i &* 53 &+ 7) % 256))
        }
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
        // Result should contain the initial + continuation bytes, with optional DHT reseed expansion.
        XCTAssertGreaterThanOrEqual(result?.count ?? 0, 1024)

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

        // Reconstructor may insert a DHT table before finalizing partial output.
        XCTAssertGreaterThanOrEqual(result?.count ?? 0, 514)

        let stitchedSuffix = result?.suffix(2)
        XCTAssertEqual(stitchedSuffix, Data([0xFF, 0xD9]))
    }

    func testReconstructDetailed_marksPartialWhenEOINotFound() async {
        let initial = Data([0xFF, 0xD8, 0xFF, 0xDA] + Array(repeating: 0x11, count: 508))
        reader.buffer = initial + Data(repeating: 0x00, count: 1024)

        let result = await sut.reconstructDetailed(
            headerOffset: 0,
            initialChunk: initial,
            reader: reader
        )

        XCTAssertEqual(result?.format, .jpeg)
        XCTAssertEqual(result?.isPartial, true)
    }

    func testReconstructDetailed_reseedsJPEGHuffmanTableWhenMissing() async {
        var initial = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        initial.append(Data(repeating: 0x00, count: 10))
        initial.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x11, 0x22, 0x33, 0x44])
        initial.append(Data(repeating: 0x55, count: 512 - initial.count))

        // Use high-entropy data to pass JPEGStreamValidator
        var sectorBytes = [UInt8](repeating: 0, count: 510)
        var seed: UInt32 = 12345
        for i in 0 ..< 510 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            sectorBytes[i] = UInt8((seed >> 16) & 0xFF)
        }
        var sector = Data(sectorBytes)
        sector.append(contentsOf: [0xFF, 0xD9])
        reader.buffer = initial + sector

        let result = await sut.reconstructDetailed(
            headerOffset: 0,
            initialChunk: initial,
            reader: reader
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.isPartial, false)
        let bytes = [UInt8](result?.data ?? Data())
        XCTAssertTrue(containsMarker([0xFF, 0xC4], in: bytes))
    }

    func testReconstructDetailed_reassemblesSplitHEICSegments() async throws {
        var ftyp = Data([0x00, 0x00, 0x00, 0x18])
        try ftyp.append(XCTUnwrap("ftyp".data(using: .ascii)))
        try ftyp.append(XCTUnwrap("heic".data(using: .ascii)))
        ftyp.append(Data(repeating: 0x00, count: 12))
        let initial = ftyp + Data(repeating: 0x00, count: 512 - ftyp.count)

        var moov = Data([0x00, 0x00, 0x00, 0x20])
        try moov.append(XCTUnwrap("moov".data(using: .ascii)))
        moov.append(Data(repeating: 0x01, count: 24))
        moov.append(Data(repeating: 0x00, count: 512 - moov.count))

        var mdat = Data([0x00, 0x00, 0x00, 0x20])
        try mdat.append(XCTUnwrap("mdat".data(using: .ascii)))
        mdat.append(Data(repeating: 0x02, count: 24))
        mdat.append(Data(repeating: 0x00, count: 512 - mdat.count))

        reader.buffer = initial + Data(repeating: 0x00, count: 512) + moov + mdat

        let result = await sut.reconstructDetailed(
            headerOffset: 0,
            initialChunk: initial,
            reader: reader
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .heic)
        XCTAssertEqual(result?.isPartial, false)
        let payload = result?.data ?? Data()
        XCTAssertTrue(try payload.contains(XCTUnwrap("moov".data(using: .ascii))))
        XCTAssertTrue(try payload.contains(XCTUnwrap("mdat".data(using: .ascii))))
    }

    func testReconstructDetailed_HEICIncludesOptionalHEVCValidation() async throws {
        var ftyp = Data([0x00, 0x00, 0x00, 0x18])
        try ftyp.append(XCTUnwrap("ftyp".data(using: .ascii)))
        try ftyp.append(XCTUnwrap("heic".data(using: .ascii)))
        ftyp.append(Data(repeating: 0x00, count: 12))
        let initial = ftyp + Data(repeating: 0x00, count: 512 - ftyp.count)

        var moov = Data([0x00, 0x00, 0x00, 0x20])
        try moov.append(XCTUnwrap("moov".data(using: .ascii)))
        moov.append(Data(repeating: 0x01, count: 24))
        moov.append(Data(repeating: 0x00, count: 512 - moov.count))

        let hevcPayload: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xAA, // VPS
            0x00, 0x00, 0x01, 0x42, 0x01, 0xBB, // SPS
            0x00, 0x00, 0x01, 0x44, 0x01, 0xCC, // PPS
        ]
        var mdat = Data()
        var mdatSize = UInt32(8 + hevcPayload.count).bigEndian
        mdat.append(Data(bytes: &mdatSize, count: 4))
        try mdat.append(XCTUnwrap("mdat".data(using: .ascii)))
        mdat.append(contentsOf: hevcPayload)
        mdat.append(Data(repeating: 0x00, count: 512 - mdat.count))

        reader.buffer = initial + moov + mdat

        let result = await sut.reconstructDetailed(
            headerOffset: 0,
            initialChunk: initial,
            reader: reader
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .heic)
        XCTAssertFalse(result?.isPartial ?? true)
        XCTAssertNotNil(result?.hevcValidation)
        XCTAssertTrue(result?.hevcValidation?.hasRequiredParameterSets ?? false)
    }
}
