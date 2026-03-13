import Foundation

// swiftlint:disable file_length
extension DeepScanService {
    // swiftlint:disable:next function_body_length function_parameter_count
    func processCarvedFile(
        candidate: CarvedCandidate,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        preferredFreeSpaceRange: FreeSpaceRange?,
        decisionTracer: (any DeepScanDecisionTracing)?
    ) async {
        var header = [UInt8](repeating: 0, count: 16)
        let bytesRead = header.withUnsafeMutableBytes { buffer in
            reader.read(into: buffer.baseAddress!, offset: candidate.offsetOnDisk, length: 16)
        }

        guard bytesRead == 16 else {
            await recordCandidateTrace(
                decisionTracer: decisionTracer,
                candidateSource: "filesystem_carver",
                signature: nil,
                fileName: candidate.fileName,
                fileExtension: candidate.fileExtension,
                offsetOnDisk: candidate.offsetOnDisk,
                sizeInBytes: candidate.sizeInBytes,
                entropy: nil,
                confidenceScore: nil,
                preferredFreeSpaceRange: preferredFreeSpaceRange,
                crossesPreferredBoundary: false,
                estimationMethod: "filesystem_carver",
                maxScanBytes: nil,
                hasInvalidCriticalChunkCRC: nil,
                emissionDecision: "not_evaluated",
                acceptanceDecision: "not_evaluated",
                finalDecision: "rejected",
                reason: "header_short_read"
            )
            return
        }

        guard let signature = verifyMagicBytes(header, expectedExtension: candidate.fileExtension) else {
            await recordCandidateTrace(
                decisionTracer: decisionTracer,
                candidateSource: "filesystem_carver",
                signature: nil,
                fileName: candidate.fileName,
                fileExtension: candidate.fileExtension,
                offsetOnDisk: candidate.offsetOnDisk,
                sizeInBytes: candidate.sizeInBytes,
                entropy: shannonEntropy(of: header),
                confidenceScore: nil,
                preferredFreeSpaceRange: preferredFreeSpaceRange,
                crossesPreferredBoundary: false,
                estimationMethod: "filesystem_carver",
                maxScanBytes: nil,
                hasInvalidCriticalChunkCRC: nil,
                emissionDecision: "not_evaluated",
                acceptanceDecision: "not_evaluated",
                finalDecision: "rejected",
                reason: "signature_verification_failed"
            )
            return
        }

        let entropy = shannonEntropy(of: header)
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
                entropy: entropy,
                hasStructureSignal: candidate.sizeInBytes > 0
            )
        )
        let emissionDecision = emissionDecision(for: file)
        let acceptanceDecision = if emissionDecision.shouldEmit {
            candidateAcceptanceDecision(
                offset: candidate.offsetOnDisk,
                sizeInBytes: candidate.sizeInBytes,
                maxContiguousEndOffset: totalBytes,
                tracker: scanAccumulator.tracker
            )
        } else {
            CandidateAcceptanceDecision(canAccept: false, reason: "not_evaluated")
        }
        let finalDecision = emissionDecision.shouldEmit && acceptanceDecision.canAccept ? "accepted" : "rejected"
        let finalReason = emissionDecision.shouldEmit ? acceptanceDecision.reason : emissionDecision.reason

        await recordCandidateTrace(
            decisionTracer: decisionTracer,
            candidateSource: "filesystem_carver",
            signature: signature,
            fileName: candidate.fileName,
            fileExtension: candidate.fileExtension,
            offsetOnDisk: candidate.offsetOnDisk,
            sizeInBytes: candidate.sizeInBytes,
            entropy: entropy,
            confidenceScore: file.confidenceScore,
            preferredFreeSpaceRange: preferredFreeSpaceRange,
            crossesPreferredBoundary: false,
            estimationMethod: "filesystem_carver",
            maxScanBytes: nil,
            hasInvalidCriticalChunkCRC: nil,
            emissionDecision: emissionDecision.reason,
            acceptanceDecision: acceptanceDecision.reason,
            finalDecision: finalDecision,
            reason: finalReason
        )

        guard emissionDecision.shouldEmit, acceptanceDecision.canAccept else {
            return
        }

        registerCandidate(
            offset: candidate.offsetOnDisk,
            sizeInBytes: candidate.sizeInBytes,
            tracker: &scanAccumulator.tracker
        )
        scanAccumulator.filesFound += 1
        continuation.yield(.fileFound(file))
    }

    func scanChunk(
        context: ScanContext,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        decisionTracer: (any DeepScanDecisionTracing)?
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
                continuation: continuation,
                decisionTracer: decisionTracer
            )
        }

        return matches.count
    }

    // swiftlint:disable:next function_body_length function_parameter_count
    func processMatch(
        _ matchEntry: (Int, FileSignature),
        context: ScanContext,
        reader: PrivilegedDiskReading,
        scanAccumulator: inout ScanAccumulator,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        decisionTracer: (any DeepScanDecisionTracing)?
    ) async {
        let (index, signature) = matchEntry
        let offset = context.bytesScanned + UInt64(index) - UInt64(context.readOffset)
        if scanAccumulator.tracker.offsetBloom.probablyContains(offset),
           scanAccumulator.tracker.allOffsets.contains(offset)
        {
            let candidateNumber = scanAccumulator.filesFound + 1
            let fileName = extractCandidateFileName(
                signature: signature,
                context: context,
                index: index,
                candidateNumber: candidateNumber
            )
            await recordCandidateTrace(
                decisionTracer: decisionTracer,
                candidateSource: "magic_scan",
                signature: signature,
                fileName: fileName,
                fileExtension: signature.fileExtension,
                offsetOnDisk: offset,
                sizeInBytes: nil,
                entropy: nil,
                confidenceScore: nil,
                preferredFreeSpaceRange: context.preferredFreeSpaceRange,
                crossesPreferredBoundary: false,
                estimationMethod: "not_evaluated",
                maxScanBytes: nil,
                hasInvalidCriticalChunkCRC: nil,
                emissionDecision: "not_evaluated",
                acceptanceDecision: "duplicate_offset",
                finalDecision: "rejected",
                reason: "duplicate_offset"
            )
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
        let crossesPreferredBoundary = candidateCrossesPreferredBoundary(
            offset: offset,
            sizeInBytes: sizeInBytes,
            preferredEndOffset: context.maxContiguousEndOffset
        )
        var score = confidenceScore(
            signature: signature,
            sizeInBytes: sizeInBytes,
            entropy: entropy,
            hasStructureSignal: true,
            hasInvalidPNGCriticalChunkCRC: hasInvalidCriticalChunkCRC
        )
        if crossesPreferredBoundary {
            score = min(score, Self.crossRangeConfidenceCap)
        }

        let file = RecoverableFile(
            id: UUID(),
            fileName: fileName,
            fileExtension: signature.fileExtension,
            fileType: signature.category,
            sizeInBytes: sizeInBytes,
            offsetOnDisk: offset,
            signatureMatch: signature,
            source: .deepScan,
            isLikelyContiguous: sizeInBytes > 0 && fragmentMap == nil && !crossesPreferredBoundary,
            confidenceScore: score,
            fragmentMap: fragmentMap
        )
        let emissionDecision = emissionDecision(for: file, entropy: entropy)
        let acceptanceDecision = if emissionDecision.shouldEmit {
            candidateAcceptanceDecision(
                offset: offset,
                sizeInBytes: sizeInBytes,
                maxContiguousEndOffset: crossesPreferredBoundary ? context.totalBytes : context.maxContiguousEndOffset,
                tracker: scanAccumulator.tracker
            )
        } else {
            CandidateAcceptanceDecision(canAccept: false, reason: "not_evaluated")
        }
        let finalDecision = emissionDecision.shouldEmit && acceptanceDecision.canAccept ? "accepted" : "rejected"
        let finalReason = emissionDecision.shouldEmit ? acceptanceDecision.reason : emissionDecision.reason

        await recordCandidateTrace(
            decisionTracer: decisionTracer,
            candidateSource: "magic_scan",
            signature: signature,
            fileName: fileName,
            fileExtension: signature.fileExtension,
            offsetOnDisk: offset,
            sizeInBytes: sizeInBytes,
            entropy: entropy,
            confidenceScore: score,
            preferredFreeSpaceRange: context.preferredFreeSpaceRange,
            crossesPreferredBoundary: crossesPreferredBoundary,
            estimationMethod: candidateEstimation.estimationMethod,
            maxScanBytes: candidateEstimation.maxScanBytes,
            hasInvalidCriticalChunkCRC: hasInvalidCriticalChunkCRC,
            emissionDecision: emissionDecision.reason,
            acceptanceDecision: acceptanceDecision.reason,
            finalDecision: finalDecision,
            reason: finalReason
        )

        guard emissionDecision.shouldEmit, acceptanceDecision.canAccept else {
            return
        }

        registerCandidate(offset: offset, sizeInBytes: sizeInBytes, tracker: &scanAccumulator.tracker)
        scanAccumulator.filesFound += 1
        continuation.yield(.fileFound(file))
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
        var estimate = CandidateEstimation(
            sizeInBytes: 0,
            hasInvalidCriticalChunkCRC: false,
            estimationMethod: "none",
            maxScanBytes: nil
        )

        // Sizing can read past the preferred free-space boundary so boundary-crossing
        // candidates still get a full estimate. Acceptance later decides confidence.
        let availableDeviceBytesUInt = context.totalBytes > offset ? context.totalBytes - offset : 0
        let maxAllowedBytes = min(Int(32 * 1024 * 1024), Int(min(availableDeviceBytesUInt, UInt64(Int.max))))
        estimate.maxScanBytes = maxAllowedBytes

        if signature == .png,
           let pngEstimate = try? await fileFooterDetector.estimatePNGSize(
               startOffset: offset,
               reader: reader,
               maxScanBytes: maxAllowedBytes,
               validateCriticalChunkCRCs: true
           )
        {
            estimate.sizeInBytes = pngEstimate.sizeInBytes
            estimate.hasInvalidCriticalChunkCRC = pngEstimate.hasInvalidCriticalChunkCRC
            estimate.estimationMethod = "png_footer_detector"
        }

        let footerDetectableSignatures: Set<FileSignature> = [.jpeg, .gif, .bmp, .webp]
        if footerDetectableSignatures.contains(signature),
           let estimatedSize = try? await fileFooterDetector.estimateSize(
               signature: signature,
               startOffset: offset,
               reader: reader,
               maxScanBytes: maxAllowedBytes
           )
        {
            estimate.sizeInBytes = estimatedSize
            estimate.estimationMethod = "footer_detector"
        }

        let mp4LikeSignatures: Set<FileSignature> = [.mp4, .mov, .m4v, .threeGP, .heic, .heif, .avif, .cr3]
        if mp4LikeSignatures.contains(signature) {
            let mp4Reconstructor = MP4Reconstructor()
            if let contiguousSize = mp4Reconstructor.calculateContiguousSize(startingAt: offset, reader: reader) {
                estimate.sizeInBytes = Int64(contiguousSize)
                estimate.estimationMethod = "mp4_reconstructor"
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
                estimate.estimationMethod = "image_reconstructor"
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
        maxContiguousEndOffset: UInt64,
        tracker: CandidateTracker
    ) -> Bool {
        candidateAcceptanceDecision(
            offset: offset,
            sizeInBytes: sizeInBytes,
            maxContiguousEndOffset: maxContiguousEndOffset,
            tracker: tracker
        ).canAccept
    }

    func candidateAcceptanceDecision(
        offset: UInt64,
        sizeInBytes: Int64,
        maxContiguousEndOffset: UInt64,
        tracker: CandidateTracker
    ) -> CandidateAcceptanceDecision {
        if tracker.offsetBloom.probablyContains(offset), tracker.allOffsets.contains(offset) {
            return CandidateAcceptanceDecision(canAccept: false, reason: "duplicate_offset")
        }

        if let candidateRange = buildCandidateRange(
            offset: offset,
            sizeInBytes: sizeInBytes,
            totalBytes: maxContiguousEndOffset
        ) {
            if candidateRange.endExclusive > maxContiguousEndOffset {
                return CandidateAcceptanceDecision(canAccept: false, reason: "exceeds_boundary")
            }

            for range in tracker.claimedRanges {
                if rangesOverlap(candidateRange, range) {
                    return CandidateAcceptanceDecision(canAccept: false, reason: "overlaps_claimed_range")
                }
            }
        } else {
            if tracker.claimedRanges.contains(where: { offset >= $0.start && offset < $0.endExclusive }) {
                return CandidateAcceptanceDecision(canAccept: false, reason: "offset_inside_claimed_range")
            }
        }

        return CandidateAcceptanceDecision(canAccept: true, reason: "accepted")
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

    func candidateCrossesPreferredBoundary(
        offset: UInt64,
        sizeInBytes: Int64,
        preferredEndOffset: UInt64
    ) -> Bool {
        guard sizeInBytes > 0 else { return false }
        let size = UInt64(sizeInBytes)
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow else { return false }
        return end > preferredEndOffset
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

    // swiftlint:disable:next function_parameter_count
    func recordCandidateTrace(
        decisionTracer: (any DeepScanDecisionTracing)?,
        candidateSource: String,
        signature: FileSignature?,
        fileName: String?,
        fileExtension: String?,
        offsetOnDisk: UInt64,
        sizeInBytes: Int64?,
        entropy: Double?,
        confidenceScore: Double?,
        preferredFreeSpaceRange: FreeSpaceRange?,
        crossesPreferredBoundary: Bool,
        estimationMethod: String,
        maxScanBytes: Int?,
        hasInvalidCriticalChunkCRC: Bool?,
        emissionDecision: String,
        acceptanceDecision: String,
        finalDecision: String,
        reason: String
    ) async {
        guard let decisionTracer else { return }

        let allocationState = if let preferredFreeSpaceRange {
            if offsetOnDisk >= preferredFreeSpaceRange.startOffset, offsetOnDisk < preferredFreeSpaceRange.endOffset {
                "free"
            } else {
                "outside_preferred_free_range"
            }
        } else {
            "unknown"
        }

        await decisionTracer.record(
            DeepScanTraceRecord(
                timestamp: Date(),
                event: "candidate_decision",
                devicePath: nil,
                filesystem: nil,
                totalBytes: nil,
                freeSpaceRangeCount: nil,
                filesFound: nil,
                scanOffset: nil,
                nextOffset: nil,
                skippedBytes: nil,
                candidateSource: candidateSource,
                signature: signature?.rawValue,
                fileName: fileName,
                fileExtension: fileExtension,
                offsetOnDisk: offsetOnDisk,
                estimatedSizeInBytes: sizeInBytes,
                entropy: entropy,
                confidenceScore: confidenceScore,
                allocationState: allocationState,
                preferredRangeStartOffset: preferredFreeSpaceRange?.startOffset,
                preferredRangeEndOffset: preferredFreeSpaceRange?.endOffset,
                crossesPreferredBoundary: crossesPreferredBoundary,
                estimationMethod: estimationMethod,
                maxScanBytes: maxScanBytes,
                hasInvalidCriticalChunkCRC: hasInvalidCriticalChunkCRC,
                emissionDecision: emissionDecision,
                acceptanceDecision: acceptanceDecision,
                finalDecision: finalDecision,
                reason: reason
            )
        )
    }
}

extension DeepScanService {
    struct CandidateAcceptanceDecision {
        let canAccept: Bool
        let reason: String
    }
}
