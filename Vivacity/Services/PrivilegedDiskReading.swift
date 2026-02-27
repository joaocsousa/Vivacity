import Foundation

/// A protocol for accessing block devices, which enables dependency injection for testing.
protocol PrivilegedDiskReading: Sendable {
    /// Whether the reader currently supports random access.
    var isSeekable: Bool { get }

    /// Opens the device for reading.
    func start() throws

    /// Reads up to `length` bytes from the given offset into `buffer`.
    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int

    /// Stops the reader and closes file descriptors.
    func stop()
}
