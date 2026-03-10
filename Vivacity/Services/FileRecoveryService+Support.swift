import CryptoKit
import Foundation

extension FileRecoveryService {
    func startReader(
        _ reader: PrivilegedDiskReading,
        devicePath: String,
        readerType: String,
        context: String
    ) throws {
        do {
            try reader.start()
            let startMessage =
                "\(context.capitalized) reader started device=\(devicePath) reader=\(readerType)"
            logger.info("\(startMessage, privacy: .public)")
        } catch {
            let failureMessage =
                "Failed to start \(context) reader device=\(devicePath) " +
                "reader=\(readerType) reason=\(error.localizedDescription)"
            logger.error("\(failureMessage, privacy: .public)")
            throw error
        }
    }

    func stopReader(
        _ reader: PrivilegedDiskReading,
        devicePath: String,
        readerType: String,
        context: String
    ) {
        let stopMessage =
            "Stopping \(context) reader device=\(devicePath) reader=\(readerType)"
        logger.info("\(stopMessage, privacy: .public)")
        reader.stop()
    }

    func makeProgress(
        state: RecoveryState,
        currentFileName: String?,
        isFinished: Bool
    ) -> FileRecoveryProgress {
        FileRecoveryProgress(
            completedFiles: state.completedFiles,
            totalFiles: state.totalFiles,
            recoveredBytes: state.recoveredBytes,
            totalBytes: state.totalBytes,
            currentFileName: currentFileName,
            isFinished: isFinished
        )
    }

    func recordRecoveryFailure(
        _ error: Error,
        for file: RecoverableFile,
        destinationURL: URL,
        failures: inout [FileRecoveryFailure]
    ) {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let failureMessage =
            "Failed to recover file=\(file.fullFileName) " +
            "destination=\(destinationURL.path) reason=\(description)"
        logger.error("\(failureMessage, privacy: .public)")
        failures.append(FileRecoveryFailure(file: file, errorDescription: description))
    }

    func prepareOutputFile(
        for file: RecoverableFile,
        preferredName: String,
        destinationDirectory: URL
    ) throws -> (destinationURL: URL, outputHandle: FileHandle) {
        let destinationURL = uniqueFileURL(
            in: destinationDirectory,
            preferredName: preferredName,
            fileExtension: file.fileExtension
        )
        let destinationMessage =
            "Resolved recovery destination file=\(file.fullFileName) " +
            "preferredName=\(preferredName) outputPath=\(destinationURL.path)"
        logger.debug("\(destinationMessage, privacy: .public)")
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil) else {
            let createFailureMessage =
                "Failed to create recovery output placeholder path=\(destinationURL.path)"
            logger.error("\(createFailureMessage, privacy: .public)")
            throw FileRecoveryError.cannotCreateDestination(destinationURL.path)
        }

