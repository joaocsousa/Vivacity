import XCTest
@testable import Vivacity

final class PNGChunkValidatorTests: XCTestCase {
    private let validator = PNGChunkValidator()

    func testValidateCriticalChunkCRCsReturnsNoInvalidChunksForValidPNG() {
        let bytes = makeMinimalPNG()

        let validation = validator.validateCriticalChunkCRCs(in: bytes)

        XCTAssertEqual(validation?.validatedCriticalChunkCount, 2)
        XCTAssertEqual(validation?.invalidCriticalChunkCount, 0)
        XCTAssertEqual(validation?.hasInvalidCriticalChunkCRC, false)
    }

    func testValidateCriticalChunkCRCsFlagsCorruptedIHDRChunk() {
        var bytes = makeMinimalPNG()
        bytes[16] ^= 0x01 // Corrupt IHDR data without updating CRC.

        let validation = validator.validateCriticalChunkCRCs(in: bytes)

        XCTAssertEqual(validation?.validatedCriticalChunkCount, 2)
        XCTAssertEqual(validation?.invalidCriticalChunkCount, 1)
        XCTAssertEqual(validation?.hasInvalidCriticalChunkCRC, true)
    }

    func testValidateCriticalChunkCRCsReturnsNilForMissingIEND() {
        var bytes = makeMinimalPNG()
        bytes.removeLast(12) // Remove IEND chunk.

        let validation = validator.validateCriticalChunkCRCs(in: bytes)

        XCTAssertNil(validation)
    }

    private func makeMinimalPNG() -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        // IHDR chunk: length(13), type("IHDR"), data, CRC.
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        bytes.append(contentsOf: [0x49, 0x48, 0x44, 0x52])
        bytes.append(contentsOf: [
            0x00, 0x00, 0x00, 0x01, // width = 1
            0x00, 0x00, 0x00, 0x01, // height = 1
            0x08, // bit depth
            0x02, // color type RGB
            0x00, // compression
            0x00, // filter
            0x00, // interlace
        ])
        bytes.append(contentsOf: [0x90, 0x77, 0x53, 0xDE])

        // IEND chunk: length(0), type("IEND"), CRC.
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x49, 0x45, 0x4E, 0x44])
        bytes.append(contentsOf: [0xAE, 0x42, 0x60, 0x82])

        return bytes
    }
}
