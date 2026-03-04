import Foundation
import os

// MARK: - Scan Phase

/// The current phase of the dual-scan flow.
enum ScanPhase: Sendable, Equatable {
    case idle
    case fastScanning
    case fastComplete
    case deepScanning
    case complete
}

// MARK: - ViewModel

/// ViewModel for the file scan screen.
///
/// Manages a two-phase scan flow (Fast Scan → optional Deep Scan) and exposes
/// the cumulative file list, selection state, and progress to the view layer.
@Observable
@MainActor
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

    /// All recoverable files found across both phases.
    private(set) var foundFiles: [RecoverableFile] = []

    /// IDs of user-selected files for recovery.
    var selectedFileIDs: Set<UUID> = []

    /// ID of the file currently selected for preview.
    var previewFileID: UUID?

    /// Current scan progress (0–1) for the active phase.
    private(set) var progress: Double = 0

    /// Duration of the fast scan in seconds (set when fast scan completes).
    private(set) var fastScanDuration: TimeInterval?

    /// User-facing error message.
    var errorMessage: String?

    /// Whether disk access was denied and the user needs to grant permissions.
    var permissionDenied: Bool = false

    /// Last sample verification summary for selected files.
    private(set) var lastSampleVerificationSummary: SampleVerificationSummary?

    /// Whether pre-recovery sample verification is currently running.
    private(set) var isVerifyingSamples: Bool = false

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
        (scanPhase == .fastComplete || scanPhase == .complete) && !selectedFileIDs.isEmpty
    }

    /// Whether scanning is currently in progress.
    var isScanning: Bool {
        scanPhase == .fastScanning || scanPhase == .deepScanning
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

    /// Files found by the fast scan matching current filters.
    var filteredFastScanFiles: [RecoverableFile] {
        filteredFiles.filter { $0.source == .fastScan }
    }

    /// Files found by the deep scan matching current filters.
    var filteredDeepScanFiles: [RecoverableFile] {
        filteredFiles.filter { $0.source == .deepScan }
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

    /// Files found by the fast scan.
    var fastScanFiles: [RecoverableFile] {
        foundFiles.filter { $0.source == .fastScan }
    }

    /// Files found by the deep scan.
    var deepScanFiles: [RecoverableFile] {
        foundFiles.filter { $0.source == .deepScan }
    }

    // MARK: - Dependencies

    private let fastScanService: FastScanServicing
    private let deepScanService: DeepScanServicing
    private let sessionManager: SessionManaging
    private let cameraRecoveryService: CameraRecoveryServicing
    private let fileSampleVerifier: FileSampleVerifying
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FileScan")

    /// Handle for the currently running scan task (for cancellation).
    private var scanTask: Task<Void, Never>?
    /// Periodic session checkpoint task while deep scan is active.
    private var sessionAutoSaveTask: Task<Void, Never>?
    /// Exact deep-scan cursor reported by the scanner.
    private var lastDeepScanOffset: UInt64 = 0

    /// Timestamp when the fast scan started.
    private var fastScanStartTime: Date?

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

    /// Starts the fast (metadata-based) scan on the given device.
    func startFastScan(device: StorageDevice) {
        guard scanPhase == .idle else { return }

        // Raw disk images are not mounted, so we can't use FileManager fast scan.
        // Jump straight to the deep scan prompt phase.
        if device.isDiskImage {
            logger.info("Skipping fast scan for disk image: \(device.name)")
            scanPhase = .fastComplete
            return
        }

        scanPhase = .fastScanning
        progress = 0
        foundFiles = []
        selectedFileIDs = []
        errorMessage = nil
        fastScanStartTime = Date()

        scanTask = Task {
            do {
                let stream = fastScanService.scan(device: device)
                for try await event in stream {
                    handleScanEvent(event)
                }
                // If we reach here without .completed, mark as complete
                if scanPhase == .fastScanning {
                    cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
                    finishFastScan()
                }
            } catch is CancellationError {
                logger.info("Fast scan cancelled by user")
                cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
                scanPhase = .fastComplete
            } catch {
                logger.error("Fast scan error: \(error.localizedDescription)")
                errorMessage = "Scan error: \(error.localizedDescription)"
                scanPhase = .fastComplete
            }
        }
    }

    /// Starts the deep (byte-carving) scan on the given device.
    func startDeepScan(device: StorageDevice) {
        guard scanPhase == .fastComplete else { return }

        scanPhase = .deepScanning
        progress = 0
        errorMessage = nil
        lastDeepScanOffset = 0

        // We use offsetOnDisk to deduplicate bytes found in the Deep Scan.
        // FastScanService sets offsetOnDisk to 0 for files found by FileManager,
        // so we filter those out (otherwise the Deep Scanner will skip sector 0 entirely).
        let existingOffsets = Set(foundFiles.map(\.offsetOnDisk).filter { $0 > 0 })

        scanTask = Task {
            do {
                let stream = deepScanService.scan(
                    device: device,
                    existingOffsets: existingOffsets,
                    startOffset: 0,
                    cameraProfile: cameraProfile
                )
                for try await event in stream {
                    handleScanEvent(event)
                }
                if scanPhase == .deepScanning {
                    scanPhase = .complete
                }
                stopSessionAutoSave()
            } catch is CancellationError {
                logger.info("Deep scan cancelled by user")
                scanPhase = .complete
                stopSessionAutoSave()
            } catch {
                logger.error("Deep scan error: \(error.localizedDescription)")
                errorMessage = "Deep scan error: \(error.localizedDescription)"
                scanPhase = .complete
                stopSessionAutoSave()
            }
        }
        startSessionAutoSave(device: device)
    }

    /// Stops the currently running scan phase early.
    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        stopSessionAutoSave()

        // If the user manually stops the scan, we always jump to the final completion state
        // (skipping any intermediate prompts like the Deep Scan prompt)
        switch scanPhase {
        case .fastScanning:
            logger.info("Fast scan stopped early by user. Transitioning to final complete state.")
            scanPhase = .complete

        case .deepScanning:
            logger.info("Deep scan stopped early by user. Transitioning to final complete state.")
            scanPhase = .complete

        default:
            break
        }
    }

    /// Skips the deep scan and transitions to `.complete`.
    func skipDeepScan() {
        guard scanPhase == .fastComplete else { return }
        scanPhase = .complete
        stopSessionAutoSave()
    }

    // MARK: - Session Management

    /// Saves the current scan progress for the given device.
    func saveSession(device: StorageDevice) async {
        guard isScanning || scanPhase == .fastComplete || scanPhase == .complete else { return }

        // Convert progress percentage back to approximate offset
        let activeOffset: UInt64 = switch scanPhase {
        case .deepScanning:
            max(lastDeepScanOffset, UInt64(progress * Double(device.totalCapacity)))
        case .complete:
            max(lastDeepScanOffset, UInt64(device.totalCapacity))
        default:
            0
        }

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

    /// Loads a saved session and resumes deep scanning.
    func resumeSession(_ session: ScanSession, device: StorageDevice) {
        guard scanPhase == .idle else { return }

        scanPhase = .deepScanning
        foundFiles = session.discoveredFiles
        progress = Double(session.lastScannedOffset) / Double(device.totalCapacity)
        lastDeepScanOffset = UInt64(max(session.lastScannedOffset, 0))
        selectedFileIDs = []
        errorMessage = nil

        let existingOffsets = Set(foundFiles.map(\.offsetOnDisk).filter { $0 > 0 })
        cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)

        scanTask = Task {
            do {
                let stream = deepScanService.scan(
                    device: device,
                    existingOffsets: existingOffsets,
                    startOffset: UInt64(session.lastScannedOffset),
                    cameraProfile: cameraProfile
                )
                for try await event in stream {
                    handleScanEvent(event)
                }
                if scanPhase == .deepScanning {
                    scanPhase = .complete
                }
                stopSessionAutoSave()
            } catch is CancellationError {
                logger.info("Deep scan cancelled by user")
                scanPhase = .complete
                stopSessionAutoSave()
            } catch {
                logger.error("Deep scan error: \(error.localizedDescription)")
                errorMessage = "Deep scan error: \(error.localizedDescription)"
                scanPhase = .complete
                stopSessionAutoSave()
            }
        }
        startSessionAutoSave(device: device)
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

    private func handleScanEvent(_ event: ScanEvent) {
        switch event {
        case let .fileFound(file):
            foundFiles.append(file)
            if file.recoveryConfidence != .low {
                selectedFileIDs.insert(file.id)
            }
        case let .progress(value):
            progress = value
        case let .checkpoint(offset):
            lastDeepScanOffset = offset
        case .completed:
            if scanPhase == .fastScanning {
                finishFastScan()
            } else if scanPhase == .deepScanning {
                scanPhase = .complete
            }
        }
    }

    private func finishFastScan() {
        if let start = fastScanStartTime {
            fastScanDuration = Date().timeIntervalSince(start)
        }
        scanPhase = .fastComplete
        progress = 1
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
