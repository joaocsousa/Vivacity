import XCTest
@testable import Vivacity

final class JPEGStreamValidatorTests: XCTestCase {
    private let validator = JPEGStreamValidator()

    func testAcceptsHighEntropyCompressedData() {
        // Simulate compressed JPEG scan data with good entropy and proper byte-stuffing
        var data = [UInt8](repeating: 0, count: 512)
        // Fill with pseudo-random high-entropy data
        for i in 0 ..< data.count {
            data[i] = UInt8((i * 37 + 13) % 256)
        }
        XCTAssertTrue(validator.isPlausibleJPEGScanData(data))
    }

    func testRejectsAllZerosSector() {
        let data = [UInt8](repeating: 0, count: 512)
        XCTAssertFalse(validator.isPlausibleJPEGScanData(data))
    }

    func testRejectsMostlyZerosSector() {
        var data = [UInt8](repeating: 0, count: 512)
        // Only 10% non-zero
        for i in 0 ..< 50 {
            data[i] = UInt8(i + 1)
        }
        XCTAssertFalse(validator.isPlausibleJPEGScanData(data))
    }

    func testRejectsExcessiveMarkerSector() {
        // Fill with lots of bare markers (0xFF followed by non-zero, non-RST)
        var data = [UInt8](repeating: 0, count: 512)
        for i in stride(from: 0, to: 510, by: 2) {
            data[i] = 0xFF
            data[i + 1] = 0xE0 // APP0 marker — not valid in scan data
        }
        XCTAssertFalse(validator.isPlausibleJPEGScanData(data))
    }

    func testAcceptsByteStuffedMarkers() {
        // JPEG scan data with proper byte stuffing (0xFF 0x00)
        var data = [UInt8](repeating: 0, count: 512)
        for i in 0 ..< data.count {
            data[i] = UInt8((i * 73 + 29) % 256)
        }
        // Insert some byte-stuffed sequences (these are valid in scan data)
        data[100] = 0xFF
        data[101] = 0x00
        data[200] = 0xFF
        data[201] = 0x00
        XCTAssertTrue(validator.isPlausibleJPEGScanData(data))
    }

    func testAcceptsRestartMarkers() {
        // JPEG scan data with restart markers (0xFF 0xD0..0xD7) — these are valid
        var data = [UInt8](repeating: 0, count: 512)
        for i in 0 ..< data.count {
            data[i] = UInt8((i * 53 + 7) % 256)
        }
        data[50] = 0xFF
        data[51] = 0xD3 // RST3
        data[150] = 0xFF
        data[151] = 0xD7 // RST7
        XCTAssertTrue(validator.isPlausibleJPEGScanData(data))
    }

    func testRejectsLowEntropySector() {
        // Repeating pattern — very low entropy
        var data = [UInt8](repeating: 0, count: 512)
        for i in 0 ..< data.count {
            data[i] = UInt8(i % 3) // Only 3 unique values
        }
        XCTAssertFalse(validator.isPlausibleJPEGScanData(data))
    }

    func testRejectsEmptyData() {
        XCTAssertFalse(validator.isPlausibleJPEGScanData([]))
    }

    func testAcceptsTypicalScanData() {
        // Create moderately high entropy data that mimics real scan output
        var data = [UInt8](repeating: 0, count: 512)
        var seed: UInt32 = 12345
        for i in 0 ..< data.count {
            // Simple LCG pseudo-random generator for reasonable entropy
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data[i] = UInt8((seed >> 16) & 0xFF)
        }
        XCTAssertTrue(validator.isPlausibleJPEGScanData(data))
    }
}
