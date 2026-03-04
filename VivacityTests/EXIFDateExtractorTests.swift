import Foundation
import XCTest
@testable import Vivacity

final class EXIFDateExtractorTests: XCTestCase {
    func testExtractMetadataFromPartialJPEGWithTimeZone() {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0xFF
        bytes[1] = 0xD8

        writeASCII("DateTimeOriginal", to: &bytes, at: 24)
        writeASCII("2024:11:23 18:45:01+02:00", to: &bytes, at: 64)
        writeASCII("Canon EOS R5", to: &bytes, at: 128)

        let metadata = EXIFDateExtractor.extractMetadata(from: bytes)
        XCTAssertEqual(metadata?.captureTimeToken, "20241123_184501+0200")
        XCTAssertEqual(metadata?.deviceToken, "Canon")
    }

    func testExtractMetadataFromPartialMOVUsingMVHD() throws {
        var bytes = [UInt8](repeating: 0, count: 256)
        writeASCII("mvhd", to: &bytes, at: 20)
        bytes[24] = 0 // version
        bytes[25] = 0 // flags
        bytes[26] = 0
        bytes[27] = 0

        let utcDate = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2025,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5
        ).date)

        let quickTimeEpochDelta: TimeInterval = 2_082_844_800
        let quickTimeSeconds = UInt32(utcDate.timeIntervalSince1970 + quickTimeEpochDelta)
        writeUInt32BE(quickTimeSeconds, to: &bytes, at: 28)
        writeASCII("GoPro", to: &bytes, at: 80)

        let metadata = EXIFDateExtractor.extractMetadata(from: bytes)
        XCTAssertEqual(metadata?.captureTimeToken, "20250102_030405+0000")
        XCTAssertEqual(metadata?.deviceToken, "GoPro")
    }

    private func writeASCII(_ string: String, to bytes: inout [UInt8], at offset: Int) {
        for (index, byte) in string.utf8.enumerated() where offset + index < bytes.count {
            bytes[offset + index] = byte
        }
    }

    private func writeUInt32BE(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        guard offset + 3 < bytes.count else { return }
        bytes[offset + 0] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
