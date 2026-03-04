import Foundation
import os

// swiftlint:disable file_length
// MARK: - Scan Phase

/// The current phase of the unified single-run scan flow.
enum ScanPhase: Sendable, Equatable {
    case idle
    case scanning
    case complete
}

// MARK: - ViewModel

/// ViewModel for the file scan screen.
///
/// Manages a single user-facing scan flow that runs all available scan methods
/// and exposes the cumulative file list, selection state, and progress to the
/// view layer.
@Observable
@MainActor
// swiftlint:disable:next type_body_length
final class FileScanViewModel {
    struct SampleVerificationSummary: Sendable, Equatable {
        let verifiedCount: Int
        let mismatchCount: Int
        let unreadableCount: Int

        var hasWarnings: Bool {
            mismatchCount > 0 || unreadableCount > 0
        }

        var warningMessage: String {
            var parts: [String] = []
            if mismatchCount > 0 {
                parts.append("\(mismatchCount) file(s) changed between reads")
            }
            if unreadableCount > 0 {
                parts.append("\(unreadableCount) file(s) could not be read")
            }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Published State

    /// Current scan phase.
    private(set) var scanPhase: ScanPhase = .idle

    /// The detected camera profile of the scanned device.
    private(set) var cameraProfile: CameraProfile = .generic

    /// All recoverable files found across all scanning methods.
    private(set) var foundFiles: [RecoverableFile] = []

    /// IDs of user-selected files for recovery.
    var selectedFileIDs: Set<UUID> = []

    /// ID of the file currently selected for preview.
    var previewFileID: UUID?

    /// Current scan progress (0–1) for the active unified scan.
    private(set) var progress: Double = 0

    /// Estimated remaining scan time in seconds.
    private(set) var estimatedTimeRemaining: TimeInterval?

    /// Duration of the completed scan, if available.
    private(set) var scanDuration: TimeInterval?

    /// User-facing error message.
    var errorMessage: String?

    /// Whether disk access was denied and the user needs to grant permissions.
    var permissionDenied: Bool = false

    /// Last sample verification summary for selected files.
    private(set) var lastSampleVerificationSummary: SampleVerificationSummary?

    /// Whether pre-recovery sample verification is currently running.
    private(set) var isVerifyingSamples: Bool = false

    /// Human-readable percentage label for current progress.
    var progressPercentageText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    /// Human-readable ETA label for scan progress.
    var estimatedTimeRemainingText: String? {
        guard isScanning, let remaining = estimatedTimeRemaining, remaining.isFinite else {
            return nil
        }
        if remaining <= 60 {
            return "< 1 min"
        }
        return Self.etaFormatter.string(from: remaining)
    }

    /// Human-readable total scan duration label (available after completion).
    var scanDurationText: String? {
        guard let duration = scanDuration else { return nil }
        return Self.durationFormatter.string(from: duration)
    }

    // MARK: - Filters

    enum FileTypeFilter: String, CaseIterable, Sendable {
        case all = "All"
        case images = "Images"
        case videos = "Videos"
    }

    enum FileSizeFilter: String, CaseIterable, Sendable {
        case any = "Any Size"
        case under5MB = "Under 5 MB"
        case between5And100MB = "5-100 MB"
        case over100MB = "Over 100 MB"

        var byteRange: ClosedRange<Int64>? {
            switch self {
            case .any:
                nil
            case .under5MB:
                0 ... 5_000_000
            case .between5And100MB:
                5_000_001 ... 100_000_000
            case .over100MB:
                100_000_001 ... Int64.max
            }
        }
    }

    /// Query string to filter by file name.
    var fileNameQuery: String = ""

    /// Selected type filter.
    var fileTypeFilter: FileTypeFilter = .all

    /// Selected size filter.
    var fileSizeFilter: FileSizeFilter = .any

    // MARK: - Computed

    /// The file currently selected for preview, if any.
    var previewFile: RecoverableFile? {
        guard let id = previewFileID else { return nil }
        return foundFiles.first { $0.id == id }
    }

    /// Number of files the user has selected.
    var selectedCount: Int {
        selectedFileIDs.count
    }

    /// Number of selected files visible under current filters.
    var selectedFilteredCount: Int {
        let filteredIDs = Set(filteredFiles.map(\.id))
        return selectedFileIDs.intersection(filteredIDs).count
    }

    /// Whether any filter is active.
    var isFiltering: Bool {
        !fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || fileTypeFilter != .all
            || fileSizeFilter != .any
    }

    /// Whether recovery can be started (not scanning + at least one selected).
    var canRecover: Bool {
        scanPhase == .complete && !selectedFileIDs.isEmpty
    }

    /// Whether scanning is currently in progress.
    var isScanning: Bool {
        scanPhase == .scanning
    }

    /// Whether there are any files to filter.
    var hasFiles: Bool {
        !foundFiles.isEmpty
    }

    /// Files that match the current filters.
    var filteredFiles: [RecoverableFile] {
        let normalizedQuery = fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return foundFiles.filter { file in
            if !normalizedQuery.isEmpty {
                let nameMatches = file.fullFileName.lowercased().contains(normalizedQuery)
                let pathMatches = file.filePath?.lowercased().contains(normalizedQuery) ?? false
                if !nameMatches, !pathMatches {
                    return false
                }
            }

            switch fileTypeFilter {
            case .all:
                break
            case .images:
                if file.fileType != .image { return false }
            case .videos:
                if file.fileType != .video { return false }
            }

            if let range = fileSizeFilter.byteRange, !range.contains(file.sizeInBytes) {
                return false
            }

            return true
        }
    }

    /// Whether the filtered result set is empty while files exist.
    var showFilteredEmptyState: Bool {
        hasFiles && filteredFiles.isEmpty
    }

    /// Label showing filtered vs total counts.
    var filteredCountLabel: String {
        if isFiltering {
            return "Showing \(filteredFiles.count) of \(foundFiles.count) files"
        }
        return "\(foundFiles.count) files found"
    }

    /// Label showing selected count under current filters.
    var selectedCountLabel: String? {
        guard selectedCount > 0 else { return nil }

        if isFiltering {
            return "Selected \(selectedFilteredCount) of \(filteredFiles.count) shown"
        }

        return "Selected \(selectedCount)"
    }

    // MARK: - Dependencies

    private let fastScanService: FastScanServicing
    private let deepScanService: DeepScanServicing
    private let sessionManager: SessionManaging
    private let cameraRecoveryService: CameraRecoveryServicing
    private let fileSampleVerifier: FileSampleVerifying
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FileScan")

    /// Handle for the currently running unified scan task (for cancellation).
    private var scanTask: Task<Void, Never>?
    /// Periodic session checkpoint task while scan is active.
    private var sessionAutoSaveTask: Task<Void, Never>?
    /// Exact deep-scan cursor reported by the scanner.
    private var lastDeepScanOffset: UInt64 = 0

    /// Whether the metadata/catalog scan worker has finished.
    private var hasCompletedFastWorker = false
    /// Whether the deep/raw scan worker has finished.
    private var hasCompletedDeepWorker = false

    /// Last reported fast scan progress (0...1), used for fallback ETA near the end.
    private var latestFastProgress: Double = 0

    /// Timestamp when the unified scan started.
    private var scanStartTime: Date?
    /// Timestamp when the fast worker started.
    private var fastWorkerStartTime: Date?
    /// Timestamp when the deep worker started.
    private var deepWorkerStartTime: Date?

    /// Last checkpoint used for throughput estimation.
    private var etaLastOffset: UInt64?
    /// Timestamp of the last checkpoint used for throughput estimation.
    private var etaLastTimestamp: Date?
    /// Smoothed deep scan throughput (bytes/sec).
    private var smoothedThroughputBytesPerSecond: Double?

    /// Tracks files with real offsets to deduplicate overlaps between scan methods.
    private var fileIndexByOffset: [UInt64: Int] = [:]
    /// Tracks offset-less files (usually metadata hits) by key for dedupe.
    private var offsetlessKeys: Set<String> = []

    private enum WorkerOutcome {
        case success
        case failed(String)
    }

    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    // MARK: - Init

    init(
        fastScanService: FastScanServicing = FastScanService(),
        deepScanService: DeepScanServicing = DeepScanService(),
        sessionManager: SessionManaging = SessionManager(),
        cameraRecoveryService: CameraRecoveryServicing = CameraRecoveryService(),
        fileSampleVerifier: FileSampleVerifying = FileRecoveryService()
    ) {
        self.fastScanService = fastScanService
        self.deepScanService = deepScanService
        self.sessionManager = sessionManager
        self.cameraRecoveryService = cameraRecoveryService
        self.fileSampleVerifier = fileSampleVerifier
    }

    // MARK: - Actions

    /// Starts a single unified scan that runs all available scan methods.
    func startScan(device: StorageDevice) {
        guard scanPhase == .idle else { return }
        startUnifiedScan(device: device, startOffset: 0, seedFiles: [], includeFastWorker: !device.isDiskImage)
    }

    /// Stops the currently running scan phase early.
    func stopScanning() {
        guard scanPhase == .scanning else { return }
        logger.info("Scan stopped early by user. Transitioning to complete state.")
        scanTask?.cancel()
        scanTask = nil
        hasCompletedFastWorker = true
        hasCompletedDeepWorker = true
        markScanCompleted(forceProgressToFull: false)
    }

    /// Backward-compatible wrappers for older call sites/tests.
    func startFastScan(device: StorageDevice) {
        startScan(device: device)
    }

    func startDeepScan(device _: StorageDevice) {}

    func skipDeepScan() {}

    // MARK: - Session Management

    /// Saves the current scan progress for the given device.
    func saveSession(device: StorageDevice) async {
        guard isScanning || scanPhase == .complete else { return }

        let activeOffset = max(lastDeepScanOffset, UInt64(progress * Double(device.totalCapacity)))

        let session = ScanSession(
            id: UUID(),
            dateSaved: Date(),
            deviceID: device.id,
            deviceTotalCapacity: device.totalCapacity,
            lastScannedOffset: Int64(activeOffset),
            discoveredFiles: foundFiles
        )

        do {
            try await sessionManager.save(session)
            logger.info("Session saved successfully")
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
            errorMessage = "Failed to save session: \(error.localizedDescription)"
        }
    }

    /// Loads a saved session and resumes the unified scan from the deep cursor.
    func resumeSession(_ session: ScanSession, device: StorageDevice) {
        guard scanPhase == .idle else { return }
        let startOffset = UInt64(max(session.lastScannedOffset, 0))
        startUnifiedScan(
            device: device,
            startOffset: startOffset,
            seedFiles: session.discoveredFiles,
            includeFastWorker: false
        )
    }

    // MARK: - Selection

    /// Toggles the selection state of a file.
    func toggleSelection(_ fileID: UUID) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else {
            selectedFileIDs.insert(fileID)
        }
    }

