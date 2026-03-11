import Foundation
import os

protocol DeepScanServicing: Sendable {
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error>
}

struct RollingOffsetBloomFilter {
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
    let fileFooterDetector: FileFooterDetecting
    let performanceConfig: PerformanceConfiguration

    init(
        diskReaderFactory: @escaping @Sendable (String)
            -> any PrivilegedDiskReading = { DiskReaderFactoryProvider.makeReader(forPath: $0) },
        fileFooterDetector: FileFooterDetecting = FileFooterDetector(),
        performanceConfig: PerformanceConfiguration = .default
    ) {
        self.diskReaderFactory = diskReaderFactory
        self.fileFooterDetector = fileFooterDetector
        self.performanceConfig = performanceConfig
    }

    static let sectorSize = 512
    static let baseReadChunkSectors = 256
    static let maxSignatureLength = 16
    static let entropySampleBytes = 4096
    static let entropyRejectThreshold = 2.2
    static let confidenceRejectThreshold = 0.4
    static let bloomCapacityBits = 1 << 20

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private func logWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

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

    struct ScanContext {
        let buffer: [UInt8]
        let scanLength: Int
        let readOffset: Int
        let bytesScanned: UInt64
        let cameraProfile: CameraProfile
        let totalBytes: UInt64
        let maxContiguousEndOffset: UInt64
    }

    struct ClaimedRange: Sendable {
        let start: UInt64
        let endExclusive: UInt64
    }

    struct CandidateTracker {
        var allOffsets: Set<UInt64>
        var offsetBloom: RollingOffsetBloomFilter
        var claimedRanges: [ClaimedRange]
    }

    struct ScanAccumulator {
        var filesFound: Int
        var tracker: CandidateTracker
    }

    struct CarvedCandidate {
        let fileName: String
        let fileExtension: String
        let sizeInBytes: Int64
        let offsetOnDisk: UInt64
    }

    struct CandidateEstimation {
        var sizeInBytes: Int64
        var hasInvalidCriticalChunkCRC: Bool
    }

    private struct ActiveCarvers {
        var fat: FATCarver?
        var apfs: APFSCarver?
        var hfsPlus: HFSPlusCarver?
    }

    private struct ScanLoopState {
        var currentChunkSectors: Int
        var chunkSize: Int
        var buffer: [UInt8]
        var bytesScanned: UInt64
        var scanAccumulator: ScanAccumulator
        var lastProgressReport: Double
        var lastCheckpointOffset: UInt64
        var carryOver: Int
        var chunkReadCount: Int
        var lastLoggedProgressDecile: Int
        var freeSpaceRanges: [FreeSpaceRange]?
        var currentRangeIndex: Int?
    }

    private struct ChunkReadResult {
        let bytesRead: Int
        let scanLength: Int
        let readOffset: Int
    }

    private struct ScanRuntimeContext {
        let devicePath: String
        let reader: any PrivilegedDiskReading
        let cameraProfile: CameraProfile
        let totalBytes: UInt64
        let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    }

    private func performScan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeInfo = VolumeInfo.detect(for: device)
        let devicePath = volumeInfo.devicePath
        logInfo(
            "Starting deep scan on '\(device.name)' " +
                "device=\(devicePath) " +
                "fs=\(volumeInfo.filesystemType.displayName) " +
                "blockSize=\(volumeInfo.blockSize) " +
                "startOffset=\(startOffset) " +
                "existingOffsets=\(existingOffsets.count)"
        )
        let reader = try startReader(for: devicePath)
        defer { reader.stop() }

