import Darwin
import Foundation
import os

/// API for recovering selected files to a destination folder.
protocol FileRecoveryServicing: Sendable {
    /// Recovers selected files from a scanned device to a destination folder.
    func recover(files: [RecoverableFile], from sourceDevice: StorageDevice, to destinationURL: URL) async throws
}

/// Per-file error captured during a batch recovery operation.
struct FileRecoveryFailure: Sendable {
    let file: RecoverableFile
    let errorDescription: String
}

/// Completion summary for a batch recovery operation.
struct FileRecoveryResult: Sendable {
    let recoveredFiles: [URL]
    let failures: [FileRecoveryFailure]
}

/// Progress payload emitted while recovering files.
struct FileRecoveryProgress: Sendable {
    let completedFiles: Int
    let totalFiles: Int
    let recoveredBytes: Int64
    let totalBytes: Int64
    let currentFileName: String?
    let isFinished: Bool

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return totalFiles > 0 ? 0 : 1 }
        return min(1, max(0, Double(recoveredBytes) / Double(totalBytes)))
    }
}

/// Recovers files by reading raw bytes from the scanned device and writing each file to a destination directory.
struct FileRecoveryService: FileRecoveryServicing {
    typealias ProgressHandler = @Sendable (FileRecoveryProgress) -> Void

    private struct RecoveryState {
        var completedFiles: Int
        var recoveredBytes: Int64
        let totalFiles: Int
        let totalBytes: Int64
    }

    private let logger = Logger(subsystem: "com.vivacity.app", category: "FileRecovery")
    private let diskReaderFactory: @Sendable (String) -> any PrivilegedDiskReading

    init(
        diskReaderFactory: @escaping @Sendable (String)
            -> any PrivilegedDiskReading = { devicePath in
                if devicePath.hasPrefix("/dev/") {
                    return PrivilegedDiskReader(devicePath: devicePath)
                }
                return RegularFileDiskReader(filePath: devicePath)
            }
    ) {
        self.diskReaderFactory = diskReaderFactory
    }

    func recover(files: [RecoverableFile], from sourceDevice: StorageDevice, to destinationURL: URL) async throws {
        _ = try await recover(
            files: files,
            from: sourceDevice,
            to: destinationURL,
            progressHandler: { _ in }
        )
    }

