import XCTest
@testable import Vivacity

final class FileScanViewModelTests: XCTestCase {
    @MainActor
    func testFastScanCompletesAndTransitions() async {
        let fast = FakeFastScanService(events: [
            .progress(0.1),
            .fileFound(.fixture(id: 1, source: .fastScan)),
            .progress(0.6),
            .completed,
        ])
        let deep = FakeDeepScanService(events: [])
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(sut.scanPhase, .fastComplete)
        XCTAssertEqual(sut.foundFiles.count, 1)
        XCTAssertEqual(sut.progress, 1.0)
    }

    @MainActor
    func testDeepScanDedupesExistingOffsets() async {
        let fast = FakeFastScanService(events: [
            .fileFound(.fixture(id: 1, offset: 1024, source: .fastScan)),
            .completed,
        ])
        let deep = FakeDeepScanService(events: [
            .fileFound(.fixture(id: 2, offset: 1024, source: .deepScan)), // should be skipped
            .fileFound(.fixture(id: 3, offset: 2048, source: .deepScan)),
            .completed,
        ])
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        sut.startDeepScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 2) // one fast + one deep
    }

    @MainActor
    func testFiltersApplyToFoundFiles() async {
        let fast = FakeFastScanService(events: [
            .fileFound(.fixture(id: 1, name: "IMG_0001", type: .image, size: 2_000_000, source: .fastScan)),
            .fileFound(.fixture(id: 2, name: "Video_01", type: .video, size: 120_000_000, source: .fastScan)),
            .fileFound(.fixture(id: 3, name: "IMG_0002", type: .image, size: 8_000_000, source: .fastScan)),
            .completed,
        ])
        let deep = FakeDeepScanService(events: [])
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        sut.fileTypeFilter = .images
        sut.fileSizeFilter = .between5And100MB
        sut.fileNameQuery = "img"

        XCTAssertEqual(sut.filteredFiles.count, 1)
        XCTAssertEqual(sut.filteredFiles.first?.fileName, "IMG_0002")
        XCTAssertTrue(sut.isFiltering)
    }
}

// MARK: - Fakes

struct FakeFastScanService: FastScanServicing {
    let events: [ScanEvent]
    func scan(device: StorageDevice) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

struct FakeDeepScanService: DeepScanServicing {
    let events: [ScanEvent]
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in events where !shouldSkip(event: event, existingOffsets: existingOffsets) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func shouldSkip(event: ScanEvent, existingOffsets: Set<UInt64>) -> Bool {
        if case let .fileFound(file) = event {
            return existingOffsets.contains(file.offsetOnDisk)
        }
        return false
    }
}

// MARK: - Fixtures

extension RecoverableFile {
    fileprivate static func fixture(
        id: Int,
        name: String = "file",
        type: FileCategory = .image,
        size: Int64 = 1024,
        offset: UInt64 = 0,
        source: ScanSource
    ) -> RecoverableFile {
        RecoverableFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", id))") ?? UUID(),
            fileName: name,
            fileExtension: type == .image ? "jpg" : "mp4",
            fileType: type,
            sizeInBytes: size,
            offsetOnDisk: offset,
            signatureMatch: .jpeg,
            source: source
        )
    }
}

extension StorageDevice {
    fileprivate static func fakeDevice() -> StorageDevice {
        StorageDevice(
            id: "fake",
            name: "FakeDisk",
            volumePath: URL(fileURLWithPath: "/Volumes/Fake"),
            volumeUUID: "FAKE-UUID",
            filesystemType: .fat32,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 10000,
            availableCapacity: 5000
        )
    }
}
