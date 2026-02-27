import Foundation
import os

/// ViewModel for the device selection screen.
///
/// Loads available storage devices and manages the user's selection.
/// Automatically refreshes when volumes are mounted or unmounted.
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

    private let deviceService: DeviceServicing
    private let partitionSearchService: PartitionSearchService
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeviceSelection")

    // MARK: - Init

    init(deviceService: DeviceServicing = DeviceService(),
         partitionSearchService: PartitionSearchService = PartitionSearchService()) {
        self.deviceService = deviceService
        self.partitionSearchService = partitionSearchService
    }

    // MARK: - Actions

    /// Discovers available devices and updates the published state.
    func loadDevices() async {
        isLoading = true
        errorMessage = nil

        do {
            devices = try await deviceService.discoverDevices()
            let count = devices.count
            logger.info("Discovered \(count) device(s)")

            // Clear selection if the previously selected device is no longer available.
            if let selected = selectedDevice, !self.devices.contains(selected) {
                selectedDevice = nil
            }
        } catch {
            logger.error("Device discovery failed: \(error.localizedDescription)")
            errorMessage = "Failed to discover devices: \(error.localizedDescription)"
        }

        isLoading = false
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
            let range = NSRange(physicalDevicePath.startIndex..<physicalDevicePath.endIndex, in: physicalDevicePath)
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
}
