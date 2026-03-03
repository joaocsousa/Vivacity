import AppKit
import Foundation
import Observation

/// Errors raised while validating destination or starting recovery.
enum RecoveryDestinationError: LocalizedError {
    case destinationRequired
    case destinationOnScannedDevice
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .destinationRequired:
            "Please choose a destination folder."
        case .destinationOnScannedDevice:
            "Choose a destination on a different device to avoid overwriting recoverable data."
        case let .insufficientSpace(required, available):
            "Not enough free space. Required: \(formatBytes(required)), available: \(formatBytes(available))."
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// ViewModel for recovery destination selection and validation.
@Observable
@MainActor
final class RecoveryDestinationViewModel {
    typealias DirectoryPicker = @MainActor () -> URL?
    typealias VolumeInfoLookup = @MainActor (URL) -> VolumeInfo

    struct VolumeInfo: Sendable {
        let volumeRootURL: URL
        let volumeUUID: String?
        let availableCapacity: Int64
    }

    /// User-selected destination folder.
    var destinationURL: URL?

    /// Total bytes required for currently selected files.
    let requiredSpace: Int64

    /// Bytes available on the destination volume.
    private(set) var availableSpace: Int64 = 0

    /// Indicates destination resides on the scanned source device.
    private(set) var isDestinationOnScannedDevice: Bool = false

    /// Whether a recovery operation is currently running.
    private(set) var isRecovering: Bool = false

    /// Whether recovery completed successfully.
    private(set) var didCompleteRecovery: Bool = false

    /// User-facing validation or recovery error.
    var errorMessage: String?

    /// True when destination exists, has enough space, and is not on the scanned device.
    var hasEnoughSpace: Bool {
        destinationURL != nil &&
            !isDestinationOnScannedDevice &&
            availableSpace >= requiredSpace
    }

    private let scannedDevice: StorageDevice
    private let selectedFiles: [RecoverableFile]
    private let recoveryService: FileRecoveryServicing
    private let directoryPicker: DirectoryPicker
    private let volumeInfoLookup: VolumeInfoLookup

    private let sourceVolumeRootPath: String
    private let sourceVolumeUUID: String?

    init(
        scannedDevice: StorageDevice,
        selectedFiles: [RecoverableFile],
        requiredSpace: Int64? = nil,
        recoveryService: FileRecoveryServicing = FileRecoveryService(),
        directoryPicker: @escaping DirectoryPicker = RecoveryDestinationViewModel.defaultDirectoryPicker,
        volumeInfoLookup: @escaping VolumeInfoLookup = RecoveryDestinationViewModel.defaultVolumeInfo
    ) {
        self.scannedDevice = scannedDevice
        self.selectedFiles = selectedFiles
        self.requiredSpace = requiredSpace ?? selectedFiles.reduce(0) { $0 + max(0, $1.sizeInBytes) }
        self.recoveryService = recoveryService
        self.directoryPicker = directoryPicker
        self.volumeInfoLookup = volumeInfoLookup

        let sourceVolumeInfo = volumeInfoLookup(scannedDevice.volumePath)
        sourceVolumeRootPath = sourceVolumeInfo.volumeRootURL.standardizedFileURL.path
        sourceVolumeUUID = sourceVolumeInfo.volumeUUID ?? scannedDevice.volumeUUID
    }

    /// Opens a folder picker and validates the selected destination.
    func selectDestination() {
        guard let pickedURL = directoryPicker() else { return }
        destinationURL = pickedURL
        didCompleteRecovery = false
        updateAvailableSpace()
    }

    /// Refreshes destination volume free-space and same-device validation.
    func updateAvailableSpace() {
        guard let destinationURL else {
            availableSpace = 0
            isDestinationOnScannedDevice = false
            return
        }

        let destinationInfo = volumeInfoLookup(destinationURL)
        availableSpace = max(0, destinationInfo.availableCapacity)
        isDestinationOnScannedDevice = isOnScannedDevice(destinationInfo: destinationInfo)

        if isDestinationOnScannedDevice {
            errorMessage = RecoveryDestinationError.destinationOnScannedDevice.localizedDescription
        }
    }

    /// Starts file recovery if destination checks pass.
    func startRecovery() async {
        do {
            guard destinationURL != nil else {
                throw RecoveryDestinationError.destinationRequired
            }
            guard !isDestinationOnScannedDevice else {
                throw RecoveryDestinationError.destinationOnScannedDevice
            }
            guard availableSpace >= requiredSpace else {
                throw RecoveryDestinationError.insufficientSpace(required: requiredSpace, available: availableSpace)
            }

            errorMessage = nil
            didCompleteRecovery = false
            isRecovering = true
            defer { isRecovering = false }

            guard let destinationURL else { return }
            try await recoveryService.recover(
                files: selectedFiles,
                from: scannedDevice,
                to: destinationURL
            )
            didCompleteRecovery = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            didCompleteRecovery = false
        }
    }

    private func isOnScannedDevice(destinationInfo: VolumeInfo) -> Bool {
        if let destinationUUID = destinationInfo.volumeUUID,
           let sourceVolumeUUID,
           destinationUUID.caseInsensitiveCompare(sourceVolumeUUID) == .orderedSame
        {
            return true
        }

        let destinationPath = destinationInfo.volumeRootURL.standardizedFileURL.path
        if destinationPath == sourceVolumeRootPath {
            return true
        }

        let sourcePathPrefix = sourceVolumeRootPath.hasSuffix("/") ? sourceVolumeRootPath : sourceVolumeRootPath + "/"
        return destinationPath.hasPrefix(sourcePathPrefix)
    }

    private static func defaultDirectoryPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func defaultVolumeInfo(for url: URL) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]

        let values = try? url.resourceValues(forKeys: keys)
        let volumeUUID = values?.volumeUUIDString
        let availableCapacity: Int64 = if let importantCapacity = values?.volumeAvailableCapacityForImportantUsage {
            Int64(importantCapacity)
        } else if let fallbackCapacity = values?.volumeAvailableCapacity {
            Int64(fallbackCapacity)
        } else {
            0
        }

        return VolumeInfo(
            volumeRootURL: url,
            volumeUUID: volumeUUID,
            availableCapacity: availableCapacity
        )
    }
}