        let totalBytes = UInt64(device.totalCapacity)
        guard totalBytes > 0 else {
            logger.warning("Device reports 0 capacity, cannot deep scan")
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        var carvers = initializeCarvers(for: volumeInfo, reader: reader)
        let freeSpaceRanges = await initializeFreeSpaceMap(for: volumeInfo, reader: reader)
        
        var state = makeInitialScanLoopState(
            volumeInfo: volumeInfo,
            existingOffsets: existingOffsets,
            startOffset: startOffset,
            freeSpaceRanges: freeSpaceRanges
        )
        let runtime = ScanRuntimeContext(
            devicePath: devicePath,
            reader: reader,
            cameraProfile: cameraProfile,
            totalBytes: totalBytes,
            continuation: continuation
        )
        logInfo(
            "Deep scanning totalBytes=\(totalBytes) " +
                "(\(totalBytes / (1024 * 1024)) MB) " +
                "initialChunkSize=\(state.chunkSize) bytes"
        )
        try await runScanLoop(
            state: &state,
            carvers: &carvers,
            runtime: runtime
        )

        let completionMessage =
            "Deep scan complete: \(state.scanAccumulator.filesFound) file(s) " +
            "found after scanning \(state.bytesScanned) bytes"
        logInfo(completionMessage)
        continuation.yield(.checkpoint(state.bytesScanned))
        continuation.yield(.completed)
        continuation.finish()
    }

    private func initializeCarvers(for volumeInfo: VolumeInfo, reader: PrivilegedDiskReading) -> ActiveCarvers {
        switch volumeInfo.filesystemType {
        case .fat32:
            let fat = createFATCarver(reader: reader)
            logInfo("Deep scan filesystem-aware carver FAT enabled=\(fat != nil)")
            return ActiveCarvers(fat: fat, apfs: nil, hfsPlus: nil)
        case .apfs:
            logger.info("Initialized APFSCarver for APFS volume")
            return ActiveCarvers(fat: nil, apfs: APFSCarver(), hfsPlus: nil)
        case .hfsPlus:
            logger.info("Initialized HFSPlusCarver for HFS+ volume")
            return ActiveCarvers(fat: nil, apfs: nil, hfsPlus: HFSPlusCarver())
        default:
            logInfo("No filesystem-aware carver available for fs=\(volumeInfo.filesystemType.displayName)")
            return ActiveCarvers(fat: nil, apfs: nil, hfsPlus: nil)
        }
    }

