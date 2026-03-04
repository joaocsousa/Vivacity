import Foundation
import os

// swiftlint:disable file_length
protocol DeepScanServicing: Sendable {
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error>
}

// swiftlint:disable:next type_body_length
struct DeepScanService: DeepScanServicing {
    struct PerformanceConfiguration: Sendable {
        let maxParallelSignatureWorkers: Int
        let minChunkSectors: Int
        let maxChunkSectors: Int
        let checkpointIntervalBytes: UInt64

        static let `default` = PerformanceConfiguration(
            maxParallelSignatureWorkers: max(2, ProcessInfo.processInfo.activeProcessorCount),
            minChunkSectors: 128,
            maxChunkSectors: 4096,
            checkpointIntervalBytes: 8 * 1024 * 1024
        )
    }

    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeepScan")
    private let diskReaderFactory: @Sendable (String) -> any PrivilegedDiskReading
    private let fileFooterDetector: FileFooterDetecting
    private let performanceConfig: PerformanceConfiguration

    init(
        diskReaderFactory: @escaping @Sendable (String)
            -> any PrivilegedDiskReading = { PrivilegedDiskReader(devicePath: $0) as any PrivilegedDiskReading },
        fileFooterDetector: FileFooterDetecting = FileFooterDetector(),
        performanceConfig: PerformanceConfiguration = .default
    ) {
        self.diskReaderFactory = diskReaderFactory
        self.fileFooterDetector = fileFooterDetector
        self.performanceConfig = performanceConfig
    }

    private static let sectorSize = 512
    private static let baseReadChunkSectors = 256
    private static let maxSignatureLength = 16
    private static let entropySampleBytes = 4096
    private static let entropyRejectThreshold = 2.2
    private static let confidenceRejectThreshold = 0.4
    private static let bloomCapacityBits = 1 << 20

    private static let directSignatures: [(FileSignature, [UInt8])] = {
        let unambiguous: [FileSignature] = [
            .jpeg, .png, .bmp, .gif, .mkv, .wmv, .flv, .raf, .rw2,
        ]
        return unambiguous.map { ($0, $0.magicBytes) }
    }()

    // MARK: - Public API

    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64 = 0,
        cameraProfile: CameraProfile = .generic
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await performScan(
                        device: device,
                        existingOffsets: existingOffsets,
                        startOffset: startOffset,
                        cameraProfile: cameraProfile,
                        continuation: continuation
                    )
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

    private struct ScanContext {
        let buffer: [UInt8]
        let scanLength: Int
        let readOffset: Int
        let bytesScanned: UInt64
        let cameraProfile: CameraProfile
        let totalBytes: UInt64
    }

    private struct ClaimedRange: Sendable {
        let start: UInt64
        let endExclusive: UInt64
    }

    private struct CandidateTracker {
        var allOffsets: Set<UInt64>
        var offsetBloom: RollingOffsetBloomFilter
        var claimedRanges: [ClaimedRange]
    }

    private struct ScanAccumulator {
        var filesFound: Int
        var tracker: CandidateTracker
    }

    private struct CarvedCandidate {
        let fileName: String
        let fileExtension: String
        let sizeInBytes: Int64
        let offsetOnDisk: UInt64
    }

    private struct CandidateEstimation {
        var sizeInBytes: Int64
        var hasInvalidCriticalChunkCRC: Bool
    }

    private struct RollingOffsetBloomFilter {
        private var bits: [UInt64]
        private let mask: UInt64

        init(capacityBits: Int) {
            let roundedBits = max(64, 1 << Int(log2(Double(max(capacityBits, 64)))))
            bits = Array(repeating: 0, count: roundedBits / 64)
            mask = UInt64(roundedBits - 1)
        }

        mutating func insert(_ value: UInt64) {
            for hash in hashes(for: value) {
                let idx = Int(hash >> 6)
                let bit = UInt64(1) << (hash & 63)
                bits[idx] |= bit
            }
        }

        func probablyContains(_ value: UInt64) -> Bool {
            for hash in hashes(for: value) {
                let idx = Int(hash >> 6)
                let bit = UInt64(1) << (hash & 63)
                if bits[idx] & bit == 0 { return false }
            }
            return true
        }

