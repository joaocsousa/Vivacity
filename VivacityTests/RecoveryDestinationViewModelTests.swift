import XCTest
@testable import Vivacity

final class RecoveryDestinationViewModelTests: XCTestCase {
    @MainActor
    func testSelectDestinationSetsDestinationAndAvailableSpace() {
        let destination = URL(fileURLWithPath: "/Volumes/Recovery/Output")
        let sut = RecoveryDestinationViewModel(
            scannedDevice: .fixture(),
            selectedFiles: [.fixture(size: 50)],
            directoryPicker: { destination },
            volumeInfoLookup: { url in
                if url.path.hasPrefix("/Volumes/Source") {
                    return RecoveryDestinationViewModel.VolumeInfo(
                        volumeRootURL: URL(fileURLWithPath: "/Volumes/Source"),
                        volumeUUID: "SOURCE-UUID",
                        availableCapacity: 8192
                    )
                }
                return RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: URL(fileURLWithPath: "/Volumes/Recovery"),
                    volumeUUID: "RECOVERY-UUID",
                    availableCapacity: url == destination ? 4096 : 8192
                )
            }
        )

        sut.selectDestination()

        XCTAssertEqual(sut.destinationURL, destination)
        XCTAssertEqual(sut.availableSpace, 4096)
        XCTAssertFalse(sut.isDestinationOnScannedDevice)
    }

    @MainActor
    func testUpdateAvailableSpaceRejectsSameDeviceByUUID() {
        let destination = URL(fileURLWithPath: "/Volumes/External/Output")
        let sut = RecoveryDestinationViewModel(
            scannedDevice: .fixture(volumePath: URL(fileURLWithPath: "/Volumes/Source"), volumeUUID: "SAME-UUID"),
            selectedFiles: [.fixture(size: 10)],
            directoryPicker: { destination },
            volumeInfoLookup: { url in
                if url.path.hasPrefix("/Volumes/Source") {
                    return RecoveryDestinationViewModel.VolumeInfo(
                        volumeRootURL: URL(fileURLWithPath: "/Volumes/Source"),
                        volumeUUID: "SAME-UUID",
                        availableCapacity: 1024
                    )
                }
                return RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: URL(fileURLWithPath: "/Volumes/External"),
                    volumeUUID: "SAME-UUID",
                    availableCapacity: 1024
                )
            }
        )

        sut.selectDestination()

        XCTAssertTrue(sut.isDestinationOnScannedDevice)
        XCTAssertEqual(
            sut.errorMessage,
            RecoveryDestinationError.destinationOnScannedDevice.localizedDescription
        )
    }

    @MainActor
    func testUpdateAvailableSpaceRejectsSameDeviceByRootPathFallback() {
        let destination = URL(fileURLWithPath: "/Volumes/Source/Recovery")
        let sut = RecoveryDestinationViewModel(
            scannedDevice: .fixture(volumePath: URL(fileURLWithPath: "/Volumes/Source"), volumeUUID: ""),
            selectedFiles: [.fixture(size: 10)],
            directoryPicker: { destination },
            volumeInfoLookup: { url in
                RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: url.path.hasPrefix("/Volumes/Source")
                        ? URL(fileURLWithPath: "/Volumes/Source")
                        : URL(fileURLWithPath: "/Volumes/Other"),
                    volumeUUID: nil,
                    availableCapacity: 8192
                )
            }
        )

        sut.selectDestination()

        XCTAssertTrue(sut.isDestinationOnScannedDevice)
    }

    @MainActor
    func testStartRecoveryRequiresDestination() async {
        let service = RecordingRecoveryService()
        let sut = RecoveryDestinationViewModel(
            scannedDevice: .fixture(),
            selectedFiles: [.fixture(size: 10)],
            recoveryService: service,
            directoryPicker: { nil },
            volumeInfoLookup: { _ in
                RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: URL(fileURLWithPath: "/Volumes/Other"),
                    volumeUUID: "OTHER-UUID",
                    availableCapacity: 8192
                )
            }
        )

        await sut.startRecovery()

        XCTAssertEqual(sut.errorMessage, RecoveryDestinationError.destinationRequired.localizedDescription)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 0)
    }

    @MainActor
    func testStartRecoveryFailsWhenInsufficientSpace() async {
        let destination = URL(fileURLWithPath: "/Volumes/Recovery/Output")
        let service = RecordingRecoveryService()
        let sut = RecoveryDestinationViewModel(
            scannedDevice: .fixture(),
            selectedFiles: [.fixture(size: 10000)],
            recoveryService: service,
            directoryPicker: { destination },
            volumeInfoLookup: { url in
                RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: url.path.hasPrefix("/Volumes/Source")
                        ? URL(fileURLWithPath: "/Volumes/Source")
                        : URL(fileURLWithPath: "/Volumes/Recovery"),
                    volumeUUID: url.path.hasPrefix("/Volumes/Source") ? "SOURCE-UUID" : "RECOVERY-UUID",
                    availableCapacity: 512
                )
            }
        )

        sut.selectDestination()
        await sut.startRecovery()

        XCTAssertFalse(sut.hasEnoughSpace)
        XCTAssertNotNil(sut.errorMessage)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 0)
    }

    @MainActor
    func testStartRecoveryCallsServiceWhenValidDestination() async {
        let destination = URL(fileURLWithPath: "/Volumes/Recovery/Output")
        let file = RecoverableFile.fixture(size: 500)
        let device = StorageDevice.fixture(
            volumePath: URL(fileURLWithPath: "/Volumes/Source"),
            volumeUUID: "SOURCE-UUID"
        )
        let service = RecordingRecoveryService()
        let sut = RecoveryDestinationViewModel(
            scannedDevice: device,
            selectedFiles: [file],
            recoveryService: service,
            directoryPicker: { destination },
            volumeInfoLookup: { url in
                if url.path.hasPrefix("/Volumes/Source") {
                    return RecoveryDestinationViewModel.VolumeInfo(
                        volumeRootURL: URL(fileURLWithPath: "/Volumes/Source"),
                        volumeUUID: "SOURCE-UUID",
                        availableCapacity: 8192
                    )
                }

                return RecoveryDestinationViewModel.VolumeInfo(
                    volumeRootURL: URL(fileURLWithPath: "/Volumes/Recovery"),
                    volumeUUID: "RECOVERY-UUID",
                    availableCapacity: 8192
                )
            }
        )

        sut.selectDestination()
        await sut.startRecovery()

        XCTAssertNil(sut.errorMessage)
        XCTAssertFalse(sut.isRecovering)

        let calls = await service.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.files, [file])
        XCTAssertEqual(calls.first?.destinationURL, destination)
        XCTAssertEqual(calls.first?.sourceDevice, device)
    }
}

