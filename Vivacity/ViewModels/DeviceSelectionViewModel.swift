import Foundation
import os

/// ViewModel for the device selection screen.
///
/// Loads available storage devices and manages the user's selection.
/// Automatically refreshes when volumes are mounted or unmounted.
@Observable
@MainActor
final class DeviceSelectionViewModel {
    struct HelperFeedbackAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct HelperAttentionCallout: Equatable {
        let title: String
        let message: String
        let symbolName: String
    }

    // MARK: - Published State

    /// All discovered storage devices.
    private(set) var devices: [StorageDevice] = []

    /// The device the user has selected (if any).
    var selectedDevice: StorageDevice?

    /// Sessions available for resuming, keyed by deviceID.
    private(set) var savedSessions: [String: ScanSession] = [:]

    /// Whether a device discovery is in progress.
    private(set) var isLoading = false

    /// Whether a disk image creation is currently in progress.
    private(set) var isCreatingImage = false

    /// Progress of the active disk image creation (0.0 to 1.0).
    private(set) var imageCreationProgress: Double = 0.0

    /// User-facing error message, shown via an alert.
    var errorMessage: String?

    /// One-shot navigation request for a freshly created image-backed scan target.
    private(set) var pendingScanDevice: StorageDevice?

    /// Current privileged helper installation status for the main screen.
    private(set) var helperStatus: PrivilegedHelperStatus = .notInstalled

    /// Optional helper-management feedback presented to the user.
    var helperFeedbackAlert: HelperFeedbackAlert?

    // MARK: - Dependencies

    private let deviceService: DeviceServicing
    private let partitionSearchService: PartitionSearchService
    private let sessionManager: SessionManaging
    private let diskImageService: DiskImageServicing
    private let helperManager: PrivilegedHelperManaging
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeviceSelection")

    // MARK: - Init

    init(
        deviceService: DeviceServicing = DeviceService(),
        partitionSearchService: PartitionSearchService = PartitionSearchService(),
        sessionManager: SessionManaging = SessionManager(),
        diskImageService: DiskImageServicing = DiskImageService(),
        helperManager: PrivilegedHelperManaging = PrivilegedHelperInstallService(
            helperLabel: PrivilegedHelperClient.defaultServiceName
        )
    ) {
        self.deviceService = deviceService
        self.partitionSearchService = partitionSearchService
        self.sessionManager = sessionManager
        self.diskImageService = diskImageService
        self.helperManager = helperManager
    }

    // MARK: - Actions

    func load() async {
        refreshHelperStatus()
        await loadDevices()
    }

