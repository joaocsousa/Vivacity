import XCTest
@testable import Vivacity

final class CameraRecoveryServiceTests: XCTestCase {
    var service: CameraRecoveryService!

    override func setUp() {
        super.setUp()
        service = CameraRecoveryService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    private func createTestFile(source: ScanSource, filePath: String?) -> RecoverableFile {
        RecoverableFile(
            id: UUID(),
            fileName: "test.jpg",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 1024,
            offsetOnDisk: 0,
            signatureMatch: .jpeg,
            source: source,
            filePath: filePath
        )
    }

    func testDetectGoProProfile() {
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/100GOPRO/GOPR0001.JPG"),
            createTestFile(source: .fastScan, filePath: "/DCIM/100GOPRO/GOPR0002.JPG"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .goPro)
    }

    func testDetectCanonProfile() {
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/100CANON/IMG_0001.JPG"),
            createTestFile(source: .fastScan, filePath: "/EOSMISC/M0001.TXT"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .canon)
    }

    func testDetectSonyProfile() {
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/100MSDCF/DSC0001.JPG"),
            createTestFile(source: .fastScan, filePath: "/MP_ROOT/100ANV01/M0001.MP4"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .sony)
    }

    func testDetectDJIProfile() {
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/100MEDIA/DJI_0001.JPG"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .dji)
    }

    func testDetectGenericProfileWithNoClues() {
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/RANDOM/IMG_01.JPG"),
            createTestFile(source: .fastScan, filePath: "/Users/Docs/photo.jpg"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .generic)
    }

    func testDetectGenericProfileWithEmptyFiles() {
        let profile = service.detectProfile(from: [])
        XCTAssertEqual(profile, .generic)
    }

    func testIgnoresDeepScanFiles() {
        // Even if deep scan files magically mapped to a path (they don't), they should be ignored
        let files = [
            createTestFile(source: .deepScan, filePath: "/DCIM/100GOPRO/file.jpg"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .generic)
    }

    func testHighestScoreWins() {
        // Give 2 hints for GoPro, 1 hint for Sony
        let files = [
            createTestFile(source: .fastScan, filePath: "/DCIM/100GOPRO/GOPR0001.JPG"),
            createTestFile(source: .fastScan, filePath: "/DCIM/100GOPRO/GOPR0002.JPG"),
            createTestFile(source: .fastScan, filePath: "/DCIM/100MSDCF/oops.jpg"),
        ]

        let profile = service.detectProfile(from: files)
        XCTAssertEqual(profile, .goPro)
    }
}
