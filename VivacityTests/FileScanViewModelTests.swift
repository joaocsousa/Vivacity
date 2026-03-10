import AppKit
import SwiftUI
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

        XCTAssertEqual(sut.scanPhase, .complete)
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

    @MainActor
    func testDefaultSelectionIncludesOnlyMediumAndHighConfidence() async {
        let fast = FakeFastScanService(events: [
            .fileFound(.fixture(id: 1, source: .fastScan)),
            .completed,
        ])
        let deep = FakeDeepScanService(events: [
            .fileFound(.fixture(id: 2, source: .deepScan, confidenceScore: 0.81)),
            .fileFound(.fixture(id: 3, source: .deepScan, confidenceScore: 0.20)),
            .completed,
        ])
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 50_000_000)
        sut.startDeepScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 50_000_000)

        let selectedNames = Set(sut.foundFiles.filter { sut.selectedFileIDs.contains($0.id) }.map(\.fileName))
        XCTAssertTrue(selectedNames.contains("file_01"))
        XCTAssertTrue(selectedNames.contains("file_02"))
        XCTAssertFalse(selectedNames.contains("file_03"))
    }

    func testRecoveryConfidenceClassification() {
        let fast = RecoverableFile.fixture(id: 1, source: .fastScan, contiguous: true)
        XCTAssertEqual(fast.recoveryConfidence, .high)
        XCTAssertEqual(fast.corruptionLikelihood, .low)

        let deepContiguous = RecoverableFile.fixture(
            id: 2,
            type: .video,
            size: 50_000_000,
            source: .deepScan,
            contiguous: true
        )
        XCTAssertEqual(deepContiguous.recoveryConfidence, .medium)
        XCTAssertEqual(deepContiguous.corruptionLikelihood, .medium)

        let deepLikelyFragmented = RecoverableFile.fixture(
            id: 3,
            source: .deepScan,
            contiguous: false
        )
        XCTAssertEqual(deepLikelyFragmented.recoveryConfidence, .low)
        XCTAssertEqual(deepLikelyFragmented.corruptionLikelihood, .high)

        let deepUnknownWithNoSize = RecoverableFile.fixture(
            id: 4,
            size: 0,
            source: .deepScan,
            contiguous: nil
        )
        XCTAssertEqual(deepUnknownWithNoSize.recoveryConfidence, .low)
        XCTAssertEqual(deepUnknownWithNoSize.corruptionLikelihood, .high)
    }

    func testConfidenceBadgeCopyIsExplicit() {
        XCTAssertEqual(RecoveryConfidence.high.badgeText, "Recovery High")
        XCTAssertEqual(CorruptionLikelihood.high.badgeText, "Corruption High")
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

final class FakeHelperManager: PrivilegedHelperManaging {
    var currentStatusValue: PrivilegedHelperStatus
    var statusAfterInstall: PrivilegedHelperStatus?
    var statusAfterUninstall: PrivilegedHelperStatus?
    var installError: Error?
    var uninstallError: Error?
    private(set) var installCallCount = 0
    private(set) var uninstallCallCount = 0

    init(
        currentStatusValue: PrivilegedHelperStatus,
        statusAfterInstall: PrivilegedHelperStatus? = nil,
        statusAfterUninstall: PrivilegedHelperStatus? = nil,
        installError: Error? = nil,
        uninstallError: Error? = nil
    ) {
        self.currentStatusValue = currentStatusValue
        self.statusAfterInstall = statusAfterInstall
        self.statusAfterUninstall = statusAfterUninstall
        self.installError = installError
        self.uninstallError = uninstallError
    }

    func currentStatus() -> PrivilegedHelperStatus {
        currentStatusValue
    }

    func installIfNeeded() throws {
        installCallCount += 1
        if let installError {
            throw installError
        }
        if let statusAfterInstall {
            currentStatusValue = statusAfterInstall
        }
    }

    func uninstallIfInstalled() throws {
        uninstallCallCount += 1
        if let uninstallError {
            throw uninstallError
        }
        if let statusAfterUninstall {
            currentStatusValue = statusAfterUninstall
        }
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
        source: ScanSource,
        contiguous: Bool? = nil,
        confidenceScore: Double? = nil
    ) -> RecoverableFile {
        RecoverableFile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", id))") ?? UUID(),
            fileName: name == "file" ? "file_\(String(format: "%02d", id))" : name,
            fileExtension: type == .image ? "jpg" : "mp4",
            fileType: type,
            sizeInBytes: size,
            offsetOnDisk: offset,
            signatureMatch: .jpeg,
            source: source,
            isLikelyContiguous: contiguous,
            confidenceScore: confidenceScore
        )
    }
}

extension StorageDevice {
    fileprivate static func fakeDevice(
        name: String = "FakeDisk",
        volumePath: URL = URL(fileURLWithPath: "/Volumes/Fake"),
        filesystemType: FilesystemType = .fat32,
        isExternal: Bool = true,
        isDiskImage: Bool = false
    ) -> StorageDevice {
        StorageDevice(
            id: volumePath.absoluteString,
            name: name,
            volumePath: volumePath,
            volumeUUID: "FAKE-UUID",
            filesystemType: filesystemType,
            isExternal: isExternal,
            isDiskImage: isDiskImage,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 10000,
            availableCapacity: 5000
        )
    }
}

private func makeVolumeInfo(
    filesystemType: FilesystemType,
    devicePath: String,
    mountPoint: URL,
    isInternal: Bool,
    isBootable: Bool,
    isFileVaultEnabled: Bool
) -> VolumeInfo {
    VolumeInfo(
        filesystemType: filesystemType,
        devicePath: devicePath,
        mountPoint: mountPoint,
        blockSize: 4096,
        isInternal: isInternal,
        isBootable: isBootable,
        isFileVaultEnabled: isFileVaultEnabled
    )
}

