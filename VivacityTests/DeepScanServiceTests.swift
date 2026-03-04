import XCTest
@testable import Vivacity

final class DeepScanServiceTests: XCTestCase {
    func testDeepScanDetectsAVIFBrand() async throws {
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66,
            0x00, 0x00, 0x00, 0x00,
        ]
        bytes.append(contentsOf: Array(repeating: 0x00, count: 2048 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let stream = deepScanService.scan(
            device: makeDevice(totalCapacity: Int64(bytes.count)),
            existingOffsets: [],
            startOffset: 0,
            cameraProfile: .generic
        )

        var firstFoundFile: RecoverableFile?
        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertEqual(firstFoundFile?.signatureMatch, .avif)
        XCTAssertEqual(firstFoundFile?.fileExtension, "avif")
    }

    func testDeepScanDetectsCR3Brand() async throws {
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x63, 0x72, 0x33, 0x20,
            0x00, 0x00, 0x00, 0x00,
        ]
        bytes.append(contentsOf: Array(repeating: 0x00, count: 2048 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let stream = deepScanService.scan(
            device: makeDevice(totalCapacity: Int64(bytes.count)),
            existingOffsets: [],
            startOffset: 0,
            cameraProfile: .canon
        )

        var firstFoundFile: RecoverableFile?
        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertEqual(firstFoundFile?.signatureMatch, .cr3)
        XCTAssertEqual(firstFoundFile?.fileExtension, "cr3")
    }

    func testDeepScanDetectsRAFDirectSignature() async throws {
        var bytes = FileSignature.raf.magicBytes
        bytes.append(contentsOf: Array(repeating: 0x00, count: 2048 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let stream = deepScanService.scan(
            device: makeDevice(totalCapacity: Int64(bytes.count)),
            existingOffsets: [],
            startOffset: 0,
            cameraProfile: .generic
        )

        var firstFoundFile: RecoverableFile?
        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertEqual(firstFoundFile?.signatureMatch, .raf)
        XCTAssertEqual(firstFoundFile?.fileExtension, "raf")
    }

    func testDeepScanDetectsMOVUsingAtomPatternWithoutFtyp() async throws {
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x20, 0x6D, 0x6F, 0x6F, 0x76, // moov
        ]
        bytes.append(contentsOf: Array(repeating: 0x00, count: 24))
        bytes.append(contentsOf: [
            0x00, 0x00, 0x00, 0x20, 0x6D, 0x64, 0x61, 0x74, // mdat
        ])
        bytes.append(contentsOf: Array(repeating: 0x00, count: 24))
        bytes.append(contentsOf: Array(repeating: 0x00, count: 4096 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let stream = deepScanService.scan(
            device: makeDevice(totalCapacity: Int64(bytes.count)),
            existingOffsets: [],
            startOffset: 0,
            cameraProfile: .generic
        )

        var firstFoundFile: RecoverableFile?
        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertEqual(firstFoundFile?.signatureMatch, .mov)
    }

    func testDeepScanFiltersLowEntropyJPEGFalsePositive() async throws {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF]
        bytes.append(contentsOf: Array(repeating: 0x00, count: 512))
        bytes.append(contentsOf: [0xFF, 0xD9])
        bytes.append(contentsOf: Array(repeating: 0x00, count: 4096 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(bytes.count), availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)
        var foundFiles: [RecoverableFile] = []
        for try await event in stream {
            if case let .fileFound(file) = event {
                foundFiles.append(file)
            }
        }

        XCTAssertTrue(foundFiles.isEmpty)
    }

    func testDeepScanEmitsHighEntropyJPEGWithConfidenceScore() async throws {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF]
        while bytes.count < 4094 {
            bytes.append(UInt8(bytes.count % 256))
        }
        bytes.append(contentsOf: [0xFF, 0xD9])

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let deepScanService = DeepScanService { _ in fakeReader }
        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(bytes.count), availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)
        var firstFoundFile: RecoverableFile?

        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertNotNil(firstFoundFile)
        XCTAssertNotNil(firstFoundFile?.confidenceScore)
        XCTAssertNotEqual(firstFoundFile?.recoveryConfidence, .low)
    }

    func testFileFooterDetectorFindsJPEGFooter() async throws {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF]
        bytes.append(contentsOf: Array(repeating: 0x11, count: 100))
        bytes.append(contentsOf: [0xFF, 0xD9])
        bytes.append(contentsOf: Array(repeating: 0x00, count: 512 - bytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(bytes))
        let detector = FileFooterDetector()

        let estimated = try await detector.estimateSize(
            signature: .jpeg,
            startOffset: 0,
            reader: fakeReader,
            maxScanBytes: 512
        )

        XCTAssertEqual(estimated, 105)
    }

    func testDeepScanEstimatesPNGSizeFromFooter() async throws {
        var pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        pngBytes.append(contentsOf: Array(repeating: 0x10, count: 40))
        pngBytes.append(contentsOf: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        pngBytes.append(contentsOf: Array(repeating: 0x00, count: 1024 - pngBytes.count))

        let fakeReader = FakePrivilegedDiskReader(buffer: Data(pngBytes))
        let deepScanService = DeepScanService { _ in fakeReader }

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .other, isExternal: true, isDiskImage: false,
            partitionOffset: nil, partitionSize: nil, totalCapacity: 1024, availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)
        var firstFoundFile: RecoverableFile?

        for try await event in stream {
            if case let .fileFound(file) = event {
                firstFoundFile = file
                break
            }
        }

        XCTAssertEqual(firstFoundFile?.signatureMatch, .png)
        XCTAssertEqual(firstFoundFile?.sizeInBytes, 56)
        XCTAssertEqual(firstFoundFile?.isLikelyContiguous, true)
    }

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

    private func makeDevice(totalCapacity: Int64 = 1024) -> StorageDevice {
        StorageDevice(
            id: "test",
            name: "test",
            volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test",
            filesystemType: .other,
            isExternal: true,
            isDiskImage: false,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: totalCapacity,
            availableCapacity: 0
        )
    }
}