    /// Recovers files and emits progress updates as bytes and files complete.
    func recover(
        files: [RecoverableFile],
        from sourceDevice: StorageDevice,
        to destinationURL: URL,
        progressHandler: @escaping ProgressHandler
    ) async throws -> FileRecoveryResult {
        try Task.checkCancellation()
        try ensureDestinationDirectory(at: destinationURL)

        let volumeInfo = VolumeInfo.detect(for: sourceDevice)
        let reader = diskReaderFactory(volumeInfo.devicePath)
        let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.sizeInBytes) }

        var state = RecoveryState(
            completedFiles: 0,
            recoveredBytes: 0,
            totalFiles: files.count,
            totalBytes: totalBytes
        )
        var recoveredFiles: [URL] = []
        var failures: [FileRecoveryFailure] = []

        progressHandler(
            FileRecoveryProgress(
                completedFiles: state.completedFiles,
                totalFiles: state.totalFiles,
                recoveredBytes: state.recoveredBytes,
                totalBytes: state.totalBytes,
                currentFileName: nil,
                isFinished: files.isEmpty
            )
        )

        do {
            try reader.start()
            defer { reader.stop() }

            for file in files {
                try Task.checkCancellation()

                do {
                    let writtenURL = try recoverSingleFile(
                        file,
                        reader: reader,
                        destinationDirectory: destinationURL,
                        state: &state,
                        progressHandler: progressHandler
                    )

                    recoveredFiles.append(writtenURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    logger.error("Failed to recover \(file.fullFileName): \(description)")
                    failures.append(FileRecoveryFailure(file: file, errorDescription: description))
                }

                state.completedFiles += 1
                progressHandler(
                    FileRecoveryProgress(
                        completedFiles: state.completedFiles,
                        totalFiles: state.totalFiles,
                        recoveredBytes: state.recoveredBytes,
                        totalBytes: state.totalBytes,
                        currentFileName: nil,
                        isFinished: state.completedFiles == state.totalFiles
                    )
                )
            }
        } catch {
            throw error
        }

        return FileRecoveryResult(recoveredFiles: recoveredFiles, failures: failures)
    }

    private func recoverSingleFile(
        _ file: RecoverableFile,
        reader: PrivilegedDiskReading,
        destinationDirectory: URL,
        state: inout RecoveryState,
        progressHandler: @escaping ProgressHandler
    ) throws -> URL {
        guard file.sizeInBytes > 0 else {
            throw FileRecoveryError.invalidFileSize(file.fullFileName)
        }

        let preferredName = inferPreferredOutputName(for: file, reader: reader)
        let destinationURL = uniqueFileURL(
            in: destinationDirectory,
            preferredName: preferredName,
            fileExtension: file.fileExtension
        )
        _ = FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)

        var fileRecoveredBytes: Int64 = 0
        defer {
            try? outputHandle.close()
        }

        let chunkSize = 1024 * 1024
        var remainingBytes = UInt64(file.sizeInBytes)
        var readOffset = file.offsetOnDisk
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while remainingBytes > 0 {
            try Task.checkCancellation()

            let bytesToRead = min(UInt64(chunkSize), remainingBytes)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                reader.read(
                    into: rawBuffer.baseAddress!,
                    offset: readOffset,
                    length: Int(bytesToRead)
                )
            }

            guard bytesRead > 0 else {
                throw FileRecoveryError.unexpectedEndOfInput(file.fullFileName)
            }

            try outputHandle.write(contentsOf: Data(buffer[..<bytesRead]))

            let recoveredChunkBytes = Int64(bytesRead)
            fileRecoveredBytes += recoveredChunkBytes
            state.recoveredBytes += recoveredChunkBytes
            readOffset += UInt64(bytesRead)
            remainingBytes -= UInt64(bytesRead)

            progressHandler(
                FileRecoveryProgress(
                    completedFiles: state.completedFiles,
                    totalFiles: state.totalFiles,
                    recoveredBytes: state.recoveredBytes,
                    totalBytes: state.totalBytes,
                    currentFileName: file.fullFileName,
                    isFinished: false
                )
            )
        }

        logger.info("Recovered \(file.fullFileName) (\(fileRecoveredBytes) bytes)")
        return destinationURL
    }

    /// Attempts to build a richer output name using capture metadata from partial media bytes.
    /// Falls back to the scanned file name when metadata cannot be extracted.
    private func inferPreferredOutputName(for file: RecoverableFile, reader: PrivilegedDiskReading) -> String {
        let sampleBytes = readHeadSample(
            from: reader,
            offset: file.offsetOnDisk,
            fileSize: file.sizeInBytes
        )
        guard
            let metadata = EXIFDateExtractor.extractMetadata(from: sampleBytes),
            let richName = buildMetadataDrivenName(from: metadata)
        else {
            return file.fileName
        }
        return richName
    }

    private func buildMetadataDrivenName(from metadata: EXIFDateExtractor.CaptureMetadata) -> String? {
        var parts: [String] = []
        if let capture = metadata.captureTimeToken {
            parts.append(capture)
        }
        if let device = metadata.deviceToken {
            parts.append(device)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "_")
    }

    private func readHeadSample(from reader: PrivilegedDiskReading, offset: UInt64, fileSize: Int64) -> [UInt8] {
        guard fileSize > 0 else { return [] }
        let sampleLength = min(Int(fileSize), 128 * 1024)
        guard sampleLength > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: sampleLength)
        let readBytes = buffer.withUnsafeMutableBytes { rawBuffer in
            reader.read(
                into: rawBuffer.baseAddress!,
                offset: offset,
                length: sampleLength
            )
        }

        guard readBytes > 0 else { return [] }
        return Array(buffer.prefix(readBytes))
    }

    private func ensureDestinationDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists {
            guard isDirectory.boolValue else {
                throw FileRecoveryError.destinationNotDirectory(url.path)
            }
            return
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func uniqueFileURL(
        in directoryURL: URL,
        preferredName: String,
        fileExtension: String
    ) -> URL {
        var candidateName = "\(preferredName).\(fileExtension)"
        var candidateURL = directoryURL.appendingPathComponent(candidateName)
        var duplicateIndex = 1

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateName = "\(preferredName) (\(duplicateIndex)).\(fileExtension)"
            candidateURL = directoryURL.appendingPathComponent(candidateName)
            duplicateIndex += 1
        }

        return candidateURL
    }
}

private enum FileRecoveryError: LocalizedError {
    case destinationNotDirectory(String)
    case invalidFileSize(String)
    case unexpectedEndOfInput(String)

    var errorDescription: String? {
        switch self {
        case let .destinationNotDirectory(path):
            "Destination is not a directory: \(path)"
        case let .invalidFileSize(fileName):
            "Cannot recover \(fileName): size must be greater than zero."
        case let .unexpectedEndOfInput(fileName):
            "Cannot recover \(fileName): source data ended unexpectedly."
        }
    }
}

/// File-based implementation of `PrivilegedDiskReading` used for local disk image files.
private final class RegularFileDiskReader: PrivilegedDiskReading, @unchecked Sendable {
    private let filePath: String
    private var fd: Int32 = -1

    init(filePath: String) {
        self.filePath = filePath
    }

    deinit {
        stop()
    }

    var isSeekable: Bool {
        fd >= 0
    }

    func start() throws {
        let newFD = open(filePath, O_RDONLY)
        if newFD < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fd = newFD
    }

    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard fd >= 0 else { return -1 }
        return pread(fd, buffer, length, off_t(offset))
    }

    func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}
