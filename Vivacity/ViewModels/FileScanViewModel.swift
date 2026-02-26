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
    // MARK: - Published State

    /// Current scan phase.
    private(set) var scanPhase: ScanPhase = .idle

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

    /// Whether recovery can be started (not scanning + at least one selected).
    var canRecover: Bool {
        (scanPhase == .fastComplete || scanPhase == .complete) && !selectedFileIDs.isEmpty
    }

    /// Whether scanning is currently in progress.
    var isScanning: Bool {
        scanPhase == .fastScanning || scanPhase == .deepScanning
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
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FileScan")

    /// Handle for the currently running scan task (for cancellation).
    private var scanTask: Task<Void, Never>?

    /// Timestamp when the fast scan started.
    private var fastScanStartTime: Date?

    // MARK: - Init

    init(
        fastScanService: FastScanServicing = FastScanService(),
        deepScanService: DeepScanServicing = DeepScanService()
    ) {
        self.fastScanService = fastScanService
        self.deepScanService = deepScanService
    }

    // MARK: - Actions

    /// Starts the fast (metadata-based) scan on the given device.
    func startFastScan(device: StorageDevice) {
        guard scanPhase == .idle else { return }

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
                    finishFastScan()
                }
            } catch is CancellationError {
                logger.info("Fast scan cancelled by user")
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

        // We use offsetOnDisk to deduplicate bytes found in the Deep Scan.
        // FastScanService sets offsetOnDisk to 0 for files found by FileManager,
        // so we filter those out (otherwise the Deep Scanner will skip sector 0 entirely).
        let existingOffsets = Set(foundFiles.map(\.offsetOnDisk).filter { $0 > 0 })

        scanTask = Task {
            do {
                let stream = deepScanService.scan(
                    device: device,
                    existingOffsets: existingOffsets
                )
                for try await event in stream {
                    handleScanEvent(event)
                }
                if scanPhase == .deepScanning {
                    scanPhase = .complete
                }
            } catch is CancellationError {
                logger.info("Deep scan cancelled by user")
                scanPhase = .complete
            } catch {
                logger.error("Deep scan error: \(error.localizedDescription)")
                errorMessage = "Deep scan error: \(error.localizedDescription)"
                scanPhase = .complete
            }
        }
    }

    /// Stops the currently running scan phase early.
    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil

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

    /// Deselects all files.
    func deselectAll() {
        selectedFileIDs.removeAll()
    }

    // MARK: - Private

    private func handleScanEvent(_ event: ScanEvent) {
        switch event {
        case let .fileFound(file):
            foundFiles.append(file)
        case let .progress(value):
            progress = value
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
}
