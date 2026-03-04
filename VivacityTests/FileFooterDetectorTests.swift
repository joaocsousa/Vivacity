import XCTest
@testable import Vivacity

final class FileFooterDetectorTests: XCTestCase {
    private let detector = FileFooterDetector()

    // MARK: - BMP Tests

    func testBMPSizeExtractsExactSizeFromHeader() {
        // BMP header: "BM" + 4 bytes little-endian file size
        var data = Data()
        data.append(contentsOf: [0x42, 0x4D]) // "BM"

        // File size = 12345 (0x3039) as little-endian
        let fileSize: UInt32 = 12345
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })

        // Rest of header padding
        data.append(Data(repeating: 0, count: 8))
        // Some pixel data
        data.append(Data(repeating: 0xFF, count: Int(fileSize) - 14))

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateBMPSize(startOffset: 0, reader: reader)
        XCTAssertEqual(size, 12345)
    }

    func testBMPSizeRejectsNonBMPData() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateBMPSize(startOffset: 0, reader: reader)
        XCTAssertNil(size)
    }

    func testBMPSizeRejectsTooSmallFileSize() {
        // "BM" + file size of 5 (below minimum 14 byte header)
        var data = Data([0x42, 0x4D])
        data.append(contentsOf: withUnsafeBytes(of: UInt32(5).littleEndian) { Array($0) })
        data.append(Data(repeating: 0, count: 8))

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateBMPSize(startOffset: 0, reader: reader)
        XCTAssertNil(size)
    }

    func testBMPSizeWithOffset() {
        // Put garbage before, then the BMP at offset 100
        var data = Data(repeating: 0xAA, count: 100)
        data.append(contentsOf: [0x42, 0x4D]) // "BM"
        let fileSize: UInt32 = 5000
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(Data(repeating: 0, count: 8))

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateBMPSize(startOffset: 100, reader: reader)
        XCTAssertEqual(size, 5000)
    }

    // MARK: - WebP Tests

    func testWebPSizeExtractsExactSizeFromRIFFHeader() throws {
        // RIFF header: "RIFF" + 4 bytes LE chunk size + "WEBP"
        var data = Data()
        try data.append(XCTUnwrap("RIFF".data(using: .ascii)))

        // Chunk size = total - 8. For a 1000 byte file: chunkSize = 992
        let chunkSize: UInt32 = 992
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        try data.append(XCTUnwrap("WEBP".data(using: .ascii)))
        data.append(Data(repeating: 0, count: Int(chunkSize) - 4))

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateWebPSize(startOffset: 0, reader: reader)
        XCTAssertEqual(size, 1000) // chunkSize + 8
    }

    func testWebPSizeRejectsNonWebPData() throws {
        // RIFF + AVI instead of WEBP
        var data = Data()
        try data.append(XCTUnwrap("RIFF".data(using: .ascii)))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(100).littleEndian) { Array($0) })
        try data.append(XCTUnwrap("AVI ".data(using: .ascii)))

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateWebPSize(startOffset: 0, reader: reader)
        XCTAssertNil(size)
    }

    func testWebPSizeRejectsGarbage() {
        let data = Data(repeating: 0xFF, count: 20)
        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = detector.estimateWebPSize(startOffset: 0, reader: reader)
        XCTAssertNil(size)
    }

    // MARK: - GIF Tests

    func testGIFSizeFindsTrailerInSimpleGIF89a() async throws {
        // Minimal GIF89a with no global color table, one 1x1 image
        var data = Data()
        // GIF89a header
        try data.append(XCTUnwrap("GIF89a".data(using: .ascii)))
        // Logical Screen Descriptor: width=1, height=1, packed=0 (no GCT), bg=0, aspect=0
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        // Image Descriptor: separator=0x2C, left=0, top=0, width=1, height=1, packed=0
        data.append(contentsOf: [0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        // LZW Minimum Code Size
        data.append(contentsOf: [0x02])
        // Sub-block: 2 bytes of LZW data
        data.append(contentsOf: [0x02, 0x4C, 0x01])
        // Block terminator
        data.append(contentsOf: [0x00])
        // Trailer
        data.append(contentsOf: [0x3B])

        let expectedSize = Int64(data.count)

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = try await detector.estimateSize(
            signature: .gif,
            startOffset: 0,
            reader: reader,
            maxScanBytes: data.count
        )
        XCTAssertEqual(size, expectedSize)
    }

    func testGIFSizeRejectsNonGIFData() async throws {
        let data = Data(repeating: 0x00, count: 100)
        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = try await detector.estimateSize(
            signature: .gif,
            startOffset: 0,
            reader: reader,
            maxScanBytes: data.count
        )
        XCTAssertNil(size)
    }

    func testGIFSizeHandlesGlobalColorTable() async throws {
        var data = Data()
        // GIF89a header
        try data.append(XCTUnwrap("GIF89a".data(using: .ascii)))
        // Packed: GCT present (0x80), 2 entries (size field = 0 means 2^(0+1) = 2 entries, 2*3 = 6 bytes)
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00])
        // Global Color Table (2 entries * 3 bytes = 6 bytes)
        data.append(Data(repeating: 0x00, count: 6))
        // Image Descriptor
        data.append(contentsOf: [0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        // LZW Minimum Code Size
        data.append(contentsOf: [0x02])
        // Sub-block: 2 bytes
        data.append(contentsOf: [0x02, 0x4C, 0x01])
        // Block terminator
        data.append(contentsOf: [0x00])
        // Trailer
        data.append(contentsOf: [0x3B])

        let expectedSize = Int64(data.count)

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = try await detector.estimateSize(
            signature: .gif,
            startOffset: 0,
            reader: reader,
            maxScanBytes: data.count
        )
        XCTAssertEqual(size, expectedSize)
    }

    // MARK: - JPEG Tests (smoke check existing behavior)

    func testJPEGSizeFindsEOIMarker() async throws {
        var data = Data()
        // SOI
        data.append(contentsOf: [0xFF, 0xD8])
        // SOF0 (minimal: marker + length(11) + precision + height + width + components)
        data.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00])
        // EOI
        data.append(contentsOf: [0xFF, 0xD9])

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = try await detector.estimateSize(
            signature: .jpeg,
            startOffset: 0,
            reader: reader,
            maxScanBytes: data.count
        )
        XCTAssertEqual(size, Int64(data.count))
    }

    // MARK: - PNG Tests (smoke check existing behavior)

    func testPNGSizeFindsIENDChunk() async throws {
        var data = Data()
        // PNG signature
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Minimal IHDR chunk (length=13, type="IHDR", data, CRC)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // length
        try data.append(XCTUnwrap("IHDR".data(using: .ascii)))
        data.append(Data(repeating: 0, count: 13)) // IHDR data
        data.append(Data(repeating: 0, count: 4)) // CRC
        // IEND chunk (length=0, type="IEND", CRC)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // length
        data.append(contentsOf: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]) // IEND + CRC

        let reader = FakePrivilegedDiskReader(buffer: data)
        let size = try await detector.estimateSize(
            signature: .png,
            startOffset: 0,
            reader: reader,
            maxScanBytes: data.count
        )
        XCTAssertEqual(size, Int64(data.count))
    }
}