@MainActor
final class FileScanViewModelAdditionalTests: XCTestCase {
    func testDiskImageFullScanCompletes() async {
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: [])
        )
        let image = StorageDevice.fakeDevice(
            name: "Disk Image",
            volumePath: URL(fileURLWithPath: "/tmp/test.img"),
            filesystemType: .apfs,
            isExternal: true,
            isDiskImage: true
        )

        sut.startFastScan(device: image)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.progress, 1.0)
    }

    func testSaveSessionFailureSetsErrorMessage() async {
        let sessionManager = TestSessionManager(shouldThrowOnSave: true)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.completed]),
            deepScanService: FakeDeepScanService(events: []),
            sessionManager: sessionManager
        )

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sut.saveSession(device: .fakeDevice())

        XCTAssertNotNil(sut.errorMessage)
    }

    func testResumeSessionStartsDeepScanFromSavedOffsetAndCompletes() async {
        let recorder = TestDeepScanRecorder()
        let deep = RecordingDeepScanService(
            events: [.progress(0.8), .fileFound(.fixture(id: 9, offset: 9000, source: .deepScan)), .completed],
            recorder: recorder
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: deep
        )
        let session = ScanSession(
            id: UUID(),
            dateSaved: Date(),
            deviceID: "fake",
            deviceTotalCapacity: 10000,
            lastScannedOffset: 4000,
            discoveredFiles: [
                .fixture(id: 1, offset: 1024, source: .deepScan),
                .fixture(id: 2, offset: 0, source: .fastScan),
            ]
        )

        sut.resumeSession(session, device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 3)
        let invocation = await recorder.snapshot()
        XCTAssertEqual(invocation.startOffset, 4000)
        XCTAssertEqual(invocation.existingOffsets, Set([1024]))
    }

    func testSelectionHelpersApplyToFilteredFiles() async {
        let fast = FakeFastScanService(events: [
            .fileFound(.fixture(id: 1, name: "IMG_A", type: .image, source: .fastScan)),
            .fileFound(.fixture(id: 2, name: "VID_B", type: .video, source: .fastScan)),
            .fileFound(.fixture(id: 3, name: "IMG_C", type: .image, source: .fastScan)),
            .completed,
        ])
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: FakeDeepScanService(events: []))

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.fileTypeFilter = .images
        sut.selectAllFiltered()

        XCTAssertEqual(sut.selectedCount, 3)
        XCTAssertEqual(sut.selectedFilteredCount, 2)
        XCTAssertNotNil(sut.selectedCountLabel)
        XCTAssertTrue(sut.canRecover)

        sut.deselectFiltered()
        XCTAssertEqual(sut.selectedCount, 1)
        XCTAssertTrue(sut.canRecover)
    }

    func testStopScanningTransitionsToComplete() async {
        let fast = HangingFastScanService()
        let deep = HangingDeepScanService()
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sut.scanPhase, .scanning)
        sut.stopScanning()
        XCTAssertEqual(sut.scanPhase, .complete)

        let sut2 = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.completed]),
            deepScanService: deep
        )
        sut2.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 20_000_000)
        sut2.startDeepScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sut2.scanPhase, .scanning)
        sut2.stopScanning()
        XCTAssertEqual(sut2.scanPhase, .complete)
    }

    func testProtectedBootAPFSInitialAccessRecommendsImage() {
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        sut.refreshHelperStatus()
        let state = sut.prepareInitialScanAccess(for: protectedDevice)

        XCTAssertEqual(state, .imageRecommended)
        XCTAssertEqual(sut.scanAccessState, .imageRecommended)
        XCTAssertNotNil(sut.scanAccessMessage)
    }

    func testExternalDeviceRequiresHelperWhenMissing() {
        let externalDevice = StorageDevice.fakeDevice()
        let volumeInfo = makeVolumeInfo(
            filesystemType: .exfat,
            devicePath: "/dev/disk4s1",
            mountPoint: externalDevice.volumePath,
            isInternal: false,
            isBootable: false,
            isFileVaultEnabled: false
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .notInstalled),
            volumeInfoProvider: { _ in volumeInfo }
        )

        sut.refreshHelperStatus()
        let state = sut.prepareInitialScanAccess(for: externalDevice)

        XCTAssertEqual(state, .helperInstallRequired)
        XCTAssertEqual(sut.scanAccessState, .helperInstallRequired)
    }

    func testDiskImageInitialAccessAllowsFullScanWithoutHelperPrompt() {
        let image = StorageDevice.fakeDevice(
            name: "Recovered Image",
            volumePath: URL(fileURLWithPath: "/tmp/recovered.img"),
            filesystemType: .apfs,
            isExternal: true,
            isDiskImage: true
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .notInstalled)
        )

        sut.refreshHelperStatus()
        let state = sut.prepareInitialScanAccess(for: image)

        XCTAssertEqual(state, .fullScan)
        XCTAssertEqual(sut.scanAccessState, .fullScan)
    }

    @MainActor
    func testActivateDiskImageScanStartsFullScanWithoutHelperPrompt() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-scan-image-\(UUID().uuidString).img")
        var bytes = Data(repeating: 0x00, count: 8192)
        bytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [
                .fileFound(.fixture(id: 77, source: .fastScan)),
                .completed,
            ]),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .notInstalled)
        )
        sut.scanAccessState = .imageRequired
        sut.scanAccessMessage = "Load an image first."
        sut.permissionDenied = true

        let imageDevice = sut.activateDiskImageScan(from: tempURL)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(imageDevice.isDiskImage)
        XCTAssertEqual(imageDevice.id, tempURL.absoluteString)
        XCTAssertEqual(sut.helperStatus, .notInstalled)
        XCTAssertEqual(sut.scanAccessState, .fullScan)
        XCTAssertNil(sut.scanAccessMessage)
        XCTAssertFalse(sut.permissionDenied)
        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 1)
    }

    func testProtectedBootAPFSRuntimeEPERMRoutesToImageRequired() async {
        let fast = FakeFastScanService(events: [.completed])
        let deep = ThrowingDeepScanService(
            error: DeepScanError.cannotReadDevice(
                path: "/dev/disk3s5",
                offset: 0,
                reason: "Operation not permitted"
            )
        )
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let sut = FileScanViewModel(
            fastScanService: fast,
            deepScanService: deep,
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        sut.startScan(device: protectedDevice)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(sut.permissionDenied)
        XCTAssertEqual(sut.scanPhase, .idle)
        XCTAssertEqual(sut.scanAccessState, .imageRequired)
        XCTAssertNil(sut.errorMessage)
    }

    func testNonPermissionDeepFailureShowsErrorInsteadOfPermissionScreen() async {
        let fast = FakeFastScanService(events: [.completed])
        let deep = ThrowingDeepScanService(
            error: DeepScanError.cannotReadDevice(
                path: "/dev/disk3s5",
                offset: 0,
                reason: "No data could be read. seekable=true. diagnostic=Privileged helper returned EOF"
            )
        )
        let sut = FileScanViewModel(fastScanService: fast, deepScanService: deep)

        sut.startScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sut.permissionDenied)
        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(
            sut.errorMessage,
            "Deep scan error: Cannot read /dev/disk3s5 at offset 0: No data could be read. " +
                "seekable=true. diagnostic=Privileged helper returned EOF. " +
                "Check Full Disk Access and retry deep scan."
        )
    }

    func testCreateDiskImageFailureRoutesProtectedBootAPFSToOfflineImage() async {
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-protected-\(UUID().uuidString).dd")
        defer { try? FileManager.default.removeItem(at: destination) }

        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            diskImageService: TestDiskImageService(progressValues: [], shouldThrow: true),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        let image = await sut.createDiskImage(from: protectedDevice, to: destination)

        XCTAssertNil(image)
        XCTAssertEqual(sut.scanAccessState, .imageRequired)
        XCTAssertNotNil(sut.scanAccessMessage)
    }

    @MainActor
    func testCreateDiskImageSuccessActivatesImageBackedScanFlow() async {
        let sourceDevice = StorageDevice.fakeDevice(
            name: "External Recovery",
            volumePath: URL(fileURLWithPath: "/Volumes/External"),
            filesystemType: .exfat,
            isExternal: true
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-created-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: destination) }

        var imageBytes = Data(repeating: 0x00, count: 8192)
        imageBytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))

        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [
                .fileFound(.fixture(id: 88, source: .fastScan)),
                .completed,
            ]),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .notInstalled),
            diskImageService: TestDiskImageService(
                progressValues: [0.3, 1.0],
                outputData: imageBytes
            )
        )
        sut.scanAccessState = .imageRecommended
        sut.scanAccessMessage = "Create or load an image."
        sut.permissionDenied = true

        let imageDevice = await sut.createDiskImageAndActivateScan(from: sourceDevice, to: destination)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(imageDevice?.id, destination.absoluteString)
        XCTAssertTrue(imageDevice?.isDiskImage == true)
        XCTAssertFalse(sut.isCreatingImage)
        XCTAssertEqual(sut.imageCreationProgress, 0.0)
        XCTAssertEqual(sut.helperStatus, .notInstalled)
        XCTAssertEqual(sut.scanAccessState, .fullScan)
        XCTAssertNil(sut.scanAccessMessage)
        XCTAssertFalse(sut.permissionDenied)
        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 1)
    }

    func testContinueWithLimitedScanCompletesExistingFastResultsAfterImageRequired() async {
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [
                .fileFound(.fixture(id: 31, source: .fastScan)),
                .completed,
            ]),
            deepScanService: ThrowingDeepScanService(
                error: DeepScanError.cannotReadDevice(
                    path: "/dev/disk3s5",
                    offset: 0,
                    reason: "Operation not permitted"
                )
            ),
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        sut.startScan(device: protectedDevice)
        try? await Task.sleep(nanoseconds: 50_000_000)
        sut.continueWithLimitedScan(device: protectedDevice)

        XCTAssertEqual(sut.scanAccessState, .limitedOnly)
        XCTAssertEqual(sut.scanPhase, .complete)
        XCTAssertEqual(sut.foundFiles.count, 1)
    }

    func testProtectedBootAPFSRecommendationDoesNotOfferRetryAction() {
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        sut.refreshHelperStatus()
        _ = sut.prepareInitialScanAccess(for: protectedDevice)

        XCTAssertFalse(sut.canRetryFullScan(for: protectedDevice))
        XCTAssertTrue(sut.canOfferInAppImageCreation(for: protectedDevice))
    }

    func testProtectedBootAPFSImageRequiredDisablesInAppImageCreationAndRetry() async {
        let protectedDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let protectedVolumeInfo = makeVolumeInfo(
            filesystemType: .apfs,
            devicePath: "/dev/disk3s5",
            mountPoint: URL(fileURLWithPath: "/"),
            isInternal: true,
            isBootable: true,
            isFileVaultEnabled: true
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.completed]),
            deepScanService: ThrowingDeepScanService(
                error: DeepScanError.cannotReadDevice(
                    path: "/dev/disk3s5",
                    offset: 0,
                    reason: "Operation not permitted"
                )
            ),
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in protectedVolumeInfo }
        )

        sut.startScan(device: protectedDevice)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.scanAccessState, .imageRequired)
        XCTAssertFalse(sut.canOfferInAppImageCreation(for: protectedDevice))
        XCTAssertFalse(sut.canRetryFullScan(for: protectedDevice))
    }

    func testRetryAndImageCreationStayAvailableForNonProtectedImageRecommendation() async {
        let externalDevice = StorageDevice.fakeDevice(
            name: "External Recovery",
            volumePath: URL(fileURLWithPath: "/Volumes/External"),
            filesystemType: .exfat,
            isExternal: true
        )
        let volumeInfo = makeVolumeInfo(
            filesystemType: .exfat,
            devicePath: "/dev/disk4s1",
            mountPoint: externalDevice.volumePath,
            isInternal: false,
            isBootable: false,
            isFileVaultEnabled: false
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.completed]),
            deepScanService: ThrowingDeepScanService(
                error: DeepScanError.cannotReadDevice(
                    path: "/dev/disk4s1",
                    offset: 0,
                    reason: "Operation not permitted"
                )
            ),
            helperManager: FakeHelperManager(currentStatusValue: .installed),
            volumeInfoProvider: { _ in volumeInfo }
        )

        sut.startScan(device: externalDevice)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.scanAccessState, .imageRecommended)
        XCTAssertTrue(sut.canOfferInAppImageCreation(for: externalDevice))
        XCTAssertTrue(sut.canRetryFullScan(for: externalDevice))
    }

    func testRefreshHelperStatusSetsInstalled() {
        let helperManager = FakeHelperManager(currentStatusValue: .installed)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        sut.refreshHelperStatus()

        XCTAssertEqual(sut.helperStatus, .installed)
    }

    func testRefreshHelperStatusSetsNotInstalled() {
        let helperManager = FakeHelperManager(currentStatusValue: .notInstalled)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        sut.refreshHelperStatus()

        XCTAssertEqual(sut.helperStatus, .notInstalled)
    }

    func testInstallHelperForFullScanReturnsAlreadyInstalledWithoutReinstalling() {
        let helperManager = FakeHelperManager(currentStatusValue: .installed)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.installHelperForFullScan()

        XCTAssertEqual(result, .alreadyInstalled)
        XCTAssertEqual(helperManager.installCallCount, 0)
        XCTAssertEqual(sut.helperStatus, .installed)
        XCTAssertEqual(sut.helperInstallFeedbackState, .success)
    }

    func testInstallHelperForFullScanReturnsInstalledOnSuccessfulInstall() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .notInstalled,
            statusAfterInstall: .installed
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.installHelperForFullScan()

        XCTAssertEqual(result, .installed)
        XCTAssertEqual(helperManager.installCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .installed)
        XCTAssertEqual(sut.helperInstallFeedbackState, .success)
    }

    func testInstallHelperForFullScanReturnsFailureWhenInstallerThrows() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .notInstalled,
            installError: HelperManagerError.syntheticFailure
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.installHelperForFullScan()

        guard case let .failed(message) = result else {
            XCTFail("Expected failed helper install result")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(helperManager.installCallCount, 1)
        XCTAssertEqual(sut.helperInstallFeedbackState, .failed(message))
    }

    func testInstallHelperForFullScanReturnsFailureWhenStatusStaysOutdated() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .updateRequired,
            statusAfterInstall: .updateRequired
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.installHelperForFullScan()

        guard case let .failed(message) = result else {
            XCTFail("Expected failed helper install result")
            return
        }
        XCTAssertTrue(message.contains("update"))
        XCTAssertEqual(helperManager.installCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .updateRequired)
        XCTAssertEqual(sut.helperInstallFeedbackState, .failed(message))
    }

    func testUninstallHelperReturnsAlreadyNotInstalledWithoutCallingUninstall() {
        let helperManager = FakeHelperManager(currentStatusValue: .notInstalled)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.uninstallHelper()

        XCTAssertEqual(result, .alreadyNotInstalled)
        XCTAssertEqual(helperManager.uninstallCallCount, 0)
        XCTAssertEqual(sut.helperStatus, .notInstalled)
    }

    func testUninstallHelperReturnsUninstalledOnSuccessfulRemoval() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .installed,
            statusAfterUninstall: .notInstalled
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.uninstallHelper()

        XCTAssertEqual(result, .uninstalled)
        XCTAssertEqual(helperManager.uninstallCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .notInstalled)
        XCTAssertNil(sut.helperInstallFeedbackState)
    }

    func testUninstallHelperReturnsFailureWhenUninstallThrows() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .installed,
            uninstallError: HelperManagerError.syntheticFailure
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.uninstallHelper()

        guard case let .failed(message) = result else {
            XCTFail("Expected failed helper uninstall result")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(helperManager.uninstallCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .installed)
    }

    func testUninstallHelperReturnsFailureWhenStatusRemainsInstalled() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .installed,
            statusAfterUninstall: .installed
        )
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: []),
            helperManager: helperManager
        )

        let result = sut.uninstallHelper()

        guard case let .failed(message) = result else {
            XCTFail("Expected failed helper uninstall result")
            return
        }
        XCTAssertTrue(message.contains("still appears installed"))
        XCTAssertEqual(helperManager.uninstallCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .installed)
    }
}

