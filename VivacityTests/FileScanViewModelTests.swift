import XCTest
@testable import Vivacity

final class FileScanViewModelTests: XCTestCase {
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
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.scanPhase, .fastComplete)
        XCTAssertEqual(sut.foundFiles.count, 1)
        XCTAssertEqual(sut.progress, 0.6)
    }

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
        try? await Task.sleep(nanoseconds: 200_000_000)
        sut.startDeepScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 2) // one fast + one deep
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
    func scan(device: StorageDevice, existingOffsets: Set<UInt64>) -> AsyncThrowingStream<ScanEvent, Error> {
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

private extension RecoverableFile {
    static func fixture(id: Int, offset: UInt64 = 0, source: ScanSource) -> RecoverableFile {
        RecoverableFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", id))") ?? UUID(),
            fileName: "file\(id)",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 1024,
            offsetOnDisk: offset,
            signatureMatch: .jpeg,
            source: source
        )
    }
}

private extension StorageDevice {
    static func fakeDevice() -> StorageDevice {
        StorageDevice(
            id: "fake",
            name: "FakeDisk",
            volumePath: URL(fileURLWithPath: "/Volumes/Fake"),
            volumeUUID: "FAKE-UUID",
            filesystemType: .fat32,
            isExternal: true,
            totalCapacity: 10_000,
            availableCapacity: 5_000
        )
    }
}
