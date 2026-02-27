import Foundation

/// Simple dependency container to allow tests to inject fake services/view models.
@MainActor
enum AppEnvironment {
    static var makeDeviceSelectionViewModel: @MainActor () -> DeviceSelectionViewModel = {
        DeviceSelectionViewModel()
    }

    static var makeFileScanViewModel: @MainActor () -> FileScanViewModel = {
        FileScanViewModel()
    }

    /// Call at app startup to configure fakes when running UI tests.
    static func configureForTestingIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["VIVACITY_USE_FAKE_SERVICES"] == "1" else { return }

        makeDeviceSelectionViewModel = {
            DeviceSelectionViewModel(deviceService: FakeDeviceService())
        }
        makeFileScanViewModel = {
            FileScanViewModel(
                fastScanService: FakeFastScanService(events: [
                    .progress(0.2),
                    .fileFound(.fixture(id: 1, offset: 4096, source: .fastScan)),
                    .completed,
                ]),
                deepScanService: FakeDeepScanService(events: [
                    .progress(0.5),
                    .fileFound(.fixture(id: 2, offset: 8192, source: .deepScan)),
                    .completed,
                ])
            )
        }
    }
}

#if DEBUG

// MARK: - App fakes (compiled in Debug for UI tests)

struct FakeDeviceService: DeviceServicing {
    func discoverDevices() async throws -> [StorageDevice] {
        [
            .init(
                id: "fake-device",
                name: "FakeDisk",
                volumePath: URL(fileURLWithPath: "/Volumes/Fake"),
                volumeUUID: "FAKE-UUID",
                filesystemType: .fat32,
                isExternal: true,
                partitionOffset: nil,
                partitionSize: nil,
                totalCapacity: 10_000_000,
                availableCapacity: 5_000_000
            ),
        ]
    }

    func volumeChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

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
        startOffset: UInt64
    ) -> AsyncThrowingStream<ScanEvent, Error> {
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

extension RecoverableFile {
    fileprivate static func fixture(id: Int, offset: UInt64, source: ScanSource) -> RecoverableFile {
        RecoverableFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", id))") ?? UUID(),
            fileName: "file\(id)",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 2048,
            offsetOnDisk: offset,
            signatureMatch: .jpeg,
            source: source
        )
    }
}
#endif
