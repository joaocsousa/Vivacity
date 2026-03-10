import Foundation
import os

/// Service responsible for creating a byte-to-byte raw disk image (.dd) of a storage device.
protocol DiskImageServicing: Sendable {
    /// Creates a raw disk image of the given device at the specified destination URL.
    ///
    /// - Parameters:
    ///   - device: The storage device to image.
    ///   - destinationURL: The local file URL where the image should be saved.
    /// - Returns: An AsyncThrowingStream that yields progress as a Double between 0.0 and 1.0.
    func createImage(from device: StorageDevice, to destinationURL: URL) -> AsyncThrowingStream<Double, Error>
}

struct DiskImageService: DiskImageServicing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DiskImageService")

    /// Read in 1MB chunks for performance
    private let chunkSize = 1024 * 1024

    /// For testing dependency injection
    private let injectedReader: PrivilegedDiskReading?

    init(diskReader: PrivilegedDiskReading? = nil) {
        injectedReader = diskReader
    }

    func createImage(from device: StorageDevice, to destinationURL: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let volumeInfo = VolumeInfo.detect(for: device)
                let totalBytes = device.partitionSize ?? device.totalCapacity

                guard totalBytes > 0 else {
                    logger.error("Cannot create image of device with unknown size: \(device.name)")
                    continuation.finish(throwing: NSError(
                        domain: "DiskImageServiceError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Device capacity is unknown or 0."]
                    ))
                    return
                }

                let fileHandle: FileHandle
                do {
                    fileHandle = try prepareDestinationFile(at: destinationURL)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer { try? fileHandle.close() }

                let activeReader = injectedReader ?? DiskReaderFactoryProvider
                    .makeReader(forPath: volumeInfo.devicePath)

                do {
                    try activeReader.start()

                    let partitionOffset = device.partitionOffset ?? 0
                    let totalRead = try copyDeviceBytes(
                        reader: activeReader,
                        fileHandle: fileHandle,
                        startOffset: partitionOffset,
                        totalBytes: totalBytes,
                        continuation: continuation
                    )

                    if Task.isCancelled {
                        logger.info("Image creation cancelled for \(device.name)")
                        // Attempt to clean up the partially written file
                        try? fileHandle.close()
                        try? FileManager.default.removeItem(at: destinationURL)
                    } else {
                        logger.info("Image creation finished for \(device.name). Copied \(totalRead) bytes.")
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                activeReader.stop()
            }

            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    private func prepareDestinationFile(at destinationURL: URL) throws -> FileHandle {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil) else {
            logger.error("Failed to create destination file at \(destinationURL.path)")
            throw diskImageError(code: 2, description: "Failed to create destination file.")
        }

        do {
            return try FileHandle(forWritingTo: destinationURL)
        } catch {
            logger.error("Failed to open destination file for writing at \(destinationURL.path)")
            throw diskImageError(code: 3, description: "Failed to open destination file for writing.")
        }
    }

    private func copyDeviceBytes(
        reader: PrivilegedDiskReading,
        fileHandle: FileHandle,
        startOffset: UInt64,
        totalBytes: Int64,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) throws -> UInt64 {
        var currentOffset = startOffset
        let endOffset = startOffset + UInt64(totalBytes)
        var totalRead: UInt64 = 0

        while currentOffset < endOffset, !Task.isCancelled {
            let remaining = endOffset - currentOffset
            let bytesToRead = min(Int(remaining), chunkSize)

            var data = Data(count: bytesToRead)
            let bytesRead = data.withUnsafeMutableBytes { rawBuffer in
                reader.read(
                    into: rawBuffer.baseAddress!,
                    offset: currentOffset,
                    length: bytesToRead
                )
            }

            if bytesRead <= 0 {
                logger.warning("Short read or end of device reached at offset \(currentOffset)")
                break
            }

            try fileHandle.seekToEnd()
            fileHandle.write(data.prefix(upTo: bytesRead))

            currentOffset += UInt64(bytesRead)
            totalRead += UInt64(bytesRead)
            continuation.yield(Double(totalRead) / Double(totalBytes))
        }

        return totalRead
    }

    private func diskImageError(code: Int, description: String) -> NSError {
        NSError(
            domain: "DiskImageServiceError",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
