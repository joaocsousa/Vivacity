import CryptoKit
import Darwin
import Foundation
import os

/// API for recovering selected files to a destination folder.
protocol FileRecoveryServicing: Sendable {
    /// Recovers selected files from a scanned device to a destination folder.
    func recover(
        files: [RecoverableFile],
        from sourceDevice: StorageDevice,
        to destinationURL: URL
    ) async throws -> FileRecoveryResult
}

/// API for pre-recovery sample verification to detect unreadable or unstable sectors.
protocol FileSampleVerifying: Sendable {
    /// Verifies selected files by hashing head/tail samples twice and comparing snapshots.
    func verifySamples(files: [RecoverableFile], from sourceDevice: StorageDevice) async throws
        -> [FileSampleVerification]
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

enum FileSampleVerificationStatus: Sendable, Equatable {
    case verified
    case mismatch
    case unreadable
}

struct FileSampleVerification: Sendable {
    let file: RecoverableFile
    let status: FileSampleVerificationStatus
    let headHash: String?
    let tailHash: String?
    let failureReason: String?

    init(
        file: RecoverableFile,
        status: FileSampleVerificationStatus,
        headHash: String?,
        tailHash: String?,
        failureReason: String? = nil
    ) {
        self.file = file
        self.status = status
        self.headHash = headHash
        self.tailHash = tailHash
        self.failureReason = failureReason
    }
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
struct FileRecoveryService: FileRecoveryServicing, FileSampleVerifying {
    typealias ProgressHandler = @Sendable (FileRecoveryProgress) -> Void

    struct RecoveryState {
        var completedFiles: Int
        var recoveredBytes: Int64
        let totalFiles: Int
        let totalBytes: Int64
    }

    let logger = Logger(subsystem: "com.vivacity.app", category: "FileRecovery")
    private let diskReaderFactory: @Sendable (String) -> any PrivilegedDiskReading

    init(
        diskReaderFactory: @escaping @Sendable (String)
            -> any PrivilegedDiskReading = { DiskReaderFactoryProvider.makeReader(forPath: $0) }
    ) {
        self.diskReaderFactory = diskReaderFactory
    }

    func recover(
        files: [RecoverableFile],
        from sourceDevice: StorageDevice,
        to destinationURL: URL
    ) async throws -> FileRecoveryResult {
        try await recover(
            files: files,
            from: sourceDevice,
            to: destinationURL,
            progressHandler: { _ in }
        )
    }

    func verifySamples(
        files: [RecoverableFile],
        from sourceDevice: StorageDevice
    ) async throws -> [FileSampleVerification] {
        let volumeInfo = VolumeInfo.detect(for: sourceDevice)
        let reader = diskReaderFactory(volumeInfo.devicePath)
        let readerType = String(describing: type(of: reader))
        let verificationStartMessage =
            "Starting sample verification device=\(volumeInfo.devicePath) " +
            "reader=\(readerType) fileCount=\(files.count)"
        logger.info("\(verificationStartMessage, privacy: .public)")
        try startReader(
            reader,
            devicePath: volumeInfo.devicePath,
            readerType: readerType,
            context: "sample verification"
        )
        defer {
            stopReader(
                reader,
                devicePath: volumeInfo.devicePath,
                readerType: readerType,
                context: "sample verification"
            )
        }

        let results = files.map { file in
            verifySample(file, reader: reader)
        }
        let verifiedCount = results.filter { $0.status == .verified }.count
        let mismatchCount = results.filter { $0.status == .mismatch }.count
        let unreadableCount = results.filter { $0.status == .unreadable }.count
        let verificationEndMessage =
            "Completed sample verification device=\(volumeInfo.devicePath) " +
            "verified=\(verifiedCount) mismatch=\(mismatchCount) unreadable=\(unreadableCount)"
        logger.info("\(verificationEndMessage, privacy: .public)")
        return results
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
        let readerType = String(describing: type(of: reader))
        let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.sizeInBytes) }
        let recoveryStartMessage =
            "Starting recovery batch device=\(volumeInfo.devicePath) " +
            "destination=\(destinationURL.path) reader=\(readerType) " +
            "fileCount=\(files.count) totalBytes=\(totalBytes)"
        logger.info("\(recoveryStartMessage, privacy: .public)")