private actor RecordingRecoveryService: FileRecoveryServicing {
    struct Call: Sendable {
        let files: [RecoverableFile]
        let sourceDevice: StorageDevice
        let destinationURL: URL
    }

    private(set) var calls: [Call] = []

    func recover(files: [RecoverableFile], from sourceDevice: StorageDevice, to destinationURL: URL) async throws {
        calls.append(Call(files: files, sourceDevice: sourceDevice, destinationURL: destinationURL))
    }
}

extension RecoverableFile {
    fileprivate static func fixture(size: Int64 = 1024) -> RecoverableFile {
        RecoverableFile(
            id: UUID(),
            fileName: "IMG_0001",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: size,
            offsetOnDisk: 0,
            signatureMatch: .jpeg,
            source: .fastScan,
            isLikelyContiguous: true
        )
    }
}

extension StorageDevice {
    fileprivate static func fixture(
        volumePath: URL = URL(fileURLWithPath: "/Volumes/Source"),
        volumeUUID: String = "SOURCE-UUID"
    ) -> StorageDevice {
        StorageDevice(
            id: "disk-test",
            name: "Test Disk",
            volumePath: volumePath,
            volumeUUID: volumeUUID,
            filesystemType: .exfat,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 10000,
            availableCapacity: 5000
        )
    }
}
