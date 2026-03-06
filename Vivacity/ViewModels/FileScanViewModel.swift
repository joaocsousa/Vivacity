import Foundation
import os

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
final class FileScanViewModel {
    // MARK: - Published State

    /// Current scan phase.
    var scanPhase: ScanPhase = .idle

    /// The detected camera profile of the scanned device.
    var cameraProfile: CameraProfile = .generic

    /// All recoverable files found across all scanning methods.
    var foundFiles: [RecoverableFile] = []

    /// IDs of user-selected files for recovery.
    var selectedFileIDs: Set<UUID> = []

    /// ID of the file currently selected for preview.
    var previewFileID: UUID?

    /// Current scan progress (0–1) for the active unified scan.
    var progress: Double = 0

    /// Estimated remaining scan time in seconds.
    var estimatedTimeRemaining: TimeInterval?

    /// Duration of the completed scan, if available.
    var scanDuration: TimeInterval?

    /// User-facing error message.
    var errorMessage: String?

    /// Whether disk access was denied and the user needs to grant permissions.
    var permissionDenied: Bool = false

    /// Current privileged helper installation status.
    var helperStatus: PrivilegedHelperStatus = .notInstalled
    var helperInstallFeedbackState: HelperInstallFeedbackState?

    /// Last sample verification summary for selected files.
    private(set) var lastSampleVerificationSummary: SampleVerificationSummary?

    /// Whether pre-recovery sample verification is currently running.
    private(set) var isVerifyingSamples: Bool = false

    /// Query string to filter by file name.
    var fileNameQuery: String = ""

    /// Selected type filter.
    var fileTypeFilter: FileTypeFilter = .all

    /// Selected size filter.
    var fileSizeFilter: FileSizeFilter = .any

    // MARK: - Dependencies

    let fastScanService: FastScanServicing
    let deepScanService: DeepScanServicing
    let sessionManager: SessionManaging
    let cameraRecoveryService: CameraRecoveryServicing
    let fileSampleVerifier: FileSampleVerifying
    let helperManager: PrivilegedHelperManaging
    let logger = Logger(subsystem: "com.vivacity.app", category: "FileScan")

    /// Handle for the currently running unified scan task (for cancellation).
    var scanTask: Task<Void, Never>?
    /// Periodic session checkpoint task while scan is active.
    var sessionAutoSaveTask: Task<Void, Never>?
    /// Exact deep-scan cursor reported by the scanner.
    var lastDeepScanOffset: UInt64 = 0

    /// Whether the metadata/catalog scan worker has finished.
    var hasCompletedFastWorker = false
    /// Whether the deep/raw scan worker has finished.
    var hasCompletedDeepWorker = false

    /// Last reported fast scan progress (0...1), used for fallback ETA near the end.
    var latestFastProgress: Double = 0

    /// Timestamp when the unified scan started.
    var scanStartTime: Date?
    /// Timestamp when the fast worker started.
    var fastWorkerStartTime: Date?
    /// Timestamp when the deep worker started.
    var deepWorkerStartTime: Date?

    /// Last checkpoint used for throughput estimation.
    var etaLastOffset: UInt64?
    /// Timestamp of the last checkpoint used for throughput estimation.
    var etaLastTimestamp: Date?
    /// Smoothed deep scan throughput (bytes/sec).
    var smoothedThroughputBytesPerSecond: Double?
    /// Last logged fast worker progress decile (0-10).
    var lastLoggedFastProgressDecile = -1
    /// Last logged deep worker progress decile (0-10).
    var lastLoggedDeepProgressDecile = -1
    /// Number of files emitted by fast worker during current scan.
    var fastFilesEmittedCount = 0
    /// Number of files emitted by deep worker during current scan.
    var deepFilesEmittedCount = 0

    /// Tracks files with real offsets to deduplicate overlaps between scan methods.
    var fileIndexByOffset: [UInt64: Int] = [:]
    /// Tracks offset-less files (usually metadata hits) by key for dedupe.
    var offsetlessKeys: Set<String> = []

    enum WorkerOutcome {
        case success
        case failed(String)
    }

    enum HelperInstallAttemptResult: Equatable {
        case installed
        case alreadyInstalled
        case failed(String)
    }

    enum HelperUninstallAttemptResult: Equatable {
        case uninstalled
        case alreadyNotInstalled
        case failed(String)
    }

    enum HelperInstallFeedbackState: Equatable {
        case success
        case failed(String)
    }