private enum HelperManagerError: Error {
    case syntheticFailure
}

@MainActor
final class DeviceSelectionViewModelTests: XCTestCase {
    func testLoadDevicesKeepsNewestSessionAndClearsStaleSelection() async {
        let device = StorageDevice.fakeDevice()
        let stale = StorageDevice(
            id: "stale",
            name: "Old",
            volumePath: URL(fileURLWithPath: "/Volumes/Old"),
            volumeUUID: "OLD",
            filesystemType: .fat32,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 100,
            availableCapacity: 50
        )
        let old = ScanSession(
            id: UUID(),
            dateSaved: Date(timeIntervalSince1970: 10),
            deviceID: device.id,
            deviceTotalCapacity: 10000,
            lastScannedOffset: 10,
            discoveredFiles: []
        )
        let newer = ScanSession(
            id: UUID(),
            dateSaved: Date(timeIntervalSince1970: 20),
            deviceID: device.id,
            deviceTotalCapacity: 10000,
            lastScannedOffset: 20,
            discoveredFiles: []
        )

        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: [device]),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(loadSessions: [old, newer]),
            diskImageService: TestDiskImageService(progressValues: [])
        )
        sut.selectedDevice = stale

        await sut.loadDevices()

        XCTAssertEqual(sut.devices, [device])
        XCTAssertEqual(sut.selectedDevice, nil)
        XCTAssertEqual(sut.savedSessions[device.id]?.id, newer.id)
        XCTAssertNil(sut.errorMessage)
        XCTAssertFalse(sut.isLoading)
    }

    func testLoadDevicesFailureSetsError() async {
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: [], shouldThrow: true),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [])
        )

        await sut.loadDevices()

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertFalse(sut.isLoading)
    }

    func testRefreshHelperStatusSetsUpdateRequiredHeadlineAndAction() {
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: FakeHelperManager(currentStatusValue: .updateRequired)
        )

        sut.refreshHelperStatus()

        XCTAssertEqual(sut.helperStatus, .updateRequired)
        XCTAssertEqual(sut.helperStatusTitle, "Recovery Helper Reinstall Required")
        XCTAssertEqual(sut.helperPrimaryActionTitle, "Reinstall Helper")
    }

    func testSelectedPhysicalDeviceRequiresHelperInstallFromMainScreen() {
        let physicalDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: [physicalDevice]),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: FakeHelperManager(currentStatusValue: .notInstalled)
        )
        sut.selectedDevice = physicalDevice

        sut.refreshHelperStatus()

        XCTAssertTrue(sut.selectedDeviceRequiresHelper)
        XCTAssertEqual(sut.selectedDeviceHelperActionTitle, "Install Helper")
        XCTAssertEqual(
            sut.helperAttentionCallout?.title,
            "Install the Helper Before Scanning"
        )
    }

    func testSelectedPhysicalDeviceHighlightsVersionMismatchAndReinstallAction() {
        let physicalDevice = StorageDevice.fakeDevice(
            name: "Macintosh HD",
            volumePath: URL(fileURLWithPath: "/"),
            filesystemType: .apfs,
            isExternal: false
        )
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: [physicalDevice]),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: FakeHelperManager(currentStatusValue: .updateRequired)
        )
        sut.selectedDevice = physicalDevice

        sut.refreshHelperStatus()

        XCTAssertTrue(sut.selectedDeviceRequiresHelper)
        XCTAssertEqual(sut.selectedDeviceHelperActionTitle, "Reinstall Helper")
        XCTAssertEqual(
            sut.helperAttentionCallout?.title,
            "Version Mismatch Detected"
        )
    }

    func testSelectedDiskImageBypassesHelperRequirementOnMainScreen() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-main-screen-\(UUID().uuidString).img")
        var bytes = Data(repeating: 0x00, count: 4096)
        bytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: FakeHelperManager(currentStatusValue: .updateRequired)
        )
        sut.selectedDevice = sut.loadDiskImage(at: tempURL)

        sut.refreshHelperStatus()

        XCTAssertFalse(sut.selectedDeviceRequiresHelper)
        XCTAssertNil(sut.selectedDeviceHelperActionTitle)
    }

    func testInstallOrUpdateHelperSuccessProducesInstalledFeedback() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .notInstalled,
            statusAfterInstall: .installed
        )
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: helperManager
        )

        sut.installOrUpdateHelper()

        XCTAssertEqual(helperManager.installCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .installed)
        XCTAssertEqual(sut.helperFeedbackAlert?.title, "Helper Installed")
    }

    func testInstallOrUpdateHelperLeavesMismatchHighlightedWhenVersionStillOutdated() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .updateRequired,
            statusAfterInstall: .updateRequired
        )
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: helperManager
        )

        sut.installOrUpdateHelper()

        XCTAssertEqual(helperManager.installCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .updateRequired)
        XCTAssertEqual(sut.helperFeedbackAlert?.title, "Reinstall Still Required")
    }

    func testUninstallHelperSuccessProducesFeedback() {
        let helperManager = FakeHelperManager(
            currentStatusValue: .installed,
            statusAfterUninstall: .notInstalled
        )
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: []),
            helperManager: helperManager
        )

        sut.uninstallHelper()

        XCTAssertEqual(helperManager.uninstallCallCount, 1)
        XCTAssertEqual(sut.helperStatus, .notInstalled)
        XCTAssertEqual(sut.helperFeedbackAlert?.title, "Helper Uninstalled")
    }

    func testLoadDiskImageInsertsAndDeduplicates() throws {
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [])
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-image-\(UUID().uuidString).img")
        var bytes = Data(repeating: 0x00, count: 4096)
        bytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        sut.loadDiskImage(at: tempURL)
        sut.loadDiskImage(at: tempURL)

        XCTAssertEqual(sut.devices.count, 1)
        XCTAssertEqual(sut.selectedDevice?.id, tempURL.absoluteString)
        XCTAssertEqual(sut.devices.first?.totalCapacity, 4096)
        XCTAssertEqual(sut.devices.first?.filesystemType, .apfs)
    }

    func testLoadDiskImageAndQueueScanSetsPendingNavigation() throws {
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [])
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-load-scan-\(UUID().uuidString).img")
        var bytes = Data(repeating: 0x00, count: 4096)
        bytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let imageDevice = sut.loadDiskImageAndQueueScan(at: tempURL)

        XCTAssertEqual(imageDevice.id, tempURL.absoluteString)
        XCTAssertEqual(sut.selectedDevice?.id, tempURL.absoluteString)
        XCTAssertEqual(sut.pendingScanDevice?.id, tempURL.absoluteString)

        let pendingScanDevice = sut.consumePendingScanDevice()
        XCTAssertEqual(pendingScanDevice?.id, tempURL.absoluteString)
        XCTAssertNil(sut.pendingScanDevice)
    }

    func testCreateImageSuccessLoadsAndSelectsCreatedImage() async {
        let device = StorageDevice.fakeDevice()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).dd")
        defer { try? FileManager.default.removeItem(at: destination) }
        var bytes = Data(repeating: 0x00, count: 4096)
        bytes.replaceSubrange(32 ..< 36, with: Data("BSXN".utf8))

        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(
                progressValues: [0.25, 0.9, 1.0],
                outputData: bytes
            )
        )

        let createdImage = await sut.createImage(for: device, to: destination)

        XCTAssertFalse(sut.isCreatingImage)
        XCTAssertEqual(sut.imageCreationProgress, 0.0)
        XCTAssertNil(sut.errorMessage)
        XCTAssertEqual(sut.devices.count, 1)
        XCTAssertEqual(createdImage?.id, destination.absoluteString)
        XCTAssertEqual(sut.selectedDevice?.id, destination.absoluteString)
        XCTAssertTrue(sut.selectedDevice?.isDiskImage == true)
        XCTAssertEqual(sut.selectedDevice?.filesystemType, .apfs)
        XCTAssertEqual(sut.pendingScanDevice?.id, destination.absoluteString)

        let pendingScanDevice = sut.consumePendingScanDevice()
        XCTAssertEqual(pendingScanDevice?.id, destination.absoluteString)
        XCTAssertNil(sut.pendingScanDevice)
    }

    func testCreateImageFailureResetsStateAndLeavesImageUnloaded() async {
        let device = StorageDevice.fakeDevice()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).dd")
        defer { try? FileManager.default.removeItem(at: destination) }

        let failingSUT = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [], shouldThrow: true)
        )
        await failingSUT.createImage(for: device, to: destination)

        XCTAssertFalse(failingSUT.isCreatingImage)
        XCTAssertEqual(failingSUT.imageCreationProgress, 0.0)
        XCTAssertNotNil(failingSUT.errorMessage)
        XCTAssertTrue(failingSUT.devices.isEmpty)
        XCTAssertNil(failingSUT.selectedDevice)
        XCTAssertNil(failingSUT.pendingScanDevice)
    }
}

