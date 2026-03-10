import Foundation

// MARK: - Scan Internals

extension FileScanViewModel {
    func startUnifiedScan(
        device: StorageDevice,
        startOffset: UInt64,
        seedFiles: [RecoverableFile],
        includeFastWorker: Bool,
        includeDeepWorker: Bool
    ) {
        scanTask?.cancel()
        stopSessionAutoSave()

        scanPhase = .scanning
        progress = min(
            max(Double(startOffset) / max(Double(device.totalCapacity), 1), 0),
            1
        )
        estimatedTimeRemaining = nil
        scanDuration = nil
        errorMessage = nil
        permissionDenied = false
        if includeDeepWorker {
            setScanAccessState(.fullScan)
        } else {
            setScanAccessState(.limitedOnly)
        }

        foundFiles = seedFiles
        selectedFileIDs = Set(seedFiles.filter { $0.recoveryConfidence != .low }.map(\.id))
        previewFileID = foundFiles.first?.id

        initializeDedupeIndexes()

        lastDeepScanOffset = startOffset
        hasCompletedFastWorker = !includeFastWorker
        hasCompletedDeepWorker = !includeDeepWorker
        latestFastProgress = 0
        scanStartTime = Date()
        fastWorkerStartTime = nil
        deepWorkerStartTime = nil
        etaLastOffset = startOffset
        etaLastTimestamp = nil
        smoothedThroughputBytesPerSecond = nil
        lastLoggedFastProgressDecile = -1
        lastLoggedDeepProgressDecile = -1
        fastFilesEmittedCount = 0
        deepFilesEmittedCount = 0

        cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
        logInfo(
            "Unified scan started for '\(device.name)' includeFast=\(includeFastWorker) " +
                "includeDeep=\(includeDeepWorker) " +
                "startOffset=\(startOffset) seedFiles=\(seedFiles.count) " +
                "initialProgress=\(String(format: "%.3f", progress))"
        )
        startSessionAutoSave(device: device)

        scanTask = Task { [weak self] in
            guard let self else { return }
            logger.info("Launching fast and deep worker tasks")
            async let fastOutcome = runFastScanIfNeeded(
                device: device,
                shouldRun: includeFastWorker
            )
            async let deepOutcome = runDeepScanIfNeeded(
                device: device,
                startOffset: startOffset,
                shouldRun: includeDeepWorker
            )

            let (fastResult, deepResult) = await (fastOutcome, deepOutcome)
            finishUnifiedScan(fastOutcome: fastResult, deepOutcome: deepResult)
        }
    }

    private func runDeepScanIfNeeded(
        device: StorageDevice,
        startOffset: UInt64,
        shouldRun: Bool
    ) async -> WorkerOutcome {
        guard shouldRun else {
            logInfo("Deep worker skipped (limited scan mode)")
            return .success
        }
        return await runDeepScan(device: device, startOffset: startOffset)
    }

    private func runFastScanIfNeeded(
        device: StorageDevice,
        shouldRun: Bool
    ) async -> WorkerOutcome {
        guard shouldRun else {
            logInfo("Fast worker skipped (resume flow)")
            return .success
        }

        fastWorkerStartTime = Date()
        logInfo("Fast worker started for '\(device.name)'")
        do {
            let stream = fastScanService.scan(device: device)
            logInfo("Fast worker stream created")
            for try await event in stream {
                try Task.checkCancellation()
                handleFastScanEvent(event)
            }
            hasCompletedFastWorker = true
            cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
            logInfo(
                "Fast worker finished emittedFiles=\(fastFilesEmittedCount) " +
                    "elapsed=\(elapsedSeconds(since: fastWorkerStartTime))s " +
                    "latestProgress=\(String(format: "%.3f", latestFastProgress))"
            )
            return .success
        } catch is CancellationError {
            hasCompletedFastWorker = true
            logInfo(
                "Fast worker cancelled emittedFiles=\(fastFilesEmittedCount) " +
                    "elapsed=\(elapsedSeconds(since: fastWorkerStartTime))s"
            )
            return .success
        } catch {
            hasCompletedFastWorker = true
            logError("Fast scan worker error: \(error.localizedDescription)")
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
            return .failed("Fast scan warning: \(error.localizedDescription)")
        }
    }