        private func hashes(for value: UInt64) -> [UInt64] {
            let h1 = (value &* 0x9E37_79B9_7F4A_7C15) & mask
            let h2 = ((value ^ 0xC2B2_AE3D_27D4_EB4F) &* 0x1656_67B1_9E37_79F9) & mask
            let rotated = (value << 13) | (value >> (64 - 13))
            let h3 = (rotated &* 0x85EB_CA6B_27D4_EB2F) & mask
            return [h1, h2, h3]
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func performScan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeInfo = VolumeInfo.detect(for: device)
        let devicePath = volumeInfo.devicePath

        logger.info("Starting deep scan on \(device.name) using device \(devicePath)")

        // Use injected reader which handles authorization and privilege
        // escalation transparently — tries direct open() first, then falls
        // back to AuthorizationExecuteWithPrivileges for root-level dd.
        let reader = diskReaderFactory(devicePath)
        do {
            try reader.start()
        } catch {
            logger.error("Failed to start privileged reader: \(error.localizedDescription)")
            throw DeepScanError.cannotOpenDevice(path: devicePath, reason: error.localizedDescription)
        }
        defer { reader.stop() }

        var fatCarver: FATCarver?
        var apfsCarver: APFSCarver?
        var hfsCarver: HFSPlusCarver?

        if volumeInfo.filesystemType == .fat32 {
            var bootSector = [UInt8](repeating: 0, count: 512)
            let read = bootSector.withUnsafeMutableBytes { buf in
                reader.read(into: buf.baseAddress!, offset: 0, length: 512)
            }
            if read == 512, let bpb = BPB(bootSector: bootSector) {
                fatCarver = FATCarver(bpb: bpb)
                logger.info("Initialized FATCarver with valid BPB")
            }
        } else if volumeInfo.filesystemType == .apfs {
            apfsCarver = APFSCarver()
            logger.info("Initialized APFSCarver for APFS volume")
        } else if volumeInfo.filesystemType == .hfsPlus {
            hfsCarver = HFSPlusCarver()
            logger.info("Initialized HFSPlusCarver for HFS+ volume")
        }

        // Get total size for progress
        let totalBytes = UInt64(device.totalCapacity)
        guard totalBytes > 0 else {
            logger.warning("Device reports 0 capacity, cannot deep scan")
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        let initialChunkSectors = initialChunkSectors(for: volumeInfo.blockSize)
        var currentChunkSectors = initialChunkSectors
        var chunkSize = Self.sectorSize * currentChunkSectors
        var buffer = [UInt8](repeating: 0, count: chunkSize + Self.maxSignatureLength)
        var bytesScanned: UInt64 = startOffset - (startOffset % UInt64(Self.sectorSize))
        var scanAccumulator = ScanAccumulator(
            filesFound: 0,
            tracker: CandidateTracker(
                allOffsets: existingOffsets,
                offsetBloom: RollingOffsetBloomFilter(capacityBits: Self.bloomCapacityBits),
                claimedRanges: []
            )
        )
        var lastProgressReport: Double = -1
        var lastCheckpointOffset = bytesScanned
        var carryOver = 0 // Bytes carried over from previous read for cross-boundary matching
        for offset in existingOffsets {
            scanAccumulator.tracker.offsetBloom.insert(offset)
        }

        logger.info("Deep scanning \(totalBytes) bytes (\(totalBytes / (1024 * 1024)) MB)")

        while bytesScanned < totalBytes {
            try Task.checkCancellation()

            if buffer.count < chunkSize + Self.maxSignatureLength {
                buffer = [UInt8](repeating: 0, count: chunkSize + Self.maxSignatureLength)
                carryOver = 0
            }

            // Read a chunk
            let toRead = min(chunkSize, Int(totalBytes - bytesScanned))
            let readOffset = carryOver // We keep leftover bytes at the start of buffer

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                reader.read(
                    into: rawBuffer.baseAddress! + readOffset,
                    offset: bytesScanned,
                    length: toRead
                )
            }
            guard bytesRead > 0 else { break }

            let scanLength = readOffset + bytesRead

            // 1. Run Filesystem-Aware Carver (if active)
            buffer.withUnsafeBytes { rawBuffer in
                let chunkStart = bytesScanned > UInt64(readOffset) ? bytesScanned - UInt64(readOffset) : 0
                let slice = UnsafeRawBufferPointer(rebasing: rawBuffer[0 ..< scanLength])

                var carvedFiles: [FATCarver.CarvedFile] = []
                var carvedAPFS: [APFSCarver.CarvedFile] = []
                var carvedHFS: [HFSPlusCarver.CarvedFile] = []

                if fatCarver != nil {
                    carvedFiles = fatCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                } else if apfsCarver != nil {
                    carvedAPFS = apfsCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                } else if hfsCarver != nil {
                    carvedHFS = hfsCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                }

                // Process FAT carved files
                for carvedFile in carvedFiles {
                    if scanAccumulator.tracker.allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        candidate: CarvedCandidate(
                            fileName: carvedFile.fileName,
                            fileExtension: carvedFile.fileExtension,
                            sizeInBytes: carvedFile.sizeInBytes,
                            offsetOnDisk: carvedFile.offsetOnDisk
                        ),
                        reader: reader,
                        scanAccumulator: &scanAccumulator,
                        totalBytes: totalBytes,
                        continuation: continuation
                    )
                }

                // Process APFS carved files
                for carvedFile in carvedAPFS {
                    if scanAccumulator.tracker.allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        candidate: CarvedCandidate(
                            fileName: carvedFile.fileName,
                            fileExtension: carvedFile.fileExtension,
                            sizeInBytes: carvedFile.sizeInBytes,
                            offsetOnDisk: carvedFile.offsetOnDisk
                        ),
                        reader: reader,
                        scanAccumulator: &scanAccumulator,
                        totalBytes: totalBytes,
                        continuation: continuation
                    )
                }

                // Process HFS+ carved files
                for carvedFile in carvedHFS {
                    if scanAccumulator.tracker.allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        candidate: CarvedCandidate(
                            fileName: carvedFile.fileName,
                            fileExtension: carvedFile.fileExtension,
                            sizeInBytes: carvedFile.sizeInBytes,
                            offsetOnDisk: carvedFile.offsetOnDisk
                        ),
                        reader: reader,
                        scanAccumulator: &scanAccumulator,
                        totalBytes: totalBytes,
                        continuation: continuation
                    )
                }
            }

