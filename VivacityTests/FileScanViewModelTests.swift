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

@MainActor
final class FileScanViewModelAdditionalTests: XCTestCase {
    func testDiskImageSkipsFastScanImmediately() async {
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: [])
        )
        var image = StorageDevice.fakeDevice()
        image.isDiskImage = true

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

    func testLoadDiskImageInsertsAndDeduplicates() throws {
        let sut = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [])
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivacity-image-\(UUID().uuidString).img")
        let bytes = Data(repeating: 0xAB, count: 16)
        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        sut.loadDiskImage(at: tempURL)
        sut.loadDiskImage(at: tempURL)

        XCTAssertEqual(sut.devices.count, 1)
        XCTAssertEqual(sut.selectedDevice?.id, tempURL.absoluteString)
        XCTAssertEqual(sut.devices.first?.totalCapacity, 16)
    }

    func testCreateImageSuccessAndFailureResetState() async {
        let device = StorageDevice.fakeDevice()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).dd")
        defer { try? FileManager.default.removeItem(at: destination) }

        let successSUT = DeviceSelectionViewModel(
            deviceService: TestDeviceService(devices: []),
            partitionSearchService: PartitionSearchService(),
            sessionManager: TestSessionManager(),
            diskImageService: TestDiskImageService(progressValues: [0.25, 0.9, 1.0])
        )

        await successSUT.createImage(for: device, to: destination)
        XCTAssertFalse(successSUT.isCreatingImage)
        XCTAssertEqual(successSUT.imageCreationProgress, 0.0)
        XCTAssertNil(successSUT.errorMessage)

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

        let permissionDenied = FileScanViewModel(
            fastScanService: FakeFastScanService(events: []),
            deepScanService: FakeDeepScanService(events: [])
        )
        permissionDenied.permissionDenied = true
        AppEnvironment.makeFileScanViewModel = { permissionDenied }
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

    init(progressValues: [Double], shouldThrow: Bool = false) {
        self.progressValues = progressValues
        self.shouldThrow = shouldThrow
    }

    func createImage(from device: StorageDevice, to destinationURL: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if shouldThrow {
                    continuation.finish(throwing: TestFailure.expected)
                    return
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
            PermissionDeniedView(
                onTryAgain: {},
                onContinueLimited: {}
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