    private func createFATCarver(reader: PrivilegedDiskReading) -> FATCarver? {
        var bootSector = [UInt8](repeating: 0, count: 512)
        let bytesRead = bootSector.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: 0, length: 512)
        }
        guard bytesRead == 512, let bpb = BPB(bootSector: bootSector) else { return nil }

        logger.info("Initialized FATCarver with valid BPB")
        return FATCarver(bpb: bpb)
    }

    private func initializeFreeSpaceMap(for volumeInfo: VolumeInfo, reader: PrivilegedDiskReading) async -> [FreeSpaceRange]? {
        let mapper: FreeSpaceMapping?
        
        switch volumeInfo.filesystemType {
        case .fat32:
            mapper = FATAllocationTable(reader: reader)
        case .apfs:
            mapper = APFSSpaceManager(reader: reader)
        default:
            mapper = nil
        }
        
        guard let mapper else { return nil }
        
        do {
            var ranges: [FreeSpaceRange] = []
            for try await range in mapper.freeSpaceRanges() {
                ranges.append(range)
            }
            // Sort to ensure monotonic progression
            ranges.sort { $0.startOffset < $1.startOffset }
            
            let totalFree = ranges.reduce(0) { $0 + $1.length }
            logInfo("Successfully loaded free-space map: \(ranges.count) contiguous ranges, total unallocated \(totalFree / (1024 * 1024)) MB")
            return ranges.isEmpty ? nil : ranges
        } catch {
            logWarning("Failed to build free-space map for \(volumeInfo.filesystemType.displayName): \(error.localizedDescription). Proceeding with standard contiguous scan.")
            return nil
        }
    }

    private func makeInitialScanLoopState(
        volumeInfo: VolumeInfo,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        freeSpaceRanges: [FreeSpaceRange]?
    ) -> ScanLoopState {
        let chunkSectors = initialChunkSectors(for: volumeInfo.blockSize)
        let chunkSize = Self.sectorSize * chunkSectors
        let alignedStartOffset = startOffset - (startOffset % UInt64(Self.sectorSize))

        var scanAccumulator = ScanAccumulator(
            filesFound: 0,
            tracker: CandidateTracker(
                allOffsets: existingOffsets,
                offsetBloom: RollingOffsetBloomFilter(capacityBits: Self.bloomCapacityBits),
                claimedRanges: []
            )
        )
        for offset in existingOffsets {
            scanAccumulator.tracker.offsetBloom.insert(offset)
        }

        return ScanLoopState(
            currentChunkSectors: chunkSectors,
            chunkSize: chunkSize,
            buffer: [UInt8](repeating: 0, count: chunkSize + Self.maxSignatureLength),
            bytesScanned: alignedStartOffset,
            scanAccumulator: scanAccumulator,
            lastProgressReport: -1,
            lastCheckpointOffset: alignedStartOffset,
            carryOver: 0,
            chunkReadCount: 0,
            lastLoggedProgressDecile: -1,
            freeSpaceRanges: freeSpaceRanges,
            currentRangeIndex: freeSpaceRanges != nil ? 0 : nil
        )
    }

    private func runScanLoop(
        state: inout ScanLoopState,
        carvers: inout ActiveCarvers,
        runtime: ScanRuntimeContext
    ) async throws {
        while state.bytesScanned < runtime.totalBytes {
            try Task.checkCancellation()
            
            guard advanceToNextFreeSpaceIfNeeded(state: &state, totalBytes: runtime.totalBytes) else {
                break
            }
            
            ensureBufferCapacity(state: &state)

            guard let chunk = readNextChunk(state: &state, runtime: runtime) else {
                if state.chunkReadCount == 0 {
                    let diagnostic =
                        runtime.reader.lastReadFailureDescription ?? "no reader diagnostic available"
                    throw DeepScanError.cannotReadDevice(
                        path: runtime.devicePath,
                        offset: state.bytesScanned,
                        reason:
                        "No data could be read. seekable=\(runtime.reader.isSeekable). " +
                            "diagnostic=\(diagnostic)"
                    )
                }
                logWarning(
                    "Stopping deep scan loop due to zero/negative read " +
                        "offset=\(state.bytesScanned) " +
                        "chunks=\(state.chunkReadCount)"
                )
                break
            }

            processFilesystemCarvers(
                carvers: &carvers,
                chunk: chunk,
                state: &state,
                runtime: runtime
            )

            let detectedMatches = await processMagicByteScan(
                chunk: chunk,
                state: &state,
                runtime: runtime
            )

            updateLoopStateAfterChunk(
                chunk: chunk,
                detectedMatches: detectedMatches,
                state: &state
            )

            await emitProgressAndCheckpointIfNeeded(
                state: &state,
                totalBytes: runtime.totalBytes,
                continuation: runtime.continuation
            )
        }
    }

    private func processFilesystemCarvers(
        carvers: inout ActiveCarvers,
        chunk: ChunkReadResult,
        state: inout ScanLoopState,
        runtime: ScanRuntimeContext
    ) {
        let chunkStart = state.bytesScanned > UInt64(chunk.readOffset)
            ? state.bytesScanned - UInt64(chunk.readOffset)
            : 0
        let candidates = carveCandidates(
            carvers: &carvers,
            buffer: state.buffer,
            scanLength: chunk.scanLength,
            chunkStart: chunkStart
        )

        for candidate in candidates {
            if state.scanAccumulator.tracker.allOffsets.contains(candidate.offsetOnDisk) {
                continue
            }
            processCarvedFile(
                candidate: candidate,
                reader: runtime.reader,
                scanAccumulator: &state.scanAccumulator,
                totalBytes: runtime.totalBytes,
                continuation: runtime.continuation
            )
        }
    }

    private func carveCandidates(
        carvers: inout ActiveCarvers,
        buffer: [UInt8],
        scanLength: Int,
        chunkStart: UInt64
    ) -> [CarvedCandidate] {
        buffer.withUnsafeBytes { rawBuffer in
            let slice = UnsafeRawBufferPointer(rebasing: rawBuffer[0 ..< scanLength])

            if var fatCarver = carvers.fat {
                let carved = fatCarver.carveChunk(buffer: slice, baseOffset: chunkStart)
                carvers.fat = fatCarver
                return carved.map { file in
                    CarvedCandidate(
                        fileName: file.fileName,
                        fileExtension: file.fileExtension,
                        sizeInBytes: file.sizeInBytes,
                        offsetOnDisk: file.offsetOnDisk
                    )
                }
            }

            if let apfsCarver = carvers.apfs {
                return apfsCarver.carveChunk(buffer: slice, baseOffset: chunkStart).map { file in
                    CarvedCandidate(
                        fileName: file.fileName,
                        fileExtension: file.fileExtension,
                        sizeInBytes: file.sizeInBytes,
                        offsetOnDisk: file.offsetOnDisk
                    )
                }
            }

            if let hfsPlusCarver = carvers.hfsPlus {
                return hfsPlusCarver.carveChunk(buffer: slice, baseOffset: chunkStart).map { file in
                    CarvedCandidate(
                        fileName: file.fileName,
                        fileExtension: file.fileExtension,
                        sizeInBytes: file.sizeInBytes,
                        offsetOnDisk: file.offsetOnDisk
                    )
                }
            }

            return []
        }
    }

    private func processMagicByteScan(
        chunk: ChunkReadResult,
        state: inout ScanLoopState,
        runtime: ScanRuntimeContext
    ) async -> Int {
        let maxContiguousEndOffset: UInt64
        if let ranges = state.freeSpaceRanges, let index = state.currentRangeIndex, index < ranges.count {
            maxContiguousEndOffset = ranges[index].endOffset
        } else {
            maxContiguousEndOffset = runtime.totalBytes
        }
        
        let context = ScanContext(
            buffer: state.buffer,
            scanLength: chunk.scanLength,
            readOffset: chunk.readOffset,
            bytesScanned: state.bytesScanned,
            cameraProfile: runtime.cameraProfile,
            totalBytes: runtime.totalBytes,
            maxContiguousEndOffset: maxContiguousEndOffset
        )

        return await scanChunk(
            context: context,
            reader: runtime.reader,
            scanAccumulator: &state.scanAccumulator,
            continuation: runtime.continuation
        )
    }
}

