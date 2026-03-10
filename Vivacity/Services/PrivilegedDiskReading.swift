import Foundation

/// A protocol for accessing block devices, which enables dependency injection for testing.
protocol PrivilegedDiskReading: Sendable {
    /// Whether the reader currently supports random access.
    var isSeekable: Bool { get }

    /// Diagnostic for the most recent read failure, if available.
    var lastReadFailureDescription: String? { get }

    /// Opens the device for reading.
    func start() throws

    /// Reads up to `length` bytes from the given offset into `buffer`.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int

    /// Stops the reader and closes file descriptors.
    func stop()
}

extension PrivilegedDiskReading {
    var lastReadFailureDescription: String? {
        nil
    }
}

/// Errors specific to the deep scan process.
enum DeepScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)
    case cannotReadDevice(path: String, offset: UInt64, reason: String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path) for scanning: \(reason). " +
                guidance(for: reason, isOpenFailure: true)
        case let .cannotReadDevice(path, offset, reason):
            "Cannot read \(path) at offset \(offset): \(reason). " +
                guidance(for: reason, isOpenFailure: false)
        }
    }

    private func guidance(for reason: String, isOpenFailure: Bool) -> String {
        let normalizedReason = reason.lowercased()

        if normalizedReason.contains("operation not permitted") {
            return "macOS denied raw disk access to this device. " +
                "If this is the startup volume, retry from another boot volume or create a disk image first."
        }

        if isOpenFailure {
            return "Try running with elevated privileges or granting Full Disk Access in System Settings."
        }

        return "Check Full Disk Access and retry deep scan."
    }
}