@MainActor
final class ViewRenderingCoverageTests: XCTestCase {
    func testRenderFileRowAndPreviewVariants() {
        let imageFile = RecoverableFile.fixture(id: 11, type: .image, source: .fastScan)
        let videoFile = RecoverableFile.fixture(id: 12, type: .video, source: .deepScan, contiguous: false)
        let mockPreview = MockLivePreviewService(previewURL: nil)
        render(FileRow(
            file: imageFile,
            isSelected: true,
            isPreviewSelected: true,
            onToggle: {},
            onSelectForPreview: {}
        ))
        render(FileRow(
            file: videoFile,
            isSelected: false,
            isPreviewSelected: false,
            onToggle: {},
            onSelectForPreview: {}
        ))

        render(FilePreviewView(file: nil, device: .fakeDevice()))
        render(FilePreviewView(file: imageFile, device: .fakeDevice()))
        render(FilePreviewView(
            file: videoFile,
            device: .fakeDevice(),
            previewService: mockPreview,
            diskReaderFactory: { _ in FakePrivilegedDiskReader() }
        ))
    }

    func testRenderFileScanViewAcrossStates() async {
        let originalFactory = AppEnvironment.makeFileScanViewModel
        defer { AppEnvironment.makeFileScanViewModel = originalFactory }

        let idle = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: [])
        )
        AppEnvironment.makeFileScanViewModel = { idle }
        render(FileScanView(device: .fakeDevice()))

        let fastComplete = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [
                .fileFound(.fixture(id: 1, source: .fastScan)),
                .completed,
            ]),
            deepScanService: FakeDeepScanService(events: [])
        )
        fastComplete.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 30_000_000)
        AppEnvironment.makeFileScanViewModel = { fastComplete }
        render(FileScanView(device: .fakeDevice()))

        let interrupted = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: [])
        )
        interrupted.scanAccessState = .imageRequired
        interrupted.scanAccessMessage = "Load an image first."
        AppEnvironment.makeFileScanViewModel = { interrupted }
        render(FileScanView(device: .fakeDevice()))
    }

    private func render(_ view: some View) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }
}

