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
                "Try running with elevated privileges or granting Full Disk Access in System Settings."
        case let .cannotReadDevice(path, offset, reason):
            "Cannot read \(path) at offset \(offset): \(reason). " +
                "Check Full Disk Access and retry deep scan."
        }
    }
}