        return try (destinationURL, FileHandle(forWritingTo: destinationURL))
    }

    func cleanupIncompleteOutputFile(at destinationURL: URL) {
        do {
            try FileManager.default.removeItem(at: destinationURL)
            let cleanupMessage =
                "Removed incomplete recovery output path=\(destinationURL.path)"
            logger.info("\(cleanupMessage, privacy: .public)")
        } catch {
            let cleanupFailureMessage =
                "Failed to remove incomplete recovery output path=\(destinationURL.path) " +
                "reason=\(error.localizedDescription)"
            logger.error("\(cleanupFailureMessage, privacy: .public)")
        }
    }

    /// Attempts to build a richer output name using capture metadata from partial media bytes.
    /// Falls back to the scanned file name when metadata cannot be extracted.
    func inferPreferredOutputName(
        for file: RecoverableFile,
        reader: PrivilegedDiskReading
    ) -> String {
        let sampleBytes = readHeadSample(from: reader, file: file)
        guard
            let metadata = EXIFDateExtractor.extractMetadata(from: sampleBytes),
            let richName = buildMetadataDrivenName(from: metadata)
        else {
            return file.fileName
        }
        let metadataNameMessage =
            "Using metadata-driven output name file=\(file.fullFileName) richName=\(richName)"
        logger.debug("\(metadataNameMessage, privacy: .public)")
        return richName
    }

    func buildMetadataDrivenName(from metadata: EXIFDateExtractor.CaptureMetadata) -> String? {
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

    func readHeadSample(from reader: PrivilegedDiskReading, file: RecoverableFile) -> [UInt8] {
        let sampleRanges = file.leadingRecoveryRanges(maxBytes: 128 * 1024)
        guard let data = RecoveryByteRanges.readData(ranges: sampleRanges, from: reader) else {
            return []
        }
        return Array(data)
    }

    func ensureDestinationDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists {
            guard isDirectory.boolValue else {
                let notDirectoryMessage =
                    "Recovery destination exists but is not a directory path=\(url.path)"
                logger.error("\(notDirectoryMessage, privacy: .public)")
                throw FileRecoveryError.destinationNotDirectory(url.path)
            }
            let existingDirectoryMessage =
                "Recovery destination directory already exists path=\(url.path)"
            logger.debug("\(existingDirectoryMessage, privacy: .public)")
            return
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let createDirectoryMessage = "Created recovery destination directory path=\(url.path)"
        logger.info("\(createDirectoryMessage, privacy: .public)")
    }

    func verifySample(
        _ file: RecoverableFile,
        reader: PrivilegedDiskReading
    ) -> FileSampleVerification {
        guard file.sizeInBytes > 0 else {
            let reason = "File size is zero."
            let unreadableMessage =
                "Sample verification unreadable file=\(file.fullFileName) reason=\(reason)"
            logger.error("\(unreadableMessage, privacy: .public)")
            return FileSampleVerification(
                file: file,
                status: .unreadable,
                headHash: nil,
                tailHash: nil,
                failureReason: reason
            )
        }

        let sampleSize = min(Int(file.sizeInBytes), 4096)
        let headRanges = file.leadingRecoveryRanges(maxBytes: sampleSize)
        let tailRanges = file.trailingRecoveryRanges(maxBytes: sampleSize)
        let verifyMessage =
            "Verifying file samples file=\(file.fullFileName) sampleSize=\(sampleSize) " +
            "headRanges=\(RecoveryByteRanges.rangeSummary(headRanges)) " +
            "tailRanges=\(RecoveryByteRanges.rangeSummary(tailRanges))"
        logger.info("\(verifyMessage, privacy: .public)")

        guard let firstHead = readSampleHash(
            reader: reader,
            ranges: headRanges,
            file: file,
            label: "head sample pass 1"
        ) else {
            return unreadableVerification(file: file, label: "head sample pass 1", reader: reader)
        }
        guard let firstTail = readSampleHash(
            reader: reader,
            ranges: tailRanges,
            file: file,
            label: "tail sample pass 1"
        ) else {
            return unreadableVerification(file: file, label: "tail sample pass 1", reader: reader)
        }
        guard let secondHead = readSampleHash(
            reader: reader,
            ranges: headRanges,
            file: file,
            label: "head sample pass 2"
        ) else {
            return unreadableVerification(file: file, label: "head sample pass 2", reader: reader)
        }
        guard let secondTail = readSampleHash(
            reader: reader,
            ranges: tailRanges,
            file: file,
            label: "tail sample pass 2"
        ) else {
            return unreadableVerification(file: file, label: "tail sample pass 2", reader: reader)
        }

        if firstHead != secondHead || firstTail != secondTail {
            let mismatchMessage =
                "Sample verification mismatch file=\(file.fullFileName) " +
                "head1=\(String(firstHead.prefix(12))) head2=\(String(secondHead.prefix(12))) " +
                "tail1=\(String(firstTail.prefix(12))) tail2=\(String(secondTail.prefix(12)))"
            logger.warning("\(mismatchMessage, privacy: .public)")
            return FileSampleVerification(
                file: file,
                status: .mismatch,
                headHash: firstHead,
                tailHash: firstTail
            )
        }

        logger.info("Sample verification passed file=\(file.fullFileName, privacy: .public)")
        return FileSampleVerification(
            file: file,
            status: .verified,
            headHash: firstHead,
            tailHash: firstTail
        )
    }

    func readSampleHash(
        reader: PrivilegedDiskReading,
        ranges: [FragmentRange],
        file: RecoverableFile,
        label: String
    ) -> String? {
        let readMessage =
            "Reading \(label) file=\(file.fullFileName) " +
            "ranges=\(RecoveryByteRanges.rangeSummary(ranges))"
        logger.debug("\(readMessage, privacy: .public)")
        guard let data = RecoveryByteRanges.readData(
            ranges: ranges,
            from: reader,
            chunkSize: 4096
        ) else {
            let reason = reader.lastReadFailureDescription ?? "unknown read failure"
            let readFailureMessage =
                "Failed reading \(label) file=\(file.fullFileName) reason=\(reason)"
            logger.error("\(readFailureMessage, privacy: .public)")
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func unreadableVerification(
        file: RecoverableFile,
        label: String,
        reader: PrivilegedDiskReading
    ) -> FileSampleVerification {
        let baseReason = reader.lastReadFailureDescription ?? "unknown read failure"
        let failureReason = "\(label): \(baseReason)"
        let unreadableMessage =
            "Sample verification unreadable file=\(file.fullFileName) reason=\(failureReason)"
        logger.error("\(unreadableMessage, privacy: .public)")
        return FileSampleVerification(
            file: file,
            status: .unreadable,
            headHash: nil,
            tailHash: nil,
            failureReason: failureReason
        )
    }

    func uniqueFileURL(
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

        if duplicateIndex > 1 {
            let collisionMessage =
                "Adjusted recovery output name preferredName=\(preferredName).\(fileExtension) " +
                "resolvedName=\(candidateName)"
            logger.debug("\(collisionMessage, privacy: .public)")
        }

        return candidateURL
    }
}