extension DeepScanService {
    private func startReader(for devicePath: String) throws -> any PrivilegedDiskReading {
        let reader = diskReaderFactory(devicePath)
        do {
            try reader.start()
            let successMessage = "Deep reader started successfully for \(devicePath). " +
                "readerType=\(String(reflecting: type(of: reader))) seekable=\(reader.isSeekable)"
            logInfo(successMessage)
            return reader
        } catch {
            let failureDiagnostic = reader.lastReadFailureDescription ?? "nil"
            let failureMessage = "Reader failed \(devicePath): \(error.localizedDescription) " +
                "readerType=\(String(reflecting: type(of: reader))) diagnostic=\(failureDiagnostic)"
            logger.error("\(failureMessage, privacy: .public)")
            throw DeepScanError.cannotOpenDevice(path: devicePath, reason: error.localizedDescription)
        }
    }

    private func ensureBufferCapacity(state: inout ScanLoopState) {
        if state.buffer.count < state.chunkSize + Self.maxSignatureLength {
            state.buffer = [UInt8](repeating: 0, count: state.chunkSize + Self.maxSignatureLength)
            state.carryOver = 0
        }
    }

    private func readNextChunk(
        state: inout ScanLoopState,
        runtime: ScanRuntimeContext
    ) -> ChunkReadResult? {
        let maxAvailableBytes: UInt64
        if let ranges = state.freeSpaceRanges, let index = state.currentRangeIndex, index < ranges.count {
            maxAvailableBytes = ranges[index].endOffset - state.bytesScanned
        } else {
            maxAvailableBytes = runtime.totalBytes - state.bytesScanned
        }
        
        let bytesToRead = min(state.chunkSize, Int(maxAvailableBytes))
        let readOffset = state.carryOver

        let bytesRead = state.buffer.withUnsafeMutableBytes { rawBuffer in
            runtime.reader.read(
                into: rawBuffer.baseAddress! + readOffset,
                offset: state.bytesScanned,
                length: bytesToRead
            )
        }
        guard bytesRead > 0 else {
            let diagnostic = runtime.reader.lastReadFailureDescription ?? "no reader diagnostic available"
            logWarning(
                "Deep read returned bytesRead=\(bytesRead) " +
                    "offset=\(state.bytesScanned) " +
                    "requested=\(bytesToRead) " +
                    "readOffset=\(readOffset) " +
                    "seekable=\(runtime.reader.isSeekable) " +
                    "diagnostic=\(diagnostic)"
            )
            return nil
        }

        if state.chunkReadCount == 0 {
            logInfo(
                "Deep first chunk read succeeded " +
                    "bytesRead=\(bytesRead) " +
                    "requested=\(bytesToRead) " +
                    "offset=\(state.bytesScanned)"
            )
        }

        return ChunkReadResult(
            bytesRead: bytesRead,
            scanLength: readOffset + bytesRead,
            readOffset: readOffset
        )
    }