    /// Discovers available devices and updates the published state.
    func loadDevices() async {
        isLoading = true
        errorMessage = nil

        do {
            async let fetchDevices = deviceService.discoverDevices()
            async let fetchSessions = sessionManager.loadAll()

            let (discoveredDevices, loadedSessions) = try await (fetchDevices, fetchSessions)

            devices = discoveredDevices

            // Map sessions by device ID
            var sessionMap: [String: ScanSession] = [:]
            for session in loadedSessions {
                // If there are multiple sessions for a device, keep the newest one
                if let existing = sessionMap[session.deviceID] {
                    if session.dateSaved > existing.dateSaved {
                        sessionMap[session.deviceID] = session
                    }
                } else {
                    sessionMap[session.deviceID] = session
                }
            }
            savedSessions = sessionMap

            let count = devices.count
            logger.info("Discovered \(count) device(s) and \(loadedSessions.count) session(s)")

            // Clear selection if the previously selected device is no longer available.
            if let selected = selectedDevice, !self.devices.contains(selected) {
                selectedDevice = nil
            }
        } catch {
            logger.error("Device discovery or session loading failed: \(error.localizedDescription)")
            errorMessage = "Failed to discover devices or sessions: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refreshHelperStatus() {
        helperStatus = helperManager.currentStatus()
        let helperStatusRawValue = helperStatus.rawValue
        logger.info("Main-screen helper status updated to \(helperStatusRawValue, privacy: .public)")
    }

    func clearHelperFeedbackAlert() {
        helperFeedbackAlert = nil
    }

    func installOrUpdateHelper() {
        let statusBefore = helperManager.currentStatus()
        helperStatus = statusBefore

        if statusBefore == .installed {
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Already Installed",
                message: "The recovery helper is already installed and matches this build."
            )
            logger.info("Main-screen helper install skipped because helper is already installed")
            return
        }

        do {
            try helperManager.installIfNeeded()
        } catch {
            helperStatus = helperManager.currentStatus()
            let message = error.localizedDescription
            helperFeedbackAlert = HelperFeedbackAlert(
                title: statusBefore == .updateRequired ? "Helper Reinstall Failed" : "Helper Installation Failed",
                message: message
            )
            logger.error("Main-screen helper install failed: \(message, privacy: .public)")
            return
        }

        let statusAfter = helperManager.currentStatus()
        helperStatus = statusAfter

        switch statusAfter {
        case .installed:
            helperFeedbackAlert = HelperFeedbackAlert(
                title: statusBefore == .updateRequired ? "Helper Reinstalled" : "Helper Installed",
                message: "The recovery helper is ready for full raw-disk scans from the main screen."
            )
            logger.info("Main-screen helper install completed successfully")
        case .updateRequired:
            let message =
                "Vivacity still sees a version mismatch. Reinstall the helper again from this " +
                "screen before running a full physical-disk scan."
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Reinstall Still Required",
                message: message
            )
            logger.error("Main-screen helper install left helper in updateRequired state")
        case .notInstalled:
            let message =
                "Vivacity could not verify the helper installation. Try again before running " +
                "a full physical-disk scan."
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Was Not Installed",
                message: message
            )
            logger.error("Main-screen helper install finished without an installed helper")
        }
    }

    func uninstallHelper() {
        let statusBefore = helperManager.currentStatus()
        helperStatus = statusBefore

        guard statusBefore != .notInstalled else {
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Not Installed",
                message: "There is no recovery helper installed on this Mac."
            )
            logger.info("Main-screen helper uninstall skipped because helper is not installed")
            return
        }

        do {
            try helperManager.uninstallIfInstalled()
        } catch {
            helperStatus = helperManager.currentStatus()
            let message = error.localizedDescription
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Uninstall Failed",
                message: message
            )
            logger.error("Main-screen helper uninstall failed: \(message, privacy: .public)")
            return
        }

        let statusAfter = helperManager.currentStatus()
        helperStatus = statusAfter

        if statusAfter == .notInstalled {
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Uninstalled",
                message: "The recovery helper was removed. Disk images still scan normally, " +
                    "but physical-disk full scans will need it reinstalled."
            )
            logger.info("Main-screen helper uninstall completed successfully")
        } else {
            let message =
                "Vivacity still detects the helper after the uninstall attempt. Remove it " +
                "again before assuming the Mac is back to limited-scan mode."
            helperFeedbackAlert = HelperFeedbackAlert(
                title: "Helper Still Installed",
                message: message
            )
            logger.error("Main-screen helper uninstall left helper in \(statusAfter.rawValue, privacy: .public)")
        }
    }

    var helperStatusTitle: String {
        switch helperStatus {
        case .installed:
            "Recovery Helper Ready"
        case .notInstalled:
            "Recovery Helper Not Installed"
        case .updateRequired:
            "Recovery Helper Reinstall Required"
        }
    }

    var helperStatusMessage: String {
        if let selectedDeviceHelperMessage {
            return selectedDeviceHelperMessage
        }

        switch helperStatus {
        case .installed:
            return "Full raw-disk scans can start immediately from physical devices. " +
                "Disk images never require the helper."
        case .notInstalled:
            return "Install the helper here before running a full physical-disk scan. " +
                "You can still load and scan disk images without it."
        case .updateRequired:
            return "The installed helper does not match this build of Vivacity. Reinstall " +
                "it now before scanning a physical device so the latest privileged code is used."
        }
    }

    var helperPrimaryActionTitle: String? {
        switch helperStatus {
        case .installed:
            nil
        case .notInstalled:
            "Install Helper"
        case .updateRequired:
            "Reinstall Helper"
        }
    }

    var helperShowsDestructiveAction: Bool {
        helperStatus != .notInstalled
    }

    var helperNeedsAttention: Bool {
        helperStatus != .installed
    }

    var helperAttentionCallout: HelperAttentionCallout? {
        if selectedDeviceRequiresHelper {
            let deviceName = selectedDevice?.name ?? "this physical device"
            switch helperStatus {
            case .installed:
                break
            case .notInstalled:
                return HelperAttentionCallout(
                    title: "Install the Helper Before Scanning",
                    message: "Install the recovery helper before scanning \(deviceName). " +
                        "Disk images can still be scanned without it.",
                    symbolName: "lock.shield.fill"
                )
            case .updateRequired:
                return HelperAttentionCallout(
                    title: "Version Mismatch Detected",
                    message: "The installed helper does not match this build of Vivacity. " +
                        "Reinstall it before scanning \(deviceName).",
                    symbolName: "exclamationmark.triangle.fill"
                )
            }
        }

        if helperStatus == .updateRequired {
            return HelperAttentionCallout(
                title: "Version Mismatch Detected",
                message: "Reinstall the recovery helper from this screen before starting any physical-disk scan.",
                symbolName: "exclamationmark.triangle.fill"
            )
        }

        return nil
    }

    var selectedDeviceRequiresHelper: Bool {
        guard let selectedDevice else { return false }
        return requiresHelperForPhysicalScan(selectedDevice)
    }

    var selectedDeviceHelperActionTitle: String? {
        guard selectedDeviceRequiresHelper else { return nil }
        return helperPrimaryActionTitle
    }

    private var selectedDeviceHelperMessage: String? {
        guard selectedDeviceRequiresHelper, let selectedDevice else { return nil }

        switch helperStatus {
        case .installed:
            return nil
        case .notInstalled:
            return "Install the helper from this screen before scanning \(selectedDevice.name). " +
                "Disk images still work without it."
        case .updateRequired:
            return "The installed helper does not match this build of Vivacity. Reinstall it " +
                "here before scanning \(selectedDevice.name)."
        }
    }

    private func requiresHelperForPhysicalScan(_ device: StorageDevice) -> Bool {
        !device.isDiskImage && helperStatus != .installed
    }

    /// Deletes the saved session for the given device ID.
    func deleteSession(forDeviceID deviceID: String) async {
        guard let session = savedSessions[deviceID] else { return }
        do {
            try await sessionManager.deleteSession(id: session.id)
            savedSessions.removeValue(forKey: deviceID)
        } catch {
            logger.error("Failed to delete session: \(error.localizedDescription)")
            errorMessage = "Failed to delete old session."
        }
    }

    /// Observes volume mount/unmount events and refreshes the device list automatically.
    ///
    /// Call this from a `.task {}` modifier — it runs for the lifetime of the task.
    func observeVolumeChanges() async {
        for await _ in deviceService.volumeChanges() {
            logger.info("Volume change detected, refreshing device list")
            // Add a small delay so macOS can clean up unmounted paths before we read them
            try? await Task.sleep(nanoseconds: 500_000_000)
            await loadDevices()
        }
    }

    /// Scans the physical disk backing the given device for lost partitions.
    func searchForLostPartitions(on device: StorageDevice) async {
        isLoading = true
        errorMessage = nil

        do {
            let volumeInfo = VolumeInfo.detect(for: device)
            var physicalDevicePath = volumeInfo.devicePath

            // Extract the whole disk path (e.g. `/dev/rdisk4` from `/dev/rdisk4s1`)
            let deviceRegex = try NSRegularExpression(pattern: "^(/dev/r?disk\\d+)")
            let range = NSRange(physicalDevicePath.startIndex ..< physicalDevicePath.endIndex, in: physicalDevicePath)
            if let match = deviceRegex.firstMatch(in: physicalDevicePath, options: [], range: range) {
                if let swiftRange = Range(match.range(at: 1), in: physicalDevicePath) {
                    physicalDevicePath = String(physicalDevicePath[swiftRange])
                }
            }

            logger.info("Starting partition search on physical device: \(physicalDevicePath)")

            let reader = PrivilegedDiskReader(devicePath: physicalDevicePath)
            let newPartitions = try await partitionSearchService.findPartitions(on: physicalDevicePath, reader: reader)

            // Add virtual partitions to the list, removing any old ones for this path just in case
            devices.removeAll { $0.id.starts(with: physicalDevicePath + "-part-") }
            devices.append(contentsOf: newPartitions)

            if newPartitions.isEmpty {
                errorMessage = "No lost partitions found on this disk."
            }

        } catch {
            logger.error("Partition search failed: \(error.localizedDescription)")
            errorMessage = "Failed to search for partitions: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Disk Imaging

    /// Loads an existing disk image file (.dd, .dmg, etc.) as a StorageDevice.
    @discardableResult
    func loadDiskImage(at url: URL) -> StorageDevice {
        let imageDevice = DiskImageDeviceLoader.makeStorageDevice(from: url)
        if imageDevice.totalCapacity == 0 {
            logger.warning("Could not determine size for disk image at \(url.path)")
        }

        // Prevent duplicates
        devices.removeAll { $0.id == imageDevice.id }

        // Add to the top of the list for visibility
        devices.insert(imageDevice, at: 0)
        selectedDevice = imageDevice

        logger.info("Loaded disk image: \(imageDevice.name) (\(imageDevice.formattedTotal))")
        return imageDevice
    }

    /// Loads an existing disk image and queues immediate navigation into scanning it.
    @discardableResult
    func loadDiskImageAndQueueScan(at url: URL) -> StorageDevice {
        let imageDevice = loadDiskImage(at: url)
        pendingScanDevice = imageDevice
        return imageDevice
    }

    /// Initiates a byte-to-byte copy of the selected device to the destination URL.
    @discardableResult
    func createImage(for device: StorageDevice, to url: URL) async -> StorageDevice? {
        guard !isCreatingImage else { return nil }

        isCreatingImage = true
        imageCreationProgress = 0.0
        errorMessage = nil
        pendingScanDevice = nil
        defer {
            isCreatingImage = false
            imageCreationProgress = 0.0
        }

        do {
            logger.info("Starting disk image creation for \(device.name) to \(url.path)")
            let stream = diskImageService.createImage(from: device, to: url)

            for try await progress in stream {
                imageCreationProgress = progress
            }

            logger.info("Successfully created disk image for \(device.name)")
            let imageDevice = loadDiskImage(at: url)
            pendingScanDevice = imageDevice
            return imageDevice
        } catch {
            logger.error("Failed to create disk image: \(error.localizedDescription)")
            errorMessage = "Failed to create disk image: \(error.localizedDescription)"
        }
        return nil
    }

    func consumePendingScanDevice() -> StorageDevice? {
        defer { pendingScanDevice = nil }
        return pendingScanDevice
    }
}