private actor TestDeepScanRecorder {
    var lastStartOffset: UInt64 = 0
    var lastExistingOffsets: Set<UInt64> = []

    func record(startOffset: UInt64, existingOffsets: Set<UInt64>) {
        lastStartOffset = startOffset
        lastExistingOffsets = existingOffsets
    }

    func snapshot() -> (startOffset: UInt64, existingOffsets: Set<UInt64>) {
        (lastStartOffset, lastExistingOffsets)
    }
}

private struct RecordingDeepScanService: DeepScanServicing {
    let events: [ScanEvent]
    let recorder: TestDeepScanRecorder

    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(startOffset: startOffset, existingOffsets: existingOffsets)
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

private struct HangingFastScanService: FastScanServicing {
    func scan(device: StorageDevice) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(0.1))
        }
    }
}

private struct HangingDeepScanService: DeepScanServicing {
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(0.1))
        }
    }
}

private struct ThrowingDeepScanService: DeepScanServicing {
    let error: Error

    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

private actor TestSessionManager: SessionManaging {
    private let shouldThrowOnSave: Bool
    private let shouldThrowOnDelete: Bool
    private let loadSessions: [ScanSession]
    private(set) var saved: [ScanSession] = []

    init(
        shouldThrowOnSave: Bool = false,
        shouldThrowOnDelete: Bool = false,
        loadSessions: [ScanSession] = []
    ) {
        self.shouldThrowOnSave = shouldThrowOnSave
        self.shouldThrowOnDelete = shouldThrowOnDelete
        self.loadSessions = loadSessions
    }

    func save(_ session: ScanSession) async throws {
        if shouldThrowOnSave { throw TestFailure.expected }
        saved.append(session)
    }

    func loadAll() async throws -> [ScanSession] {
        loadSessions
    }

    func loadSession(id: UUID) async throws -> ScanSession? {
        loadSessions.first(where: { $0.id == id })
    }

    func deleteSession(id: UUID) async throws {
        if shouldThrowOnDelete { throw TestFailure.expected }
        saved.removeAll { $0.id == id }
    }
}

private struct TestDeviceService: DeviceServicing {
    let devices: [StorageDevice]
    let shouldThrow: Bool