        var state = RecoveryState(
            completedFiles: 0,
            recoveredBytes: 0,
            totalFiles: files.count,
            totalBytes: totalBytes
        )
        var recoveredFiles: [URL] = []
        var failures: [FileRecoveryFailure] = []

        progressHandler(
            makeProgress(
                state: state,
                currentFileName: nil,
                isFinished: files.isEmpty
            )
        )

        try startReader(reader, devicePath: volumeInfo.devicePath, readerType: readerType, context: "recovery")
        defer {
            stopReader(reader, devicePath: volumeInfo.devicePath, readerType: readerType, context: "recovery")
        }

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
                recordRecoveryFailure(
                    error,
                    for: file,
                    destinationURL: destinationURL,
                    failures: &failures
                )
            }

            state.completedFiles += 1
            progressHandler(
                makeProgress(
                    state: state,
                    currentFileName: nil,
                    isFinished: state.completedFiles == state.totalFiles
                )
            )
        }

        let recoveryEndMessage =
            "Finished recovery batch destination=\(destinationURL.path) " +
            "recoveredFiles=\(recoveredFiles.count) failures=\(failures.count) " +
            "recoveredBytes=\(state.recoveredBytes)"
        logger.info("\(recoveryEndMessage, privacy: .public)")
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
        let recoveryRanges = file.recoveryRanges
        let expectedBytes = Int64(recoveryRanges.reduce(UInt64(0)) { $0 + $1.length })
        guard expectedBytes > 0 else {
            throw FileRecoveryError.invalidFileSize(file.fullFileName)
        }
        let fileRecoveryMessage =
            "Starting file recovery file=\(file.fullFileName) " +
            "expectedBytes=\(expectedBytes) ranges=\(RecoveryByteRanges.rangeSummary(recoveryRanges))"
        logger.info("\(fileRecoveryMessage, privacy: .public)")

        let preferredName = inferPreferredOutputName(for: file, reader: reader)
        let (destinationURL, outputHandle) = try prepareOutputFile(
            for: file,
            preferredName: preferredName,
            destinationDirectory: destinationDirectory
        )

        var shouldRemoveOutputFile = true
        var fileRecoveredBytes: Int64 = 0
        defer {
            try? outputHandle.close()
            if shouldRemoveOutputFile {
                cleanupIncompleteOutputFile(at: destinationURL)
            }
        }

        let chunkSize = 1024 * 1024
        let bytesRecovered = try RecoveryByteRanges.copy(
            ranges: recoveryRanges,
            from: reader,
            chunkSize: chunkSize
        ) { chunk in
            try Task.checkCancellation()
            try outputHandle.write(contentsOf: chunk)
            let recoveredChunkBytes = Int64(chunk.count)
            fileRecoveredBytes += recoveredChunkBytes
            state.recoveredBytes += recoveredChunkBytes
            progressHandler(makeProgress(state: state, currentFileName: file.fullFileName, isFinished: false))
        }

        guard bytesRecovered == expectedBytes else {
            let mismatchMessage =
                "Recovery byte count mismatch file=\(file.fullFileName) " +
                "expectedBytes=\(expectedBytes) recoveredBytes=\(bytesRecovered) " +
                "lastReadFailure=\(reader.lastReadFailureDescription ?? "none")"
            logger.error("\(mismatchMessage, privacy: .public)")
            throw FileRecoveryError.unexpectedEndOfInput(
                file.fullFileName,
                reader.lastReadFailureDescription
            )
        }

        shouldRemoveOutputFile = false
        logger.info("Recovered \(file.fullFileName) (\(fileRecoveredBytes) bytes)")
        return destinationURL
    }
}

enum FileRecoveryError: LocalizedError {
    case cannotCreateDestination(String)
    case destinationNotDirectory(String)
    case invalidFileSize(String)
    case unexpectedEndOfInput(String, String?)

    var errorDescription: String? {
        switch self {
        case let .cannotCreateDestination(path):
            return "Cannot create destination file at \(path)."
        case let .destinationNotDirectory(path):
            return "Destination is not a directory: \(path)"
        case let .invalidFileSize(fileName):
            return "Cannot recover \(fileName): size must be greater than zero."
        case let .unexpectedEndOfInput(fileName, reason):
            if let reason, !reason.isEmpty {
                return "Cannot recover \(fileName): source data ended unexpectedly. Last read failure: \(reason)."
            }
            return "Cannot recover \(fileName): source data ended unexpectedly."
        }
    }
}