    private func runDeepScan(
        device: StorageDevice,
        startOffset: UInt64
    ) async -> WorkerOutcome {
        deepWorkerStartTime = Date()
        etaLastTimestamp = deepWorkerStartTime
        do {
            let existingOffsets = Set(foundFiles.map(\.offsetOnDisk).filter { $0 > 0 })
            logInfo(
                "Deep worker started for '\(device.name)' startOffset=\(startOffset) " +
                    "existingOffsets=\(existingOffsets.count)"
            )
            let stream = deepScanService.scan(
                device: device,
                existingOffsets: existingOffsets,
                startOffset: startOffset,
                cameraProfile: cameraProfile
            )

            logInfo("Deep worker stream created")
            for try await event in stream {
                try Task.checkCancellation()
                handleDeepScanEvent(
                    event,
                    totalBytes: UInt64(device.totalCapacity)
                )
            }

            hasCompletedDeepWorker = true
            if hasCompletedFastWorker {
                progress = 1
                estimatedTimeRemaining = nil
            } else {
                progress = max(progress, 0.99)
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
            logInfo(
                "Deep worker finished emittedFiles=\(deepFilesEmittedCount) " +
                    "lastOffset=\(lastDeepScanOffset) " +
                    "elapsed=\(elapsedSeconds(since: deepWorkerStartTime))s"
            )
            return .success
        } catch is CancellationError {
            hasCompletedDeepWorker = true
            logInfo(
                "Deep worker cancelled emittedFiles=\(deepFilesEmittedCount) " +
                    "lastOffset=\(lastDeepScanOffset) " +
                    "elapsed=\(elapsedSeconds(since: deepWorkerStartTime))s"
            )
            return .success
        } catch {
            hasCompletedDeepWorker = true
            let message = error.localizedDescription
            let classifiedAsPermissionDenied = isPermissionDeniedError(message)
            let errorType = String(reflecting: type(of: error))
            logError(
                "Deep worker failed classifiedPermissionDenied=\(classifiedAsPermissionDenied) " +
                    "errorType=\(errorType) message=\(message)"
            )
            if classifiedAsPermissionDenied {
                permissionDenied = true
                if shouldRouteToOfflineImage(for: device, reason: message) {
                    let offlineImageMessage =
                        "macOS denied live raw reads of this startup APFS volume, even through the helper. " +
                        "Create the image from Recovery Mode or another boot volume, then load that image here.\n\n" +
                        "Latest error: \(message)"
                    setScanAccessState(
                        .imageRequired,
                        message: offlineImageMessage
                    )
                    return .failed("Deep scan image required: \(message)")
                }

                let imageRecommendedMessage =
                    "Full raw-disk access is currently unavailable for this device. " +
                    "Create or load a byte-to-byte image for the best recovery results, " +
                    "or continue with a limited scan.\n\n" +
                    "Latest error: \(message)"
                setScanAccessState(
                    .imageRecommended,
                    message: imageRecommendedMessage
                )
                return .failed("Deep scan permission denied: \(message)")
            }
            return .failed("Deep scan error: \(message)")
        }
    }

    private func finishUnifiedScan(
        fastOutcome: WorkerOutcome,
        deepOutcome: WorkerOutcome
    ) {
        var messages: [String] = []
        if case let .failed(message) = deepOutcome {
            messages.append(message)
        }
        if case let .failed(message) = fastOutcome {
            messages.append(message)
        }
        if !messages.isEmpty, !permissionDenied {
            errorMessage = messages.joined(separator: "\n")
        }

        logInfo(
            "Unified scan worker outcomes fast=\(describe(outcome: fastOutcome)) " +
                "deep=\(describe(outcome: deepOutcome)) errors=\(messages.count)"
        )
        cameraProfile = cameraRecoveryService.detectProfile(from: foundFiles)
        if permissionDenied {
            scanPhase = .idle
            estimatedTimeRemaining = nil
            scanTask = nil
            stopSessionAutoSave()
            logInfo(
                "Unified scan ended in permission-limited mode " +
                    "files=\(foundFiles.count) lastOffset=\(lastDeepScanOffset)"
            )
            return
        }
        if scanPhase == .scanning {
            let forceComplete = !messages.contains {
                $0.hasPrefix("Deep scan error:")
            }
            markScanCompleted(forceProgressToFull: forceComplete)
        }
        scanTask = nil
    }

    private func handleFastScanEvent(_ event: ScanEvent) {
        switch event {
        case let .fileFound(file):
            fastFilesEmittedCount += 1
            mergeFoundFile(file)
            if shouldLogFileEvent(count: fastFilesEmittedCount) {
                logInfo(
                    "Fast file #\(fastFilesEmittedCount) name='\(file.fullFileName)' " +
                        "offset=\(file.offsetOnDisk) totalFound=\(foundFiles.count)"
                )
            }
        case let .progress(value):
            latestFastProgress = min(max(value, 0), 1)
            let decile = Int((latestFastProgress * 10).rounded(.down))
            if decile > lastLoggedFastProgressDecile {
                lastLoggedFastProgressDecile = decile
                logInfo(
                    "Fast progress=\(decile * 10)% latest=\(String(format: "%.3f", latestFastProgress)) " +
                        "files=\(fastFilesEmittedCount)"
                )
            }
            if hasCompletedDeepWorker, !hasCompletedFastWorker {
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
        case .checkpoint:
            logInfo("Fast worker checkpoint")
        case .completed:
            hasCompletedFastWorker = true
            logInfo(
                "Fast worker completed event emittedFiles=\(fastFilesEmittedCount)"
            )
            if hasCompletedDeepWorker {
                estimatedTimeRemaining = nil
            }
        }
    }

    private func handleDeepScanEvent(_ event: ScanEvent, totalBytes: UInt64) {
        switch event {
        case let .fileFound(file):
            deepFilesEmittedCount += 1
            mergeFoundFile(file)
            if shouldLogFileEvent(count: deepFilesEmittedCount) {
                logInfo(
                    "Deep file #\(deepFilesEmittedCount) name='\(file.fullFileName)' " +
                        "offset=\(file.offsetOnDisk) totalFound=\(foundFiles.count)"
                )
            }
        case let .progress(value):
            updateProgressAndETA(
                normalizedProgress: value,
                offsetHint: lastDeepScanOffset,
                totalBytes: totalBytes
            )
            let decile = Int((progress * 10).rounded(.down))
            if decile > lastLoggedDeepProgressDecile {
                lastLoggedDeepProgressDecile = decile
                logInfo(
                    "Deep progress=\(decile * 10)% uiProgress=\(String(format: "%.3f", progress)) " +
                        "lastOffset=\(lastDeepScanOffset)"
                )
            }
        case let .checkpoint(offset):
            lastDeepScanOffset = offset
            let normalized = Double(offset) / max(Double(totalBytes), 1)
            updateProgressAndETA(
                normalizedProgress: normalized,
                offsetHint: offset,
                totalBytes: totalBytes
            )
            logInfo(
                "Deep checkpoint offset=\(offset) progress=\(String(format: "%.3f", progress))"
            )
        case .completed:
            hasCompletedDeepWorker = true
            logInfo(
                "Deep worker completed event emittedFiles=\(deepFilesEmittedCount) " +
                    "lastOffset=\(lastDeepScanOffset)"
            )
            if hasCompletedFastWorker {
                updateProgressAndETA(
                    normalizedProgress: 1,
                    offsetHint: totalBytes,
                    totalBytes: totalBytes
                )
            } else {
                progress = max(progress, 0.99)
                estimatedTimeRemaining = estimateFastRemainingTime()
            }
        }
    }

    private func mergeFoundFile(_ file: RecoverableFile) {
        if file.offsetOnDisk > 0 {
            if let existingIndex = fileIndexByOffset[file.offsetOnDisk],
               foundFiles.indices.contains(existingIndex)
            {
                let existing = foundFiles[existingIndex]
                if shouldPrefer(file, over: existing) {
                    let wasSelected = selectedFileIDs.contains(existing.id)
                    let wasPreviewed = previewFileID == existing.id

                    selectedFileIDs.remove(existing.id)
                    foundFiles[existingIndex] = file

                    if wasSelected || file.recoveryConfidence != .low {
                        selectedFileIDs.insert(file.id)
                    }
                    if wasPreviewed {
                        previewFileID = file.id
                    }
                }
                return
            }
        } else {
            let key = offsetlessKey(for: file)
            if offsetlessKeys.contains(key) {
                return
            }
            offsetlessKeys.insert(key)
        }

        let newIndex = foundFiles.count
        foundFiles.append(file)
        if file.offsetOnDisk > 0 {
            fileIndexByOffset[file.offsetOnDisk] = newIndex
        }
        if previewFileID == nil {
            previewFileID = file.id
        }
        if file.recoveryConfidence != .low {
            selectedFileIDs.insert(file.id)
        }
    }

    private func shouldPrefer(_ newFile: RecoverableFile, over existingFile: RecoverableFile) -> Bool {
        if newFile.source == .fastScan, existingFile.source == .deepScan {
            return true
        }
        if newFile.filePath != nil, existingFile.filePath == nil {
            return true
        }
        if (newFile.confidenceScore ?? 0) > (existingFile.confidenceScore ?? 0) {
            return true
        }
        return false
    }

    private func offsetlessKey(for file: RecoverableFile) -> String {
        if let filePath = file.filePath?.lowercased() {
            return "path:\(filePath)"
        }
        return "name:\(file.fullFileName.lowercased())|size:\(file.sizeInBytes)"
    }

    private func initializeDedupeIndexes() {
        fileIndexByOffset.removeAll(keepingCapacity: true)
        offsetlessKeys.removeAll(keepingCapacity: true)

        for (index, file) in foundFiles.enumerated() {
            if file.offsetOnDisk > 0 {
                fileIndexByOffset[file.offsetOnDisk] = index
            } else {
                offsetlessKeys.insert(offsetlessKey(for: file))
            }
        }
    }

    private func updateProgressAndETA(
        normalizedProgress: Double,
        offsetHint: UInt64,
        totalBytes: UInt64
    ) {
        let clampedProgress = min(max(normalizedProgress, 0), 1)
        progress = max(progress, clampedProgress)

        guard scanPhase == .scanning else {
            estimatedTimeRemaining = nil
            return
        }

        let now = Date()
        let safeOffset = min(offsetHint, totalBytes)

        if let previousOffset = etaLastOffset,
           let previousTimestamp = etaLastTimestamp
        {
            let deltaBytes = Double(max(Int64(safeOffset) - Int64(previousOffset), 0))
            let deltaTime = now.timeIntervalSince(previousTimestamp)
            if deltaBytes > 0, deltaTime > 0.1 {
                let instantaneousThroughput = deltaBytes / deltaTime
                if instantaneousThroughput.isFinite, instantaneousThroughput > 0 {
                    if let previous = smoothedThroughputBytesPerSecond {
                        smoothedThroughputBytesPerSecond =
                            previous * 0.75 + instantaneousThroughput * 0.25
                    } else {
                        smoothedThroughputBytesPerSecond = instantaneousThroughput
                    }
                }
            }
        }

        etaLastOffset = safeOffset
        etaLastTimestamp = now

        if progress >= 0.999 {
            estimatedTimeRemaining = hasCompletedFastWorker ? nil : estimateFastRemainingTime()
            return
        }

        let total = Double(totalBytes)
        let remainingBytes = max(0, total * (1 - progress))
        if let throughput = smoothedThroughputBytesPerSecond,
           throughput > 0
        {
            estimatedTimeRemaining = remainingBytes / throughput
            return
        }

        if let start = deepWorkerStartTime,
           progress > 0.01
        {
            let elapsed = now.timeIntervalSince(start)
            estimatedTimeRemaining = max(0, elapsed * (1 - progress) / progress)
        }
    }

    private func estimateFastRemainingTime() -> TimeInterval? {
        guard let start = fastWorkerStartTime,
              latestFastProgress > 0.01
        else {
            return nil
        }
        let elapsed = Date().timeIntervalSince(start)
        let estimatedTotal = elapsed / latestFastProgress
        return max(0, estimatedTotal - elapsed)
    }

    func markScanCompleted(forceProgressToFull: Bool) {
        if forceProgressToFull {
            progress = 1
        }
        estimatedTimeRemaining = nil
        scanPhase = .complete
        if let startedAt = scanStartTime {
            scanDuration = Date().timeIntervalSince(startedAt)
        }
        logInfo(
            "Unified scan completed forceProgress=\(forceProgressToFull) " +
                "duration=\(elapsedSeconds(since: scanStartTime))s " +
                "files=\(foundFiles.count) selected=\(selectedFileIDs.count) " +
                "lastOffset=\(lastDeepScanOffset)"
        )
        stopSessionAutoSave()
    }

    private func startSessionAutoSave(device: StorageDevice) {
        stopSessionAutoSave()
        logInfo("Session autosave task started for '\(device.name)'")
        sessionAutoSaveTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                logDebug(
                    "Autosave tick progress=\(String(format: "%.3f", progress)) " +
                        "files=\(foundFiles.count) offset=\(lastDeepScanOffset)"
                )
                await saveSession(device: device)
            }
        }
    }

    private func stopSessionAutoSave() {
        if sessionAutoSaveTask != nil {
            logInfo("Session autosave task stopped")
        }
        sessionAutoSaveTask?.cancel()
        sessionAutoSaveTask = nil
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private func logDebug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    private func shouldLogFileEvent(count: Int) -> Bool {
        count <= 20 || count.isMultiple(of: 200)
    }

    private func isPermissionDeniedError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("operation not permitted")
            || normalized.contains("permission denied")
            || normalized.contains("access denied")
            || normalized.contains("not authorized")
    }

    private func elapsedSeconds(since startedAt: Date?) -> Int {
        guard let startedAt else { return -1 }
        return Int(Date().timeIntervalSince(startedAt).rounded())
    }

    private func describe(outcome: WorkerOutcome) -> String {
        switch outcome {
        case .success:
            "success"
        case let .failed(message):
            "failed(\(message))"
        }
    }
}
