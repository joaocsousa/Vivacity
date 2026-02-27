import Foundation
import os

/// Handles on-the-fly extraction of `RecoverableFile` objects representing Deep Scan hits to a temporary location for previewing.
protocol LivePreviewServicing: Sendable {
    /// Generates a temporary URL containing the extracted bytes of the given file.
    ///
    /// - Parameters:
    ///   - file: The `RecoverableFile` to extract.
    ///   - reader: The `PrivilegedDiskReading` instance used to read the raw bytes.
    /// - Returns: A temporary `URL` pointing to the extracted data, or `nil` if extraction failed or is unsupported.
    func generatePreviewURL(for file: RecoverableFile, reader: PrivilegedDiskReading) async throws -> URL?
    
    /// Clears any cached preview files.
    func clearCache()
}

actor LivePreviewService: LivePreviewServicing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "LivePreviewService")
    
    // Cache map: File ID -> Temporary URL
    private var cache: [UUID: URL] = [:]
    
    private let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("VivacityLivePreviews", isDirectory: true)
    
    init() {
        createTempDirectory()
    }
    
    private func createTempDirectory() {
        do {
            if !FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
                try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
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
        
        if let cachedURL = cache[file.id], FileManager.default.fileExists(atPath: cachedURL.path) {
            logger.debug("Returning cached preview URL for file \(file.fileName)")
            return cachedURL
        }
        
        let destinationURL = tempDirectoryURL.appendingPathComponent(file.fullFileName)
        
        var extractionError: Error?
        var totalBytesWritten: UInt64 = 0
        
        do {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? fileHandle.close()
            }
            
            let chunkSize = 1024 * 1024 // 1MB chunks
            var currentOffset = file.offsetOnDisk
            let endOffset = file.offsetOnDisk + file.sizeInBytes
            
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            
            while currentOffset < endOffset {
                let bytesToRead = min(UInt64(chunkSize), endOffset - currentOffset)
                let bytesRead = buffer.withUnsafeMutableBytes { buf in
                    reader.read(into: buf.baseAddress!, offset: currentOffset, length: Int(bytesToRead))
                }
                
                guard bytesRead > 0 else {
                    break
                }
                
                let data = Data(bytes: buffer, count: bytesRead)
                try fileHandle.write(contentsOf: data)
                
                currentOffset += UInt64(bytesRead)
                totalBytesWritten += UInt64(bytesRead)
            }
            
            logger.debug("Successfully extracted \(totalBytesWritten) bytes for preview of \(file.fileName)")
            
            if totalBytesWritten > 0 {
                cache[file.id] = destinationURL
                return destinationURL
            } else {
                return nil
            }
            
        } catch {
            extractionError = error
            logger.error("Error extracting preview for \(file.fileName): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
    
    func clearCache() {
        for (_, url) in cache {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeAll()
        logger.debug("Cleared live preview cache.")
    }
}