    /// Selects all found files.
    func selectAll() {
        selectedFileIDs = Set(foundFiles.map(\.id))
    }

    /// Selects all filtered files.
    func selectAllFiltered() {
        let filteredIDs = Set(filteredFiles.map(\.id))
        selectedFileIDs.formUnion(filteredIDs)
    }

    /// Deselects all files.
    func deselectAll() {
        selectedFileIDs.removeAll()
    }

    /// Deselects all filtered files.
    func deselectFiltered() {
        let filteredIDs = Set(filteredFiles.map(\.id))
        selectedFileIDs.subtract(filteredIDs)
    }

    /// Verifies selected files by hashing head/tail samples before recovery.
    ///
    /// Returns a summary with counts of verified, mismatched, and unreadable files.
    func verifySelectedSamples(device: StorageDevice) async -> SampleVerificationSummary? {
        let selectedFiles = foundFiles.filter { selectedFileIDs.contains($0.id) }
        guard !selectedFiles.isEmpty else { return nil }

        isVerifyingSamples = true
        defer { isVerifyingSamples = false }

        do {
            let results = try await fileSampleVerifier.verifySamples(files: selectedFiles, from: device)
            let summary = SampleVerificationSummary(
                verifiedCount: results.filter { $0.status == .verified }.count,
                mismatchCount: results.filter { $0.status == .mismatch }.count,
                unreadableCount: results.filter { $0.status == .unreadable }.count
            )
            lastSampleVerificationSummary = summary
            return summary
        } catch {
            logger.error("Sample verification failed: \(error.localizedDescription)")
            errorMessage = "Sample verification failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Private

    private func startUnifiedScan(
        device: StorageDevice,
        startOffset: UInt64,
        seedFiles: [RecoverableFile],
        includeFastWorker: Bool
    ) {
        scanTask?.cancel()
        stopSessionAutoSave()

        scanPhase = .scanning
        progress = min(max(Double(startOffset) / max(Double(device.totalCapacity), 1), 0), 1)
        estimatedTimeRemaining = nil
        scanDuration = nil
        errorMessage = nil

        foundFiles = seedFiles
        selectedFileIDs = Set(seedFiles.filter { $0.recoveryConfidence != .low }.map(\.id))
        previewFileID = foundFiles.first?.id

        initializeDedupeIndexes()

        lastDeepScanOffset = startOffset
        hasCompletedFastWorker = !includeFastWorker
        hasCompletedDeepWorker = false
        latestFastProgress = 0
        scanStartTime = Date()
        fastWorkerStartTime = nil
        deepWorkerStartTime = nil
        etaLastOffset = startOffset
        etaLastTimestamp = nil
        smoothedThroughputBytesPerSecond = nil

        cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
        startSessionAutoSave(device: device)

        scanTask = Task { [weak self] in
            guard let self else { return }
            async let fastOutcome = runFastScanIfNeeded(device: device, shouldRun: includeFastWorker)
            async let deepOutcome = runDeepScan(device: device, startOffset: startOffset)

            let (fastResult, deepResult) = await (fastOutcome, deepOutcome)
            finishUnifiedScan(fastOutcome: fastResult, deepOutcome: deepResult)
        }
    }

    private func runFastScanIfNeeded(device: StorageDevice, shouldRun: Bool) async -> WorkerOutcome {
        guard shouldRun else {
            return .success
        }

        fastWorkerStartTime = Date()
        do {
            let stream = fastScanService.scan(device: device)
            for try await event in stream {
                try Task.checkCancellation()
                handleFastScanEvent(event)
            }
            hasCompletedFastWorker = true
            cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
            return .success
        } catch is CancellationError {
            hasCompletedFastWorker = true
            return .success
        } catch {
            hasCompletedFastWorker = true
            logger.error("Fast scan worker error: \(error.localizedDescription)")
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
            return .failed("Fast scan warning: \(error.localizedDescription)")
        }
    }

    private func runDeepScan(device: StorageDevice, startOffset: UInt64) async -> WorkerOutcome {
        deepWorkerStartTime = Date()
        etaLastTimestamp = deepWorkerStartTime
        do {
            let existingOffsets = Set(foundFiles.map(\.offsetOnDisk).filter { $0 > 0 })
            let stream = deepScanService.scan(
                device: device,
                existingOffsets: existingOffsets,
                startOffset: startOffset,
                cameraProfile: cameraProfile
            )

            for try await event in stream {
                try Task.checkCancellation()
                handleDeepScanEvent(event, totalBytes: UInt64(device.totalCapacity))
            }

            hasCompletedDeepWorker = true
            if hasCompletedFastWorker {
                progress = 1
                estimatedTimeRemaining = nil
            } else {
                progress = max(progress, 0.99)
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
            return .success
        } catch is CancellationError {
            hasCompletedDeepWorker = true
            return .success
        } catch {
            hasCompletedDeepWorker = true
            logger.error("Deep scan worker error: \(error.localizedDescription)")
            return .failed("Deep scan error: \(error.localizedDescription)")
        }
    }

    private func finishUnifiedScan(fastOutcome: WorkerOutcome, deepOutcome: WorkerOutcome) {
        var messages: [String] = []
        if case let .failed(message) = deepOutcome {
            messages.append(message)
        }
        if case let .failed(message) = fastOutcome {
            messages.append(message)
        }
        if !messages.isEmpty {
            errorMessage = messages.joined(separator: "\n")
        }

        cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
        if scanPhase == .scanning {
            let forceComplete = !messages.contains(where: { $0.hasPrefix("Deep scan error:") })
            markScanCompleted(forceProgressToFull: forceComplete)
        }
        scanTask = nil
    }

    private func handleFastScanEvent(_ event: ScanEvent) {
        switch event {
        case let .fileFound(file):
            mergeFoundFile(file)
        case let .progress(value):
            latestFastProgress = min(max(value, 0), 1)
            if hasCompletedDeepWorker, !hasCompletedFastWorker {
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
        case .checkpoint:
            break
        case .completed:
            hasCompletedFastWorker = true
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
        }
    }

    private func handleDeepScanEvent(_ event: ScanEvent, totalBytes: UInt64) {
        switch event {
        case let .fileFound(file):
            mergeFoundFile(file)
        case let .progress(value):
            updateProgressAndETA(
                normalizedProgress: value,
                offsetHint: lastDeepScanOffset,
                totalBytes: totalBytes
            )
        case let .checkpoint(offset):
            lastDeepScanOffset = offset
            let normalized = Double(offset) / max(Double(totalBytes), 1)
            updateProgressAndETA(normalizedProgress: normalized, offsetHint: offset, totalBytes: totalBytes)
        case .completed:
            hasCompletedDeepWorker = true
            if hasCompletedFastWorker {
                updateProgressAndETA(
                    normalizedProgress: 1,
                    offsetHint: totalBytes,
                    totalBytes: totalBytes
                )
            } else {
                progress = max(progress, 0.99)
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
        }
    }

    private func mergeFoundFile(_ file: RecoverableFile) {
        if file.offsetOnDisk > 0 {
            if let existingIndex = fileIndexByOffset[file.offsetOnDisk], foundFiles.indices.contains(existingIndex) {
                let existing = foundFiles[existingIndex]
                if shouldPrefer(file, over: existing) {
                    let wasSelected = selectedFileIDs.contains(existing.id)
                    let wasPreviewed = previewFileID == existing.id

                    selectedFileIDs.remove(existing.id)
                    foundFiles[existingIndex] = file

                    if wasSelected || file.recoveryConfidence != .low {
                        selectedFileIDs.insert(file.id)
                    }
                    if wasPreviewed {
                        previewFileID = file.id
                    }
                }
                return
            }
        } else {
            let key = offsetlessKey(for: file)
            if offsetlessKeys.contains(key) {
                return
            }
            offsetlessKeys.insert(key)
        }

        let newIndex = foundFiles.count
        foundFiles.append(file)
        if file.offsetOnDisk > 0 {
            fileIndexByOffset[file.offsetOnDisk] = newIndex
        }
        if previewFileID == nil {
            previewFileID = file.id
        }
        if file.recoveryConfidence != .low {
            selectedFileIDs.insert(file.id)
        }
    }

    private func shouldPrefer(_ newFile: RecoverableFile, over existingFile: RecoverableFile) -> Bool {
        if newFile.source == .fastScan, existingFile.source == .deepScan {
            return true
        }
        if newFile.filePath != nil, existingFile.filePath == nil {
            return true
        }
        if (newFile.confidenceScore ?? 0) > (existingFile.confidenceScore ?? 0) {
            return true
        }
        return false
    }

    private func offsetlessKey(for file: RecoverableFile) -> String {
        if let filePath = file.filePath?.lowercased() {
            return "path:\(filePath)"
        }
        return "name:\(file.fullFileName.lowercased())|size:\(file.sizeInBytes)"
    }

    private func initializeDedupeIndexes() {
        fileIndexByOffset.removeAll(keepingCapacity: true)
        offsetlessKeys.removeAll(keepingCapacity: true)

        for (index, file) in foundFiles.enumerated() {
            if file.offsetOnDisk > 0 {
                fileIndexByOffset[file.offsetOnDisk] = index
            } else {
                offsetlessKeys.insert(offsetlessKey(for: file))
            }
        }
    }

    private func updateProgressAndETA(
        normalizedProgress: Double,
        offsetHint: UInt64,
        totalBytes: UInt64
    ) {
        let clampedProgress = min(max(normalizedProgress, 0), 1)
        progress = max(progress, clampedProgress)

        guard scanPhase == .scanning else {
            estimatedTimeRemaining = nil
            return
        }

        let now = Date()
        let safeOffset = min(offsetHint, totalBytes)

        if let previousOffset = etaLastOffset,
           let previousTimestamp = etaLastTimestamp
        {
            let deltaBytes = Double(max(Int64(safeOffset) - Int64(previousOffset), 0))
            let deltaTime = now.timeIntervalSince(previousTimestamp)
            if deltaBytes > 0, deltaTime > 0.1 {
                let instantaneousThroughput = deltaBytes / deltaTime
                if instantaneousThroughput.isFinite, instantaneousThroughput > 0 {
                    if let previous = smoothedThroughputBytesPerSecond {
                        smoothedThroughputBytesPerSecond = previous * 0.75 + instantaneousThroughput * 0.25
                    } else {
                        smoothedThroughputBytesPerSecond = instantaneousThroughput
                    }
                }
            }
        }

        etaLastOffset = safeOffset
        etaLastTimestamp = now

        if progress >= 0.999 {
            estimatedTimeRemaining = hasCompletedFastWorker ? nil : estimateFastRemainingTime()
            return
        }

        let total = Double(totalBytes)
        let remainingBytes = max(0, total * (1 - progress))
        if let throughput = smoothedThroughputBytesPerSecond, throughput > 0 {
            estimatedTimeRemaining = remainingBytes / throughput
            return
        }

        if let start = deepWorkerStartTime, progress > 0.01 {
            let elapsed = now.timeIntervalSince(start)
            estimatedTimeRemaining = max(0, elapsed * (1 - progress) / progress)
        }
    }

    private func estimateFastRemainingTime() -> TimeInterval? {
        guard let start = fastWorkerStartTime, latestFastProgress > 0.01 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let estimatedTotal = elapsed / latestFastProgress
        return max(0, estimatedTotal - elapsed)
    }

    private func markScanCompleted(forceProgressToFull: Bool) {
        if forceProgressToFull {
            progress = 1
        }
        estimatedTimeRemaining = nil
        scanPhase = .complete
        if let startedAt = scanStartTime {
            scanDuration = Date().timeIntervalSince(startedAt)
        }
        stopSessionAutoSave()
    }

    private func startSessionAutoSave(device: StorageDevice) {
        stopSessionAutoSave()
        sessionAutoSaveTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await saveSession(device: device)
            }
        }
    }

    private func stopSessionAutoSave() {
        sessionAutoSaveTask?.cancel()
        sessionAutoSaveTask = nil
    }
}
