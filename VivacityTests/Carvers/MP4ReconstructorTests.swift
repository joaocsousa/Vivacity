import XCTest
@testable import Vivacity

final class MP4ReconstructorTests: XCTestCase {
    /// Helper to generate a fake box
    private func createBox(type: String, size: UInt32) -> Data {
        var data = Data()
        var bigEndianSize = size.bigEndian
        data.append(Data(bytes: &bigEndianSize, count: 4))
        data.append(type.data(using: .ascii)!)

        let payloadSize = Int(size) - 8
        if payloadSize > 0 {
            data.append(Data(repeating: 0, count: payloadSize))
        }
        return data
    }

    /// Extended size box
    private func createExtendedBox(type: String, size: UInt64) -> Data {
        var data = Data()
        var bigEndianSize = UInt32(1).bigEndian // 1 means extended size
        data.append(Data(bytes: &bigEndianSize, count: 4))
        data.append(type.data(using: .ascii)!)

        var bigEndianExtSize = size.bigEndian
        data.append(Data(bytes: &bigEndianExtSize, count: 8))

        let payloadSize = Int(size) - 16
        if payloadSize > 0 {
            data.append(Data(repeating: 0, count: payloadSize))
        }
        return data
    }

    func testCalculatesCorrectSizeForStandardMP4() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "moov", size: 128))
        buffer.append(createBox(type: "mdat", size: 1024))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        XCTAssertEqual(size, 32 + 128 + 1024)
    }

    func testCalculatesCorrectSizeWithExtendedSizeBox() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        // Fake a tiny extended box for testing purposes
        buffer.append(createExtendedBox(type: "mdat", size: 2048))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        XCTAssertEqual(size, 32 + 2048)
    }

    func testIgnoresGarbageAfterValidMP4() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "mdat", size: 512))
        // Garbage data (unreadable FourCC or huge size)
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        // Should return the sum of the valid boxes and ignore the rest
        XCTAssertEqual(size, 32 + 512)
    }

    func testFailsIfNoMdatFound() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "moov", size: 512))
        // No mdat

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        XCTAssertNil(size)
    }

    func testFallsBackToNilWhenOnlyMdatWithoutContainerMetadata() {
        var buffer = Data()
        buffer.append(createBox(type: "mdat", size: 512))
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        XCTAssertNil(size)
    }

    func testFailsOnZeroSizeBox() throws {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))

        var mdat = Data()
        var zeroSize = UInt32(0).bigEndian
        mdat.append(Data(bytes: &zeroSize, count: 4))
        try mdat.append(XCTUnwrap("mdat".data(using: .ascii)))
        buffer.append(mdat)

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let size = reconstructor.calculateContiguousSize(startingAt: 0, reader: fakeReader)
        XCTAssertNil(size)
    }

    // MARK: - Detailed Layout Reconstruction Tests

    func testDetailedLayoutForContiguousFile() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "moov", size: 128))
        buffer.append(createBox(type: "mdat", size: 1024))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let result = reconstructor.reconstructDetailedLayout(startingAt: 0, reader: fakeReader)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalSize, 32 + 128 + 1024)
        XCTAssertEqual(result?.fragments.count, 1)
        XCTAssertFalse(result?.hasDisplacedMoov ?? true)
    }

    func testDetailedLayoutFindsDisplacedMoov() {
        var buffer = Data()
        // ftyp + mdat (no moov contiguous)
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "mdat", size: 1024))
        // Gap of 512 bytes (one sector)
        buffer.append(Data(repeating: 0, count: 512))
        // Displaced moov
        buffer.append(createBox(type: "moov", size: 256))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let result = reconstructor.reconstructDetailedLayout(startingAt: 0, reader: fakeReader)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasDisplacedMoov ?? false)
        XCTAssertEqual(result?.fragments.count, 2)

        // First fragment: ftyp + mdat
        XCTAssertEqual(result?.fragments[0].start, 0)
        XCTAssertEqual(result?.fragments[0].length, 32 + 1024)

        // Second fragment: moov (after the gap)
        let moovStart = UInt64(32 + 1024 + 512)
        XCTAssertEqual(result?.fragments[1].start, moovStart)
        XCTAssertEqual(result?.fragments[1].length, 256)
    }

    func testDetailedLayoutReturnsNilWhenNoMdat() {
        var buffer = Data()
        buffer.append(createBox(type: "ftyp", size: 32))
        buffer.append(createBox(type: "moov", size: 512))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let reconstructor = MP4Reconstructor()

        let result = reconstructor.reconstructDetailedLayout(startingAt: 0, reader: fakeReader)
        XCTAssertNil(result)
    }
}
