import Foundation

/// A high-level representation of free (unallocated) space on a volume.
struct FreeSpaceRange: Equatable, Sendable {
    /// The physical byte offset where the free space begins
    let startOffset: UInt64
    /// The length of the contiguous free space in bytes
    let length: UInt64
    
    /// The exclusive end offset of the free space
    var endOffset: UInt64 { startOffset + length }
}

/// A protocol for components that can parse a filesystem's allocation table
/// and produce an iterative map of contiguous free space regions.
protocol FreeSpaceMapping: Sendable {
    /// Iterates through all free space ranges on the volume in physical byte order.
    ///
    /// - Returns: An asynchronous sequence of `FreeSpaceRange` objects.
    func freeSpaceRanges() -> AsyncThrowingStream<FreeSpaceRange, Error>
}
