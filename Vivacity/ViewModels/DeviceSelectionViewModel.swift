import Foundation
import os

/// ViewModel for the device selection screen.
///
/// Loads available storage devices and manages the user's selection.
@Observable
@MainActor
final class DeviceSelectionViewModel {

    // MARK: - Published State

    /// All discovered storage devices.
    private(set) var devices: [StorageDevice] = []

    /// The device the user has selected (if any).
    var selectedDevice: StorageDevice?

    /// Whether a device discovery is in progress.
    private(set) var isLoading = false

    /// User-facing error message, shown via an alert.
    var errorMessage: String?

    // MARK: - Dependencies

    private let deviceService: DeviceService
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeviceSelection")

    // MARK: - Init

    init(deviceService: DeviceService = DeviceService()) {
        self.deviceService = deviceService
    }

    // MARK: - Actions

    /// Discovers available devices and updates the published state.
    func loadDevices() async {
        isLoading = true
        errorMessage = nil

        do {
            devices = try await deviceService.discoverDevices()
            logger.info("Discovered \(self.devices.count) device(s)")
        } catch {
            logger.error("Device discovery failed: \(error.localizedDescription)")
            errorMessage = "Failed to discover devices: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