    static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static let durationFormatter: DateComponentsFormatter = {
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
        fileSampleVerifier: FileSampleVerifying = FileRecoveryService(),
        helperManager: PrivilegedHelperManaging = PrivilegedHelperInstallService(
            helperLabel: PrivilegedHelperClient.defaultServiceName
        )
    ) {
        self.fastScanService = fastScanService
        self.deepScanService = deepScanService
        self.sessionManager = sessionManager
        self.cameraRecoveryService = cameraRecoveryService
        self.fileSampleVerifier = fileSampleVerifier
        self.helperManager = helperManager
    }

    // MARK: - Actions

    /// Starts a single unified scan that runs all available scan methods.
    func startScan(device: StorageDevice, allowDeepScan: Bool = true) {
        guard scanPhase != .scanning else { return }
        let scanRequestMessage =
            "Requested unified scan for device '\(device.name)' " +
            "path=\(device.volumePath.path) " +
            "fs=\(device.filesystemType.displayName) " +
            "total=\(device.totalCapacity) " +
            "partitionSize=\(device.partitionSize ?? -1) " +
            "isDiskImage=\(device.isDiskImage) " +
            "allowDeepScan=\(allowDeepScan)"
        logger.info("\(scanRequestMessage, privacy: .public)")
        startUnifiedScan(
            device: device,
            startOffset: 0,
            seedFiles: [],
            includeFastWorker: !device.isDiskImage || !allowDeepScan,
            includeDeepWorker: allowDeepScan
        )
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

    /// Refreshes whether the privileged helper is installed and up-to-date.
    func refreshHelperStatus() {
        helperStatus = helperManager.currentStatus()
        let helperStatusRawValue = helperStatus.rawValue
        logger.info("Helper status updated to \(helperStatusRawValue, privacy: .public)")
    }

    /// Attempts to install or update the helper before starting a full scan.
    func installHelperForFullScan() -> HelperInstallAttemptResult {
        let statusBefore = helperManager.currentStatus()
        helperStatus = statusBefore
        if statusBefore == .installed {
            helperInstallFeedbackState = .success
            logger.info("Helper install skipped because helper is already installed")
            return .alreadyInstalled
        }

        do {
            try helperManager.installIfNeeded()
        } catch {
            helperStatus = helperManager.currentStatus()
            let message = error.localizedDescription
            helperInstallFeedbackState = .failed(message)
            logger.error("Helper install failed: \(message, privacy: .public)")
            return .failed(message)
        }

        let statusAfter = helperManager.currentStatus()
        helperStatus = statusAfter
        if statusAfter == .installed {
            helperInstallFeedbackState = .success
            logger.info("Helper install completed successfully")
            return .installed
        }

        let message = switch statusAfter {
        case .notInstalled:
            "Helper was not installed."
        case .updateRequired:
            "Helper install completed, but an update is still required."
        case .installed:
            "Helper installed."
        }
        helperInstallFeedbackState = .failed(message)
        logger.error("Helper install did not complete: \(message, privacy: .public)")
        return .failed(message)
    }

    /// Attempts to remove the helper from the system.
    func uninstallHelper() -> HelperUninstallAttemptResult {
        let statusBefore = helperManager.currentStatus()
        helperStatus = statusBefore
        helperInstallFeedbackState = nil
        logger.info("Helper uninstall requested statusBefore=\(statusBefore.rawValue, privacy: .public)")

        guard statusBefore != .notInstalled else {
            logger.info("Helper uninstall skipped because helper is not installed")
            return .alreadyNotInstalled
        }

        do {
            try helperManager.uninstallIfInstalled()
        } catch {
            helperStatus = helperManager.currentStatus()
            let message = error.localizedDescription
            logger.error("Helper uninstall failed: \(message, privacy: .public)")
            return .failed(message)
        }

        let statusAfter = helperManager.currentStatus()
        helperStatus = statusAfter
        logger.info("Helper uninstall post-check statusAfter=\(statusAfter.rawValue, privacy: .public)")
        guard statusAfter == .notInstalled else {
            let message = "Helper uninstall completed, but the helper still appears installed."
            logger.error("Helper uninstall did not complete: \(message, privacy: .public)")
            return .failed(message)
        }

        logger.info("Helper uninstall completed successfully")
        return .uninstalled
    }

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
            logger.error("Failed to save session: \(error.localizedDescription, privacy: .public)")
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
            includeFastWorker: false,
            includeDeepWorker: true
        )
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
            logger.error("Sample verification failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Sample verification failed: \(error.localizedDescription)"
            return nil
        }
    }
}