    private func updateLoopStateAfterChunk(
        chunk: ChunkReadResult,
        detectedMatches: Int,
        state: inout ScanLoopState
    ) {
        state.bytesScanned += UInt64(chunk.bytesRead)
        state.currentChunkSectors = adaptChunkSectors(
            current: state.currentChunkSectors,
            matches: detectedMatches,
            bytesRead: chunk.bytesRead
        )
        state.chunkSize = Self.sectorSize * state.currentChunkSectors
        state.chunkReadCount += 1

        if chunk.scanLength > Self.maxSignatureLength {
            let keepFrom = chunk.scanLength - Self.maxSignatureLength
            for index in 0 ..< Self.maxSignatureLength {
                state.buffer[index] = state.buffer[keepFrom + index]
            }
            state.carryOver = Self.maxSignatureLength
        }
    }

    private func emitProgressAndCheckpointIfNeeded(
        state: inout ScanLoopState,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async {
        let progress = Double(state.bytesScanned) / Double(totalBytes)
        let decile = Int((progress * 10).rounded(.down))
        if decile > state.lastLoggedProgressDecile {
            state.lastLoggedProgressDecile = decile
            logInfo(
                "Deep scan progress \(Int(progress * 100))% " +
                    "bytesScanned=\(state.bytesScanned) " +
                    "filesFound=\(state.scanAccumulator.filesFound)"
            )
        }
        if progress - state.lastProgressReport >= 0.01 {
            continuation.yield(.progress(min(progress, 1.0)))
            state.lastProgressReport = progress
            await Task.yield()
        }

        if state.bytesScanned - state.lastCheckpointOffset >= performanceConfig.checkpointIntervalBytes {
            logInfo("Deep scan checkpoint emitted at offset=\(state.bytesScanned)")
            continuation.yield(.checkpoint(state.bytesScanned))
            state.lastCheckpointOffset = state.bytesScanned
        }
    }

    private func advanceToNextFreeSpaceIfNeeded(state: inout ScanLoopState, totalBytes: UInt64) -> Bool {
        guard let ranges = state.freeSpaceRanges, let index = state.currentRangeIndex else { return true }
        
        guard index < ranges.count else {
            state.bytesScanned = totalBytes
            return false
        }
        
        let currentRange = ranges[index]
        if state.bytesScanned < currentRange.startOffset {
            let skipAmount = currentRange.startOffset - state.bytesScanned
            if skipAmount > 1024 * 1024 { // Only log significant skips
                logInfo("Skipping \(skipAmount / (1024 * 1024)) MB of allocated space to next free block at \(currentRange.startOffset)")
            }
            
            state.bytesScanned = currentRange.startOffset
            state.carryOver = 0
            state.buffer = [UInt8](repeating: 0, count: state.chunkSize + Self.maxSignatureLength)
        }
        
        if state.bytesScanned >= currentRange.endOffset {
            state.currentRangeIndex! += 1
            return advanceToNextFreeSpaceIfNeeded(state: &state, totalBytes: totalBytes)
        }
        
        return true
    }
}