            // 2. Linear Magic Byte Scan
            let context = ScanContext(
                buffer: buffer,
                scanLength: scanLength,
                readOffset: readOffset,
                bytesScanned: bytesScanned,
                cameraProfile: cameraProfile,
                totalBytes: totalBytes
            )
            let detectedMatches = await scanChunk(
                context: context,
                reader: reader,
                scanAccumulator: &scanAccumulator,
                continuation: continuation
            )

            bytesScanned += UInt64(bytesRead)

            currentChunkSectors = adaptChunkSectors(
                current: currentChunkSectors,
                matches: detectedMatches,
                bytesRead: bytesRead
            )
            chunkSize = Self.sectorSize * currentChunkSectors

            // Keep the last few bytes for cross-boundary matching
            if scanLength > Self.maxSignatureLength {
                let keepFrom = scanLength - Self.maxSignatureLength
                for j in 0 ..< Self.maxSignatureLength {
                    buffer[j] = buffer[keepFrom + j]
                }
                carryOver = Self.maxSignatureLength
            }

            // Report progress (throttled to avoid spamming — every ~1%)
            let progress = Double(bytesScanned) / Double(totalBytes)
            if progress - lastProgressReport >= 0.01 {
                continuation.yield(.progress(min(progress, 1.0)))
                lastProgressReport = progress

                // Yield to avoid starving the main thread
                await Task.yield()
            }

