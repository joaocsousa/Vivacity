import Foundation

extension DeepScanService {
    func processCarvedFile(
        candidate: CarvedCandidate,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) {
        var header = [UInt8](repeating: 0, count: 16)
        let bytesRead = header.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: candidate.offsetOnDisk, length: 16)
        }

        if bytesRead == 16 {
            if let signature = verifyMagicBytes(header, expectedExtension: candidate.fileExtension) {
                let file = RecoverableFile(
                    id: UUID(),
                    fileName: candidate.fileName,
                    fileExtension: candidate.fileExtension,
                    fileType: signature.category,
                    sizeInBytes: candidate.sizeInBytes,
                    offsetOnDisk: candidate.offsetOnDisk,
                    signatureMatch: signature,
                    source: .deepScan,
                    isLikelyContiguous: candidate.sizeInBytes > 0,
                    confidenceScore: confidenceScore(
                        signature: signature,
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

    func scanChunk(
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

    func processMatch(
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

    func extractCandidateFileName(
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

    func estimateCandidateSize(
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

    func sampleEntropy(buffer: [UInt8], scanLength: Int, index: Int) -> Double {
        let availableBytes = scanLength - index
        let entropySampleLength = min(max(availableBytes, 0), Self.entropySampleBytes)
        guard entropySampleLength > 0 else { return shannonEntropy(of: []) }
        let entropyBytes = Array(buffer[index ..< index + entropySampleLength])
        return shannonEntropy(of: entropyBytes)
    }

    func detectMatchesInParallel(
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
                    for position in slice {
                        if let signature = matchSignatureAt(
                            buffer: buffer,
                            position: position,
                            cameraProfile: cameraProfile
                        ) {
                            local.append((position, signature))
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

    func initialChunkSectors(for blockSize: Int) -> Int {
        let blockMultiplier = max(1, blockSize / Self.sectorSize)
        let desired = Self.baseReadChunkSectors * blockMultiplier
        return min(max(desired, performanceConfig.minChunkSectors), performanceConfig.maxChunkSectors)
    }

    func adaptChunkSectors(current: Int, matches: Int, bytesRead: Int) -> Int {
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

    func canAcceptCandidate(
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
            if tracker.claimedRanges.contains(where: { offset >= $0.start && offset < $0.endExclusive }) {
                return false
            }
        }

        return true
    }

    func registerCandidate(
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

    func buildCandidateRange(offset: UInt64, sizeInBytes: Int64, totalBytes: UInt64) -> ClaimedRange? {
        guard sizeInBytes > 0 else { return nil }
        let size = UInt64(sizeInBytes)
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow else { return nil }
        if totalBytes != UInt64.max, end > totalBytes {
            return ClaimedRange(start: offset, endExclusive: end)
        }
        return ClaimedRange(start: offset, endExclusive: end)
    }

    func rangesOverlap(_ lhs: ClaimedRange, _ rhs: ClaimedRange) -> Bool {
        lhs.start < rhs.endExclusive && rhs.start < lhs.endExclusive
    }
}