    init(devices: [StorageDevice], shouldThrow: Bool = false) {
        self.devices = devices
        self.shouldThrow = shouldThrow
    }

    func discoverDevices() async throws -> [StorageDevice] {
        if shouldThrow { throw TestFailure.expected }
        return devices
    }

    func volumeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private struct TestDiskImageService: DiskImageServicing {
    let progressValues: [Double]
    let shouldThrow: Bool
    let outputData: Data?

    init(progressValues: [Double], shouldThrow: Bool = false, outputData: Data? = nil) {
        self.progressValues = progressValues
        self.shouldThrow = shouldThrow
        self.outputData = outputData
    }

    func createImage(from device: StorageDevice, to destinationURL: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if shouldThrow {
                    continuation.finish(throwing: TestFailure.expected)
                    return
                }
                if let outputData {
                    try? outputData.write(to: destinationURL)
                }
                for progress in progressValues {
                    continuation.yield(progress)
                }
                continuation.finish()
            }
        }
    }
}

private actor MockLivePreviewService: LivePreviewServicing {
    let previewURL: URL?

    init(previewURL: URL?) {
        self.previewURL = previewURL
    }

    func generatePreviewURL(for file: RecoverableFile, reader: PrivilegedDiskReading) async throws -> URL? {
        previewURL
    }

    func clearCache() async {}
}