            if bytesScanned - lastCheckpointOffset >= performanceConfig.checkpointIntervalBytes {
                continuation.yield(.checkpoint(bytesScanned))
                lastCheckpointOffset = bytesScanned
            }
        }

        logger
            .info(
                "Deep scan complete: \(scanAccumulator.filesFound) file(s) found after scanning \(bytesScanned) bytes"
            )
        continuation.yield(.checkpoint(bytesScanned))
        continuation.yield(.completed)
        continuation.finish()
    }

    private func processCarvedFile(
        candidate: CarvedCandidate,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) {
        // Verify signature by reading the cluster from disk
        var header = [UInt8](repeating: 0, count: 16)
        let headRead = header.withUnsafeMutableBytes { hBuf in
            reader.read(into: hBuf.baseAddress!, offset: candidate.offsetOnDisk, length: 16)
        }

        if headRead == 16 {
            if let sig = verifyMagicBytes(header, expectedExtension: candidate.fileExtension) {
                let file = RecoverableFile(
                    id: UUID(),
                    fileName: candidate.fileName,
                    fileExtension: candidate.fileExtension,
                    fileType: sig.category,
                    sizeInBytes: candidate.sizeInBytes,
                    offsetOnDisk: candidate.offsetOnDisk,
                    signatureMatch: sig,
                    source: .deepScan,
                    isLikelyContiguous: candidate.sizeInBytes > 0,
                    confidenceScore: confidenceScore(
                        signature: sig,
                        sizeInBytes: candidate.sizeInBytes,
                        entropy: shannonEntropy(of: header),
                        hasStructureSignal: candidate.sizeInBytes > 0
                    )
                )

                if shouldEmit(file),
                   canAcceptCandidate(
                       offset: candidate.offsetOnDisk,
                       sizeInBytes: candidate.sizeInBytes,
                       totalBytes: totalBytes,
                       tracker: scanAccumulator.tracker
                   )
                {
                    registerCandidate(
                        offset: candidate.offsetOnDisk,
                        sizeInBytes: candidate.sizeInBytes,
                        tracker: &scanAccumulator.tracker
                    )
                    scanAccumulator.filesFound += 1
                    continuation.yield(.fileFound(file))
                }
            }
        }
    }

    private func scanChunk(
        context: ScanContext,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async -> Int {
        let candidatePositions = stride(from: 0, to: context.scanLength - Self.maxSignatureLength, by: Self.sectorSize)
            .map { $0 }
        let matches = await detectMatchesInParallel(
            buffer: context.buffer,
            positions: candidatePositions,
            cameraProfile: context.cameraProfile
        )

        for matchEntry in matches {
            await processMatch(
                matchEntry,
                context: context,
                reader: reader,
                scanAccumulator: &scanAccumulator,
                continuation: continuation
            )
        }

        return matches.count
    }

    private func processMatch(
        _ matchEntry: (Int, FileSignature),
        context: ScanContext,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async {
        let (index, signature) = matchEntry
        let offset = context.bytesScanned + UInt64(index) - UInt64(context.readOffset)
        if scanAccumulator.tracker.offsetBloom.probablyContains(offset),
           scanAccumulator.tracker.allOffsets.contains(offset)
        {
            return
        }

        let candidateNumber = scanAccumulator.filesFound + 1
        let fileName = extractCandidateFileName(
            signature: signature,
            context: context,
            index: index,
            candidateNumber: candidateNumber
        )
        let candidateEstimation = await estimateCandidateSize(
            signature: signature,
            offset: offset,
            context: context,
            index: index,
            reader: reader
        )
        var sizeInBytes = candidateEstimation.sizeInBytes
        let hasInvalidCriticalChunkCRC = candidateEstimation.hasInvalidCriticalChunkCRC

        // For MP4-like formats, try detailed layout reconstruction for displaced moov detection
        var fragmentMap: [FragmentRange]?
        let mp4LikeSignatures: Set<FileSignature> = [.mp4, .mov, .m4v, .threeGP]
        if mp4LikeSignatures.contains(signature) {
            let reconstructor = MP4Reconstructor()
            if let result = reconstructor.reconstructDetailedLayout(startingAt: offset, reader: reader) {
                if result.hasDisplacedMoov {
                    sizeInBytes = Int64(result.totalSize)
                    fragmentMap = result.fragments
                }
            }
        }

        let entropy = sampleEntropy(buffer: context.buffer, scanLength: context.scanLength, index: index)
        let score = confidenceScore(
            signature: signature,
            sizeInBytes: sizeInBytes,
            entropy: entropy,
            hasStructureSignal: true,
            hasInvalidPNGCriticalChunkCRC: hasInvalidCriticalChunkCRC
        )

        let file = RecoverableFile(
            id: UUID(),
            fileName: fileName,
            fileExtension: signature.fileExtension,
            fileType: signature.category,
            sizeInBytes: sizeInBytes,
            offsetOnDisk: offset,
            signatureMatch: signature,
            source: .deepScan,
            isLikelyContiguous: sizeInBytes > 0 && fragmentMap == nil,
            confidenceScore: score,
            fragmentMap: fragmentMap
        )

        if shouldEmit(file, entropy: entropy),
           canAcceptCandidate(
               offset: offset,
               sizeInBytes: sizeInBytes,
               totalBytes: context.totalBytes,
               tracker: scanAccumulator.tracker
           )
        {
            registerCandidate(offset: offset, sizeInBytes: sizeInBytes, tracker: &scanAccumulator.tracker)
            scanAccumulator.filesFound += 1
            continuation.yield(.fileFound(file))
        }
    }

    private func extractCandidateFileName(
        signature: FileSignature,
        context: ScanContext,
        index: Int,
        candidateNumber: Int
    ) -> String {
        var fileName = "\(context.cameraProfile.defaultFilePrefix)\(String(format: "%04d", candidateNumber))"
        guard signature.category == .image else { return fileName }

        let availableBytes = context.buffer.count - index
        let checkLength = min(availableBytes, 65536)
        let headerSlice = Array(context.buffer[index ..< index + checkLength])
        if let exifName = EXIFDateExtractor.extractFilenamePrefix(from: headerSlice) {
            fileName = "\(exifName)_\(String(format: "%04d", candidateNumber))"
        }
        return fileName
    }

    private func estimateCandidateSize(
        signature: FileSignature,
        offset: UInt64,
        context: ScanContext,
        index: Int,
        reader: PrivilegedDiskReading
    ) async -> CandidateEstimation {
        var estimate = CandidateEstimation(sizeInBytes: 0, hasInvalidCriticalChunkCRC: false)

        if signature == .png,
           let pngEstimate = try? await fileFooterDetector.estimatePNGSize(
               startOffset: offset,
               reader: reader,
               maxScanBytes: 32 * 1024 * 1024,
               validateCriticalChunkCRCs: true
           )
        {
            estimate.sizeInBytes = pngEstimate.sizeInBytes
            estimate.hasInvalidCriticalChunkCRC = pngEstimate.hasInvalidCriticalChunkCRC
        }

        let footerDetectableSignatures: Set<FileSignature> = [.jpeg, .gif, .bmp, .webp]
        if footerDetectableSignatures.contains(signature),
           let estimatedSize = try? await fileFooterDetector.estimateSize(
               signature: signature,
               startOffset: offset,
               reader: reader,
               maxScanBytes: 32 * 1024 * 1024
           )
        {
            estimate.sizeInBytes = estimatedSize
        }

        let mp4LikeSignatures: Set<FileSignature> = [.mp4, .mov, .m4v, .threeGP, .heic, .heif, .avif, .cr3]
        if mp4LikeSignatures.contains(signature) {
            let mp4Reconstructor = MP4Reconstructor()
            if let contiguousSize = mp4Reconstructor.calculateContiguousSize(startingAt: offset, reader: reader) {
                estimate.sizeInBytes = Int64(contiguousSize)
            }
            return estimate
        }

        if signature == .jpeg, estimate.sizeInBytes == 0 {
            let imageReconstructor = ImageReconstructor()
            let availableBytes = context.buffer.count - index
            let checkLength = min(availableBytes, 65536)
            let headerSlice = Data(context.buffer[index ..< index + checkLength])
            if let result = await imageReconstructor.reconstruct(
                headerOffset: offset,
                initialChunk: headerSlice,
                reader: reader
            ) {
                estimate.sizeInBytes = Int64(result.count)
            }
        }

        return estimate
    }

    private func sampleEntropy(buffer: [UInt8], scanLength: Int, index: Int) -> Double {
        let availableBytes = scanLength - index
        let entropySampleLength = min(max(availableBytes, 0), Self.entropySampleBytes)
        guard entropySampleLength > 0 else { return shannonEntropy(of: []) }
        let entropyBytes = Array(buffer[index ..< index + entropySampleLength])
        return shannonEntropy(of: entropyBytes)
    }

    private func detectMatchesInParallel(
        buffer: [UInt8],
        positions: [Int],
        cameraProfile: CameraProfile
    ) async -> [(Int, FileSignature)] {
        guard !positions.isEmpty else { return [] }

        let workers = max(1, performanceConfig.maxParallelSignatureWorkers)
        let sliceSize = max(1, positions.count / workers)

        return await withTaskGroup(of: [(Int, FileSignature)].self) { group in
            for start in stride(from: 0, to: positions.count, by: sliceSize) {
                let end = min(start + sliceSize, positions.count)
                let slice = Array(positions[start ..< end])
                group.addTask {
                    var local: [(Int, FileSignature)] = []
                    local.reserveCapacity(slice.count / 16 + 1)
                    for pos in slice {
                        if let signature = matchSignatureAt(
                            buffer: buffer,
                            position: pos,
                            cameraProfile: cameraProfile
                        ) {
                            local.append((pos, signature))
                        }
                    }
                    return local
                }
            }

            var combined: [(Int, FileSignature)] = []
            for await partial in group {
                combined.append(contentsOf: partial)
            }
            return combined.sorted { $0.0 < $1.0 }
        }
    }

    private func initialChunkSectors(for blockSize: Int) -> Int {
        let blockMultiplier = max(1, blockSize / Self.sectorSize)
        let desired = Self.baseReadChunkSectors * blockMultiplier
        return min(max(desired, performanceConfig.minChunkSectors), performanceConfig.maxChunkSectors)
    }

    private func adaptChunkSectors(current: Int, matches: Int, bytesRead: Int) -> Int {
        guard bytesRead > 0 else { return current }

        let sectorsRead = max(1, bytesRead / Self.sectorSize)
        let density = Double(matches) / Double(sectorsRead)

        var next = current
        if density > 0.03 {
            next = max(performanceConfig.minChunkSectors, current / 2)
        } else if density < 0.005 {
            next = min(performanceConfig.maxChunkSectors, Int(Double(current) * 1.5))
        }
        return max(performanceConfig.minChunkSectors, min(next, performanceConfig.maxChunkSectors))
    }

    private func canAcceptCandidate(
        offset: UInt64,
        sizeInBytes: Int64,
        totalBytes: UInt64,
        tracker: CandidateTracker
    ) -> Bool {
        if tracker.offsetBloom.probablyContains(offset), tracker.allOffsets.contains(offset) {
            return false
        }

        if let candidateRange = buildCandidateRange(offset: offset, sizeInBytes: sizeInBytes, totalBytes: totalBytes) {
            if candidateRange.endExclusive > totalBytes {
                return false
            }

            for range in tracker.claimedRanges {
                if rangesOverlap(candidateRange, range) {
                    return false
                }
            }
        } else {
            // Unknown-sized candidate still must not start inside an already claimed range.
            if tracker.claimedRanges.contains(where: { offset >= $0.start && offset < $0.endExclusive }) {
                return false
            }
        }

        return true
    }

    private func registerCandidate(
        offset: UInt64,
        sizeInBytes: Int64,
        tracker: inout CandidateTracker
    ) {
        tracker.allOffsets.insert(offset)
        tracker.offsetBloom.insert(offset)
        if let range = buildCandidateRange(offset: offset, sizeInBytes: sizeInBytes, totalBytes: UInt64.max) {
            tracker.claimedRanges.append(range)
        }
    }

    private func buildCandidateRange(offset: UInt64, sizeInBytes: Int64, totalBytes: UInt64) -> ClaimedRange? {
        guard sizeInBytes > 0 else { return nil }
        let size = UInt64(sizeInBytes)
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow else { return nil }
        if totalBytes != UInt64.max, end > totalBytes {
            return ClaimedRange(start: offset, endExclusive: end)
        }
        return ClaimedRange(start: offset, endExclusive: end)
    }

    private func rangesOverlap(_ lhs: ClaimedRange, _ rhs: ClaimedRange) -> Bool {
        lhs.start < rhs.endExclusive && rhs.start < lhs.endExclusive
    }

    private func shouldEmit(_ file: RecoverableFile, entropy: Double? = nil) -> Bool {
        let score = file.confidenceScore ?? 0

        if let entropy {
            // Drop obvious low-information false positives from deep scans.
            if entropy < Self.entropyRejectThreshold,
               file.signatureMatch == .jpeg,
               file.sizeInBytes > 0,
               file.sizeInBytes < 256 * 1024
            {
                return false
            }
        }

        return score >= Self.confidenceRejectThreshold
    }

    private func confidenceScore(
        signature: FileSignature,
        sizeInBytes: Int64,
        entropy: Double,
        hasStructureSignal: Bool,
        hasInvalidPNGCriticalChunkCRC: Bool = false
    ) -> Double {
        let signatureStrength = signatureStrength(for: signature)
        let structureScore = hasStructureSignal ? 1.0 : 0.35
        let sizeScore = sizePlausibilityScore(signature: signature, sizeInBytes: sizeInBytes)
        let entropyScore = normalizedEntropyScore(entropy)

        let weighted =
            (signatureStrength * 0.30) +
            (structureScore * 0.30) +
            (sizeScore * 0.20) +
            (entropyScore * 0.20)
        let pngCRCPenalty = signature == .png && hasInvalidPNGCriticalChunkCRC ? 0.25 : 0
        return min(max(weighted - pngCRCPenalty, 0), 1)
    }

    private func signatureStrength(for signature: FileSignature) -> Double {
        switch signature {
        case .jpeg, .png, .gif, .bmp, .tiff, .tiffBigEndian, .heic, .heif, .avif:
            0.95
        case .mp4, .mov, .m4v, .threeGP, .mkv, .avi:
            0.85
        case .webp, .wmv, .flv:
            0.75
        case .cr2, .cr3, .nef, .arw, .dng, .raf, .rw2:
            0.8
        }
    }

    private func sizePlausibilityScore(signature: FileSignature, sizeInBytes: Int64) -> Double {
        guard sizeInBytes > 0 else { return 0.2 }
        let minimum = minimumPlausibleSize(for: signature)
        if sizeInBytes < minimum {
            return 0.35
        }
        if sizeInBytes < minimum * 2 {
            return 0.7
        }
        return 1.0
    }

    private func minimumPlausibleSize(for signature: FileSignature) -> Int64 {
        switch signature.category {
        case .image: 4 * 1024
        case .video: 64 * 1024
        }
    }

    private func normalizedEntropyScore(_ entropy: Double) -> Double {
        // Typical compressed media data tends to be >5 bits/byte in local windows.
        switch entropy {
        case ..<2.2:
            0
        case 2.2 ..< 4.0:
            0.35
        case 4.0 ..< 5.0:
            0.65
        case 5.0 ..< 8.5:
            1.0
        default:
            0.8
        }
    }

    private func shannonEntropy(of bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in bytes {
            counts[Int(byte)] += 1
        }

        let total = Double(bytes.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    // MARK: - Signature Matching

    /// Checks the buffer at the given position for any known file signature.
    private func matchSignatureAt(buffer: [UInt8], position: Int, cameraProfile: CameraProfile) -> FileSignature? {
        let remaining = buffer.count - position
        guard remaining >= 4 else { return nil }

        if let direct = matchDirectSignatures(buffer: buffer, position: position, remaining: remaining) {
            return direct
        }

        if let tiff = matchTIFFSignatures(
            buffer: buffer,
            position: position,
            remaining: remaining,
            cameraProfile: cameraProfile
        ) {
            return tiff
        }

        if let riff = matchRIFFSignatures(buffer: buffer, position: position, remaining: remaining) {
            return riff
        }

        if let ftyp = matchFtypSignatures(buffer: buffer, position: position, remaining: remaining) {
            return ftyp
        }

        if let movAtom = matchMOVAtomSignatures(buffer: buffer, position: position, remaining: remaining) {
            return movAtom
        }

        return nil
    }

    private func matchDirectSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        for (signature, magic) in Self.directSignatures {
            if remaining >= magic.count {
                var matched = true
                for j in 0 ..< magic.count {
                    if buffer[position + j] != magic[j] {
                        matched = false
                        break
                    }
                }
                if matched { return signature }
            }
        }
        return nil
    }

    private func matchTIFFSignatures(
        buffer: [UInt8],
        position: Int,
        remaining: Int,
        cameraProfile: CameraProfile
    ) -> FileSignature? {
        // Panasonic RW2: 49 49 55 00
        if remaining >= 4,
           buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x55, buffer[position + 3] == 0x00
        {
            return .rw2
        }

        // Little-endian TIFF: 49 49 2A 00
        if buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x2A, buffer[position + 3] == 0x00
        {
            // Could be TIFF, CR2, ARW, or DNG
            if remaining >= 10, buffer[position + 8] == 0x43, buffer[position + 9] == 0x52 {
                return .cr2 // "CR" at offset 8
            }

            // Try IFD0 Make/Model identification (higher priority than camera profile)
            let ifdCheckLength = min(remaining, 65536)
            let headerSlice = Array(buffer[position ..< position + ifdCheckLength])
            let tiffParser = TIFFHeaderParser()
            if let rawSignature = tiffParser.identifyRAWSignature(from: headerSlice) {
                return rawSignature
            }

            // Signature promotion based on camera profile
            switch cameraProfile {
            case .sony:
                return .arw
            case .dji:
                return .dng
            default:
                return .tiff
            }
        }
        // Big-endian TIFF: 4D 4D 00 2A
        if buffer[position] == 0x4D, buffer[position + 1] == 0x4D,
           buffer[position + 2] == 0x00, buffer[position + 3] == 0x2A
        {
            return .tiffBigEndian
        }
        return nil
    }

    private func matchRIFFSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12,
           buffer[position] == 0x52, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x46, buffer[position + 3] == 0x46
        {
            let sub = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
            if sub == "AVI " { return .avi }
            if sub == "WEBP" { return .webp }
        }
        return nil
    }

    private func matchFtypSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12 {
            let ftypStr = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
            if ftypStr == "ftyp" {
                let brand = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
                switch brand.trimmingCharacters(in: .whitespaces).lowercased() {
                case "isom", "iso2", "mp41", "mp42", "avc1":
                    return .mp4
                case "qt", "qt  ", "wide":
                    return .mov
                case "heic", "heix":
                    return .heic
                case "mif1":
                    return .heif
                case "avif", "avis":
                    return .avif
                case "cr3", "crx":
                    return .cr3
                case "m4v":
                    return .m4v
                case "3gp4", "3gp5", "3gp6", "3ge6":
                    return .threeGP
                default:
                    return .mp4 // Default ftyp to mp4
                }
            }
        }
        return nil
    }

    private func matchMOVAtomSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        guard remaining >= 16 else { return nil }
        let firstType = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
        let firstSize = (Int(buffer[position]) << 24)
            | (Int(buffer[position + 1]) << 16)
            | (Int(buffer[position + 2]) << 8)
            | Int(buffer[position + 3])
        guard firstSize >= 8, firstSize <= remaining - 8 else { return nil }
        let secondHeader = position + firstSize
        guard secondHeader + 8 <= buffer.count else { return nil }
        let secondType = String(bytes: buffer[(secondHeader + 4) ..< (secondHeader + 8)], encoding: .ascii) ?? ""

        let knownAtoms: Set<String> = ["moov", "mdat", "free", "wide", "skip", "udta", "trak"]
        if knownAtoms.contains(firstType), knownAtoms.contains(secondType) {
            return .mov
        }
        return nil
    }

    /// Reads the first 16 bytes at the given cluster and checks for a known signature.
    private func verifyMagicBytes(
        _ header: [UInt8],
        expectedExtension: String
    ) -> FileSignature? {
        guard header.count >= 16 else { return nil }

        // First try to match against the expected extension
        if let expectedSig = FileSignature.from(extension: expectedExtension) {
            if matchesSignature(header, signature: expectedSig) {
                return expectedSig
            }
        }

        // If extension didn't match, or couldn't map, test all known signatures
        for signature in FileSignature.allCases {
            if matchesSignature(header, signature: signature) {
                return signature
            }
        }

        return nil
    }

    /// Checks whether the header bytes match a file signature.
    private func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        guard matchesMagicPrefix(header, signature: signature) else { return false }

        if let riffResult = matchesRIFFSubtypeIfNeeded(header, signature: signature) {
            return riffResult
        }

        if let ftypResult = matchesFTYPBrandIfNeeded(header, signature: signature) {
            return ftypResult
        }

        return true
    }

    private func matchesMagicPrefix(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes
        guard header.count >= magic.count else { return false }
        for i in 0 ..< magic.count where header[i] != magic[i] {
            return false
        }
        return true
    }

    private func matchesRIFFSubtypeIfNeeded(_ header: [UInt8], signature: FileSignature) -> Bool? {
        guard signature == .avi || signature == .webp else { return nil }
        guard header.count >= 12 else { return true }
        let subType = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
        if signature == .avi { return subType == "AVI " }
        return subType == "WEBP"
    }

    private func matchesFTYPBrandIfNeeded(_ header: [UInt8], signature: FileSignature) -> Bool? {
        let ftypSignatures: Set<FileSignature> = [.mp4, .mov, .heic, .heif, .m4v, .threeGP, .avif, .cr3]
        guard ftypSignatures.contains(signature) else { return nil }
        guard header.count >= 8 else { return true }

        let ftyp = String(bytes: header[4 ..< 8], encoding: .ascii) ?? ""
        guard ftyp == "ftyp", header.count >= 12 else { return false }

        let brand = String(bytes: header[8 ..< 12], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""

        switch signature {
        case .mp4: return ["isom", "iso2", "mp41", "mp42", "avc1"].contains(brand)
        case .mov: return ["qt", "qt  ", "wide"].contains(brand)
        case .heic: return ["heic", "heix"].contains(brand)
        case .heif: return brand == "mif1"
        case .m4v: return brand == "m4v"
        case .threeGP: return ["3gp4", "3gp5", "3gp6", "3ge6"].contains(brand)
        case .avif: return ["avif", "avis"].contains(brand)
        case .cr3: return ["cr3", "crx"].contains(brand)
        default: return true
        }
    }
}

// MARK: - Errors

/// Errors specific to the deep scan process.
enum DeepScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path) for scanning: \(reason). " +
                "Try running with elevated privileges or granting Full Disk Access in System Settings."
        }
    }
}
