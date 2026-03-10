import Foundation
import os

/// Handles on-the-fly extraction of `RecoverableFile` objects representing Deep Scan hits to a temporary location for
/// previewing.
protocol LivePreviewServicing: Sendable {
    /// Generates a temporary URL containing the extracted bytes of the given file.
    ///
    /// - Parameters:
    ///   - file: The `RecoverableFile` to extract.
    ///   - reader: The `PrivilegedDiskReading` instance used to read the raw bytes.
    /// - Returns: A temporary `URL` pointing to the extracted data, or `nil` if extraction failed or is unsupported.
    func generatePreviewURL(for file: RecoverableFile, reader: PrivilegedDiskReading) async throws -> URL?

    /// Clears any cached preview files.
    func clearCache() async
}

actor LivePreviewService: LivePreviewServicing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "LivePreviewService")

    /// Cache map: File ID -> Temporary URL
    private var cache: [UUID: URL] = [:]

    private let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
            "VivacityLivePreviews",
            isDirectory: true
        )

    init() {
        Self.createTempDirectory(at: tempDirectoryURL, logger: logger)
    }

    nonisolated static func createTempDirectory(at url: URL, logger: Logger) {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        } catch {
            logger.error("Failed to create temp directory for live previews: \(error.localizedDescription)")
        }
    }

    func generatePreviewURL(for file: RecoverableFile, reader: PrivilegedDiskReading) async throws -> URL? {
        guard file.source == .deepScan else {
            // Fast scan files already exist on disk, no need to extract.
            return nil
        }
        guard file.sizeInBytes > 0 else {
            logger.debug("Skipping preview extraction for zero-sized deep scan file \(file.fileName)")
            return nil
        }

        if let cachedURL = cache[file.id], FileManager.default.fileExists(atPath: cachedURL.path) {
            let cachedMessage =
                "Returning cached preview URL file=\(file.fileName) path=\(cachedURL.path)"
            logger.debug("\(cachedMessage, privacy: .public)")
            return cachedURL
        }

        let destinationURL = tempDirectoryURL.appendingPathComponent(file.fullFileName)
        let expectedBytes = file.recoveryRanges.reduce(UInt64(0)) { $0 + $1.length }
        let previewStartMessage =
            "Starting preview extraction file=\(file.fullFileName) " +
            "ranges=\(RecoveryByteRanges.rangeSummary(file.recoveryRanges)) " +
            "expectedBytes=\(expectedBytes)"
        logger.debug("\(previewStartMessage, privacy: .public)")

        var totalBytesWritten: UInt64 = 0

        do {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            let destinationMessage =
                "Writing preview extraction file=\(file.fullFileName) outputPath=\(destinationURL.path)"
            logger.debug("\(destinationMessage, privacy: .public)")
            defer {
                try? fileHandle.close()
            }

            totalBytesWritten = try UInt64(
                RecoveryByteRanges.copy(
                    ranges: file.recoveryRanges,
                    from: reader,
                    chunkSize: 1024 * 1024
                ) { chunk in
                    try fileHandle.write(contentsOf: chunk)
                }
            )

            logger.debug("Successfully extracted \(totalBytesWritten) bytes for preview of \(file.fileName)")

            if totalBytesWritten == expectedBytes, totalBytesWritten > 0 {
                cache[file.id] = destinationURL
                return destinationURL
            } else {
                let reason = reader.lastReadFailureDescription ?? "unknown"
                let message =
                    "Preview extraction incomplete for \(file.fileName): expected \(expectedBytes) bytes, " +
                    "got \(totalBytesWritten). Last read failure: \(reason)"
                logger.error("\(message, privacy: .public)")
                try? FileManager.default.removeItem(at: destinationURL)
                let cleanupMessage = "Removed incomplete preview output path=\(destinationURL.path)"
                logger.info("\(cleanupMessage, privacy: .public)")
                return nil
            }

        } catch {
            let failureMessage =
                "Error extracting preview for \(file.fileName): \(error.localizedDescription) " +
                "outputPath=\(destinationURL.path)"
            logger.error("\(failureMessage, privacy: .public)")
            try? FileManager.default.removeItem(at: destinationURL)
            let cleanupMessage = "Removed failed preview output path=\(destinationURL.path)"
            logger.info("\(cleanupMessage, privacy: .public)")
            return nil
        }
    }

    func clearCache() async {
        for (_, url) in cache {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeAll()
        logger.debug("Cleared live preview cache.")
    }
}