private enum TestFailure: Error {
    case expected
}

@MainActor
final class AdditionalCoverageTests: XCTestCase {
    func testRenderRecoveryAndPermissionViews() {
        let selected = RecoverableFile.fixture(id: 21, source: .fastScan)
        render(
            RecoveryDestinationView(
                scannedDevice: .fakeDevice(),
                selectedFiles: [selected]
            )
        )
        render(
            ScanAccessInterruptionView(
                state: .imageRecommended,
                message: "Create or load an image to continue.",
                onCreateImage: {},
                onLoadImage: {},
                onContinueLimited: {},
                onTryAgain: nil
            )
        )
    }

    func testConfigureAppEnvironmentWithFakeServices() async {
        let oldDeviceFactory = AppEnvironment.makeDeviceSelectionViewModel
        let oldScanFactory = AppEnvironment.makeFileScanViewModel
        let oldEnv = getenv("VIVACITY_USE_FAKE_SERVICES").map { String(cString: $0) }
        defer {
            AppEnvironment.makeDeviceSelectionViewModel = oldDeviceFactory
            AppEnvironment.makeFileScanViewModel = oldScanFactory
            if let oldEnv {
                setenv("VIVACITY_USE_FAKE_SERVICES", oldEnv, 1)
            } else {
                unsetenv("VIVACITY_USE_FAKE_SERVICES")
            }
        }

        setenv("VIVACITY_USE_FAKE_SERVICES", "1", 1)
        AppEnvironment.configureForTestingIfNeeded()

        let deviceVM = AppEnvironment.makeDeviceSelectionViewModel()
        await deviceVM.loadDevices()
        XCTAssertEqual(deviceVM.devices.first?.name, "FakeDisk")

        let scanVM = AppEnvironment.makeFileScanViewModel()
        scanVM.startFastScan(device: .fakeDevice())
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(scanVM.foundFiles.isEmpty)
    }

