import Foundation
import os

/// Service that scans filesystem catalogs/indexes for deleted image and video files.
///
/// Fast Scan follows the "map" provided by the filesystem's index/catalog to find
/// files that have been marked as deleted but whose data may still be intact.
///
/// ## Strategy by Filesystem
/// - **FAT32**: Scans the directory table for entries starting with `0xE5`
/// - **ExFAT**: Scans for directory entries with the InUse bit cleared
/// - **NTFS**: Scans the MFT for records with the "in use" flag cleared
/// - **APFS/HFS+**: Scans `.Trashes` directories and APFS local snapshots
///
/// Deep Scan (a separate service) handles the raw sector-by-sector physical search.
protocol FastScanServicing: Sendable {
    func scan(device: StorageDevice) -> AsyncThrowingStream<ScanEvent, Error>
}

struct FastScanService: FastScanServicing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FastScan")
    private let diskReaderFactory: @Sendable (String) -> any PrivilegedDiskReading
    private let runTMUtilClosure: @Sendable (URL, Logger) -> String?
    private let mountSnapshotClosure: @Sendable (String, URL, Logger) throws -> URL
    private let unmountSnapshotClosure: @Sendable (URL, Logger) -> Void

    init(
        diskReaderFactory: @escaping @Sendable (String) -> any PrivilegedDiskReading = { PrivilegedDiskReader(devicePath: $0) as any PrivilegedDiskReading },
        runTMUtilClosure: @escaping @Sendable (URL, Logger) -> String? = FastScanService.defaultRunTMUtil,
        mountSnapshotClosure: @escaping @Sendable (String, URL, Logger) throws -> URL = FastScanService.defaultMountSnapshot,
        unmountSnapshotClosure: @escaping @Sendable (URL, Logger) -> Void = FastScanService.defaultUnmountSnapshot
    ) {
        self.diskReaderFactory = diskReaderFactory
        self.runTMUtilClosure = runTMUtilClosure
        self.mountSnapshotClosure = mountSnapshotClosure
        self.unmountSnapshotClosure = unmountSnapshotClosure
    }

    /// Set of file extensions we care about (lowercased).
    private static let supportedExtensions: Set<String> = Set(FileSignature.allCases.map(\.fileExtension))

    // MARK: - Public API

    /// Scans the given device's filesystem catalog for deleted image/video files.
    ///
    /// - Parameter device: The device to scan.
    /// - Returns: An `AsyncThrowingStream` of ``ScanEvent`` values.
    func scan(device: StorageDevice) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await performScan(device: device, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Scan Logic

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func performScan(
        device: StorageDevice,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeInfo = VolumeInfo.detect(for: device)

        logger.info("Fast scan Phase A (Filesystem) on \(volumeInfo.filesystemType.displayName)")

        var foundFilenames = Set<String>()

        // ── Phase A: Filesystem Walk ──
        let phaseAStream = AsyncThrowingStream<ScanEvent, Error> { phaseAContinuation in
            Task.detached {
                do {
                    try await performFilesystemScan(device: device, continuation: phaseAContinuation)
                } catch {
                    phaseAContinuation.finish(throwing: error)
                }
            }
        }

        for try await event in phaseAStream {
            switch event {
            case let .fileFound(file):
                foundFilenames.insert(file.fileName)
                continuation.yield(event)
            case let .progress(p):
                // Scale Phase A progress to 0-50%
                continuation.yield(.progress(p * 0.5))
            case .completed:
                break // Wait for Phase B
            }
        }

        // ── Phase B: Raw Catalog Scan ──
        let needsPhaseB = volumeInfo.filesystemType == .fat32 ||
            volumeInfo.filesystemType == .exfat ||
            volumeInfo.filesystemType == .ntfs

        if needsPhaseB {
            logger.info("Fast scan Phase B (Raw Catalog) on \(volumeInfo.filesystemType.displayName)")
            do {
                let reader = diskReaderFactory(volumeInfo.devicePath)
                try reader.start()
                defer { reader.stop() }

                if reader.isSeekable {
                    let phaseBStream = AsyncThrowingStream<ScanEvent, Error> { phaseBContinuation in
                        Task.detached {
                            do {
                                switch volumeInfo.filesystemType {
                                case .fat32:
                                    let scanner = FATDirectoryScanner()
                                    try await scanner.scan(
                                        volumeInfo: volumeInfo,
                                        reader: reader,
                                        continuation: phaseBContinuation
                                    )
                                case .exfat:
                                    let scanner = ExFATScanner()
                                    try await scanner.scan(
                                        volumeInfo: volumeInfo,
                                        reader: reader,
                                        continuation: phaseBContinuation
                                    )
                                case .ntfs:
                                    let scanner = NTFSScanner()
                                    try await scanner.scan(
                                        volumeInfo: volumeInfo,
                                        reader: reader,
                                        continuation: phaseBContinuation
                                    )
                                default:
                                    break
                                }
                                phaseBContinuation.finish()
                            } catch {
                                phaseBContinuation.finish(throwing: error)
                            }
                        }
                    }

                    for try await event in phaseBStream {
                        switch event {
                        case let .fileFound(file):
                            if !foundFilenames.contains(file.fileName) {
                                foundFilenames.insert(file.fileName)
                                continuation.yield(event)
                            }
                        case let .progress(p):
                            // Scale Phase B progress 50-100%
                            continuation.yield(.progress(0.5 + p * 0.5))
                        case .completed:
                            break
                        }
                    }
                } else {
                    logger.warning("Device is not seekable (using FIFO), skipping catalog scan Phase B")
                    continuation.yield(.progress(1.0))
                }
            } catch {
                logger.error("Phase B scan failed or access denied: \(error.localizedDescription)")
                continuation.yield(.progress(1.0))
            }
        } else {
            // For APFS/HFS+ jump to 100%
            continuation.yield(.progress(1.0))
        }

        continuation.yield(.completed)
        continuation.finish()
    }

    // MARK: - Filesystem-Level Scan (all FS types)

    /// Scans a mounted volume for deleted media files using standard file APIs.
    ///
    /// This approach requires NO elevated permissions — macOS grants read access
    /// to mounted external volumes at the user level. Strategies:
    ///
    /// 1. **`.Trashes` / `.Trash` directories**: Files moved to trash but not yet purged
    /// 2. **User `~/.Trash`**: The current user's trash on the boot volume
    /// 3. **APFS local snapshots** (APFS only): Read-only frozen states that may contain
    ///    files deleted from the live filesystem
    private func performFilesystemScan(
        device: StorageDevice,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeRoot = device.volumePath
        let volumeInfo = VolumeInfo.detect(for: device)
        logger.info("Starting filesystem scan on \(device.name) at \(volumeRoot.path)")

        var filesFound = 0
        var filesExamined = 0

        // ── Strategy 1: Scan .Trashes directories ──
        let fm = FileManager.default
        var trashDirs = [URL]()

        let volumeTrashes = volumeRoot.appendingPathComponent(".Trashes")
        if fm.fileExists(atPath: volumeTrashes.path) {
            trashDirs.append(volumeTrashes)
        }

        let volumeTrash = volumeRoot.appendingPathComponent(".Trash")
        if fm.fileExists(atPath: volumeTrash.path) {
            trashDirs.append(volumeTrash)
        }

        // On the boot volume, also add the current user's Trash
        if volumeRoot.path == "/" {
            let userTrash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            if fm.fileExists(atPath: userTrash.path) {
                trashDirs.append(userTrash)
            }
        }

        for trashDir in trashDirs {
            logger.info("Scanning trash directory: \(trashDir.path)")

            guard let enumerator = fm.enumerator(
                at: trashDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()

                if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true {
                    if !fm.isReadableFile(atPath: fileURL.path) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }

                filesExamined += 1

                if let file = examineFile(at: fileURL, source: .fastScan) {
                    filesFound += 1
                    continuation.yield(.fileFound(file))
                }

                if filesExamined % 50 == 0 {
                    let progress = 1.0 - (1.0 / (1.0 + Double(filesExamined) / 500.0))
                    continuation.yield(.progress(min(progress, 0.45)))
                    await Task.yield()
                }
            }
        }

        logger.info("Trash scan found \(filesFound) file(s) from \(filesExamined) examined")

        // ── Strategy 2: Scan APFS local snapshots (APFS only) ──
        if volumeInfo.filesystemType == .apfs {
            try await scanAPFSSnapshots(
                volumeRoot: volumeRoot,
                continuation: continuation,
                filesFound: &filesFound,
                filesExamined: &filesExamined
            )
        }

        logger.info("Filesystem scan complete: \(filesFound) total deleted file(s) found")
        continuation.yield(.progress(1.0))
        continuation.yield(.completed)
        continuation.finish()
    }

    /// Discovers and scans APFS local snapshots for media files that may have been
    /// deleted from the live filesystem but still exist in a snapshot.
    private func scanAPFSSnapshots(
        volumeRoot: URL,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        filesFound: inout Int,
        filesExamined: inout Int
    ) async throws {
        guard let output = runTMUtilClosure(volumeRoot, logger) else { return }

        // Parse snapshot names (format: "com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local")
        let snapshotNames = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("com.apple.TimeMachine") }

        guard !snapshotNames.isEmpty else {
            logger.info("No APFS local snapshots found")
            return
        }

        logger.info("Found \(snapshotNames.count) APFS snapshot(s) to scan")
        continuation.yield(.progress(0.50))

        // We scan at most the 3 most recent snapshots to keep things fast
        let recentSnapshots = snapshotNames.suffix(3)

        for snapshotName in recentSnapshots {
            try await scanSingleSnapshot(
                snapshotName: snapshotName,
                volumeRoot: volumeRoot,
                continuation: continuation,
                filesFound: &filesFound,
                filesExamined: &filesExamined
            )
        }
    }

    @Sendable
    private static func defaultRunTMUtil(volumeRoot: URL, logger: Logger) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volumeRoot.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress stderr

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: outputData, encoding: .utf8)
        } catch {
            logger.info("tmutil not available or failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func scanSingleSnapshot(
        snapshotName: String,
        volumeRoot: URL,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        filesFound: inout Int,
        filesExamined: inout Int
    ) async throws {
        try Task.checkCancellation()
        
        let mountPoint: URL
        do {
            mountPoint = try mountSnapshotClosure(snapshotName, volumeRoot, logger)
        } catch {
            return
        }

        logger.info("Mounted snapshot \(snapshotName) at \(mountPoint.path)")
        await enumerateSnapshot(
            mountPoint: mountPoint,
            volumeRoot: volumeRoot,
            continuation: continuation,
            filesFound: &filesFound,
            filesExamined: &filesExamined
        )

        unmountSnapshotClosure(mountPoint, logger)
    }

    @Sendable
    private static func defaultMountSnapshot(snapshotName: String, volumeRoot: URL, logger: Logger) throws -> URL {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("vivacity_snapshot_\(UUID().uuidString)")
        try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/sbin/mount_apfs")
        mountProcess.arguments = ["-s", snapshotName, "-o", "rdonly", volumeRoot.path, mountPoint.path]
        mountProcess.standardOutput = Pipe()
        mountProcess.standardError = Pipe()

        do {
            try mountProcess.run()
            mountProcess.waitUntilExit()
            guard mountProcess.terminationStatus == 0 else {
                logger.info("mount_apfs returned non-zero for snapshot \(snapshotName)")
                try? fm.removeItem(at: mountPoint)
                throw NSError(domain: "FastScan", code: Int(mountProcess.terminationStatus))
            }
        } catch {
            logger.info("Failed to mount snapshot \(snapshotName): \(error.localizedDescription)")
            try? fm.removeItem(at: mountPoint)
            throw error
        }
        return mountPoint
    }

    @Sendable
    private static func defaultUnmountSnapshot(mountPoint: URL, logger: Logger) {
        let unmountProcess = Process()
        unmountProcess.executableURL = URL(fileURLWithPath: "/sbin/umount")
        unmountProcess.arguments = [mountPoint.path]
        unmountProcess.standardOutput = Pipe()
        unmountProcess.standardError = Pipe()
        try? unmountProcess.run()
        unmountProcess.waitUntilExit()

        try? FileManager.default.removeItem(at: mountPoint)
    }

    private func enumerateSnapshot(
        mountPoint: URL,
        volumeRoot: URL,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        filesFound: inout Int,
        filesExamined: inout Int
    ) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { break }

            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: mountPoint.path, with: "")
            let liveURL = volumeRoot.appendingPathComponent(relativePath)

            if !fm.fileExists(atPath: liveURL.path) {
                filesExamined += 1
                if let file = examineFile(at: fileURL, source: .fastScan) {
                    filesFound += 1
                    continuation.yield(.fileFound(file))
                }
            }

            if filesExamined % 100 == 0 {
                let progress = 0.50 + 0.40 * (1.0 - (1.0 / (1.0 + Double(filesExamined) / 1000.0)))
                continuation.yield(.progress(min(progress, 0.95)))
                await Task.yield()
            }
        }
    }

    // MARK: - File Examination

    /// Examines a single file, verifying its magic bytes match its extension.
    /// Returns a `RecoverableFile` if the file is a valid match, `nil` otherwise.
    private func examineFile(at url: URL, source: ScanSource) -> RecoverableFile? {
        let ext = url.pathExtension.lowercased()
        guard let signature = FileSignature.from(extension: ext) else { return nil }

        // Read the first bytes to verify the magic signature
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let headerSize = max(signature.magicBytes.count, 12) // Read enough for ftyp checks
        guard let headerData = try? fileHandle.read(upToCount: headerSize),
              headerData.count >= signature.magicBytes.count
        else {
            return nil
        }

        // Verify magic bytes match
        let headerBytes = Array(headerData)
        guard matchesSignature(headerBytes, signature: signature) else { return nil }

        // Get file size
        let fileSize: Int64 = if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                                 let size = resourceValues.fileSize
        {
            Int64(size)
        } else {
            0
        }

        let fileName = url.deletingPathExtension().lastPathComponent

        return RecoverableFile(
            id: UUID(),
            fileName: fileName,
            fileExtension: ext,
            fileType: signature.category,
            sizeInBytes: fileSize,
            offsetOnDisk: 0, // Filesystem-level scan — offset is for raw disk carving
            signatureMatch: signature,
            source: source
        )
    }

    /// Checks whether the file header bytes match the expected signature.
    private func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes

        // Basic prefix check
        guard header.count >= magic.count else { return false }
        for i in 0 ..< magic.count {
            if header[i] != magic[i] { return false }
        }

        // For RIFF-based formats (AVI, WebP), check the sub-format at offset 8
        if signature == .avi || signature == .webp {
            guard header.count >= 12 else { return true }
            let subType = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
            switch signature {
            case .avi: return subType == "AVI "
            case .webp: return subType == "WEBP"
            default: break
            }
        }

        // For ftyp-based formats (MP4, MOV, HEIC, etc.), check brand at offset 4–8
        switch signature {
        case .mp4, .mov, .heic, .heif, .m4v, .threeGP:
            guard header.count >= 8 else { return true }
            let ftypMarker = String(bytes: header[4 ..< 8], encoding: .ascii) ?? ""
            if ftypMarker != "ftyp" { return false }
            return true
        default:
            return true
        }
    }
}
