import XCTest
@testable import Vivacity

final class DeepScanServiceTests: XCTestCase {
    func testSignaturePromotionSony() async throws {
        var testBuffer = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        testBuffer.append(Data(repeating: 0, count: 512 - testBuffer.count))
        let fakeReader = FakePrivilegedDiskReader(buffer: testBuffer)
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: 1024, availableCapacity: 0
        )

        // Using sony camera profile.
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .sony)
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard let first = events.first, case let .fileFound(file) = first else {
            XCTFail("First event not fileFound")
            return
        }

        XCTAssertEqual(file.signatureMatch, .arw)
        XCTAssertEqual(file.fileExtension, "arw")
        XCTAssertTrue(file.fileName.starts(with: "DSC0"))
    }

    func testSignaturePromotionDJI() async throws {
        var testBuffer = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        testBuffer.append(Data(repeating: 0, count: 512 - testBuffer.count))
        let fakeReader = FakePrivilegedDiskReader(buffer: testBuffer)
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: 1024, availableCapacity: 0
        )

        // Using dji camera profile.
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .dji)
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard let first = events.first, case let .fileFound(file) = first else {
            XCTFail("First event not fileFound")
            return
        }

        XCTAssertEqual(file.signatureMatch, .dng)
        XCTAssertEqual(file.fileExtension, "dng")
        XCTAssertTrue(file.fileName.starts(with: "DJI_"))
    }

    func testGoProProfileNoPromotionButUsesPrefix() async throws {
        var testBuffer = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        testBuffer.append(Data(repeating: 0, count: 512 - testBuffer.count))
        let fakeReader = FakePrivilegedDiskReader(buffer: testBuffer)
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: 1024, availableCapacity: 0
        )

        // Using gopro camera profile. DeepScanService doesn't promote explicitly for it, but uses prefix.
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .goPro)
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard let first = events.first, case let .fileFound(file) = first else {
            XCTFail("First event not fileFound")
            return
        }

        XCTAssertEqual(file.signatureMatch, .tiff)
        XCTAssertEqual(file.fileExtension, "tiff")
        XCTAssertTrue(file.fileName.starts(with: "GOPR"))
    }

    func testCR2SignatureMatchesCanonPrefix() async throws {
        var cr2Header = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x43, 0x52])
        cr2Header.append(Data(repeating: 0, count: 512 - cr2Header.count))
        let fakeReader = FakePrivilegedDiskReader(buffer: cr2Header)
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: 1024, availableCapacity: 0
        )

        // Using canon camera profile.
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .canon)
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard let first = events.first, case let .fileFound(file) = first else {
            XCTFail("First event not fileFound")
            return
        }

        XCTAssertEqual(file.signatureMatch, .cr2)
        XCTAssertEqual(file.fileExtension, "cr2")
        XCTAssertTrue(file.fileName.starts(with: "IMG_"))
    }

    func testNoSignaturePromotionGeneric() async throws {
        var testBuffer = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        testBuffer.append(Data(repeating: 0, count: 512 - testBuffer.count))
        let fakeReader = FakePrivilegedDiskReader(buffer: testBuffer)
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: 0, partitionSize: 1024, totalCapacity: 1024, availableCapacity: 0
        )

        // Using generic camera profile.
        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard let first = events.first, case let .fileFound(file) = first else {
            XCTFail("First event not fileFound")
            return
        }

        XCTAssertEqual(file.signatureMatch, .tiff)
        XCTAssertEqual(file.fileExtension, "tiff")
        XCTAssertTrue(file.fileName.starts(with: "recovered_"))
    }
}