    func testFileFooterDetectorJPEGAndPNGFallbackPaths() async throws {
        let detector = FileFooterDetector()

        // SOF0 + EOI path
        var structuredJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        structuredJPEG.append(contentsOf: Array(repeating: 0x00, count: 14))
        structuredJPEG.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11])
        structuredJPEG.append(contentsOf: Array(repeating: 0x00, count: 15))
        structuredJPEG.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08])
        structuredJPEG.append(contentsOf: Array(repeating: 0x11, count: 64))
        structuredJPEG.append(contentsOf: [0xFF, 0xD9])
        structuredJPEG.append(contentsOf: Array(repeating: 0x00, count: 4096 - structuredJPEG.count))
        let structuredReader = FakePrivilegedDiskReader(buffer: Data(structuredJPEG))

        let structuredJPEGSize = try await detector.estimateSize(
            signature: .jpeg,
            startOffset: 0,
            reader: structuredReader,
            maxScanBytes: 4096
        )
        XCTAssertNotNil(structuredJPEGSize)

        var jpegBytes = [UInt8](repeating: 0, count: 4096)
        jpegBytes[0] = 0xFF
        jpegBytes[1] = 0xD8
        jpegBytes[2] = 0xFF
        jpegBytes[120] = 0xFF
        jpegBytes[121] = 0xD9
        let jpegReader = FakePrivilegedDiskReader(buffer: Data(jpegBytes))

        let jpegSize = try await detector.estimateSize(
            signature: .jpeg,
            startOffset: 0,
            reader: jpegReader,
            maxScanBytes: 2048
        )
        XCTAssertEqual(jpegSize, 122)

        var pngBytes = [UInt8](repeating: 0, count: 4096)
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (index, value) in pngHeader.enumerated() {
            pngBytes[index] = value
        }
        pngBytes[1536] = 0xFF
        pngBytes[1537] = 0xD8
        pngBytes[1538] = 0xFF
        let pngReader = FakePrivilegedDiskReader(buffer: Data(pngBytes))

        let pngSize = try await detector.estimateSize(
            signature: .png,
            startOffset: 0,
            reader: pngReader,
            maxScanBytes: 4096
        )
        XCTAssertEqual(pngSize, 1536)

        let unsupported = try await detector.estimateSize(
            signature: .mp4,
            startOffset: 0,
            reader: pngReader,
            maxScanBytes: 4096
        )
        XCTAssertNil(unsupported)
    }

    func testFATModelsAndLFNParser() {
        var sector = [UInt8](repeating: 0, count: 512)
        sector[11] = 0x00
        sector[12] = 0x02 // 512 bytes/sector
        sector[13] = 0x08 // 8 sectors/cluster
        sector[14] = 0x20
        sector[15] = 0x00 // reserved sectors
        sector[16] = 0x02 // number of FATs
        sector[36] = 0x80
        sector[37] = 0x00
        sector[38] = 0x00
        sector[39] = 0x00 // sectors per FAT
        sector[44] = 0x02
        sector[45] = 0x00
        sector[46] = 0x00
        sector[47] = 0x00 // root cluster
        sector[32] = 0x00
        sector[33] = 0x10
        sector[34] = 0x00
        sector[35] = 0x00 // total sectors
        sector[510] = 0x55
        sector[511] = 0xAA

        let bpb = BPB(bootSector: sector)
        XCTAssertNotNil(bpb)
        XCTAssertEqual(bpb?.clusterSize, 4096)
        XCTAssertEqual(bpb?.clusterOffset(2), UInt64(bpb?.dataRegionOffset ?? 0))

        var lfnEntry = [UInt8](repeating: 0xFF, count: 32)
        writeLE16(0x0056, into: &lfnEntry, at: 1) // V
        writeLE16(0x0069, into: &lfnEntry, at: 3) // i
        writeLE16(0x0076, into: &lfnEntry, at: 5) // v
        writeLE16(0x0061, into: &lfnEntry, at: 7) // a
        writeLE16(0x0063, into: &lfnEntry, at: 9) // c
        writeLE16(0x0069, into: &lfnEntry, at: 14) // i
        writeLE16(0x0074, into: &lfnEntry, at: 16) // t
        writeLE16(0x0079, into: &lfnEntry, at: 18) // y
        writeLE16(0x0000, into: &lfnEntry, at: 20)

        let chars = LFNParser.extractLFNCharacters(from: lfnEntry)
        let name = LFNParser.reconstructLFN(from: [(order: 1, chars: chars)])
        XCTAssertEqual(name, "Vivacity")
    }

    func testCarversExecutePlausiblePaths() {
        var apfsBlock = [UInt8](repeating: 0, count: 4096)
        // obj_phys_t o_type = 2 (little-endian)
        apfsBlock[24] = 0x02
        // btree leaf node metadata
        apfsBlock[32] = 0x02 // btn_flags includes leaf flag
        apfsBlock[34] = 0x00 // btn_level = 0
        apfsBlock[36] = 0x01 // btn_nkeys = 1

        let apfsResults = apfsBlock.withUnsafeBytes { bytes in
            APFSCarver().carveChunk(buffer: bytes, baseOffset: 0)
        }
        XCTAssertTrue(apfsResults.isEmpty)

        var hfsBuffer = [UInt8](repeating: 0, count: 5000)
        hfsBuffer[8] = 0xFF // kind (leaf)
        hfsBuffer[9] = 0x01 // height
        hfsBuffer[11] = 0x01 // numRecords = 1
        // keyLength = 18
        hfsBuffer[14] = 0x00
        hfsBuffer[15] = 0x12
        // nameLength = 5 ("A.jpg")
        hfsBuffer[20] = 0x00
        hfsBuffer[21] = 0x05
        writeBE16(0x0041, into: &hfsBuffer, at: 22) // A
        writeBE16(0x002E, into: &hfsBuffer, at: 24) // .
        writeBE16(0x006A, into: &hfsBuffer, at: 26) // j
        writeBE16(0x0070, into: &hfsBuffer, at: 28) // p
        writeBE16(0x0067, into: &hfsBuffer, at: 30) // g
        // recordType = 2 at currentOffset 34
        hfsBuffer[34] = 0x00
        hfsBuffer[35] = 0x02
        // logicalSize = 16 at offsets 122...129 (currentOffset + 88)
        hfsBuffer[129] = 0x10
        // startBlock = 2 at offsets 138...141 (currentOffset + 104)
        hfsBuffer[141] = 0x02

        let hfsResults = hfsBuffer.withUnsafeBytes { bytes in
            HFSPlusCarver().carveChunk(buffer: bytes, baseOffset: 0)
        }
        XCTAssertEqual(hfsResults.count, 1)
        XCTAssertEqual(hfsResults.first?.fileExtension, "jpg")
        XCTAssertEqual(hfsResults.first?.sizeInBytes, 16)
        XCTAssertEqual(hfsResults.first?.offsetOnDisk, 8192)
    }

    private func render(_ view: some View) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }

    private func writeLE16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0x00FF)
        bytes[offset + 1] = UInt8((value & 0xFF00) >> 8)
    }

    private func writeBE16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value & 0xFF00) >> 8)
        bytes[offset + 1] = UInt8(value & 0x00FF)
    }
}
