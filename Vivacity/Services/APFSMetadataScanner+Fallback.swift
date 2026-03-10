import Foundation

extension APFSMetadataScanner {
    func extractMetadataHints(
        from data: Data,
        absoluteStart: UInt64,
        blockSize: Int
    ) -> [MetadataHint] {
        let bytes = [UInt8](data)
        guard blockSize > 0, bytes.count >= 40 else { return [] }

        var hints = Set<MetadataHint>()
        var blockOffset = 0
        while blockOffset < bytes.count {
            let blockEnd = min(blockOffset + blockSize, bytes.count)
            let block = Array(bytes[blockOffset ..< blockEnd])
            if isLikelyAPFSMetadataBlock(block) {
                let baseOffset = absoluteStart + UInt64(blockOffset)
                for asciiString in extractPrintableStrings(from: block) {
                    guard let hint = makeHint(
                        from: asciiString.value,
                        absoluteOffset: baseOffset + UInt64(asciiString.offset)
                    )
                    else { continue }
                    hints.insert(hint)
                }
            }
            blockOffset += blockSize
        }

        return hints.sorted { lhs, rhs in
            if lhs.absoluteOffset == rhs.absoluteOffset {
                return lhs.path < rhs.path
            }
            return lhs.absoluteOffset < rhs.absoluteOffset
        }
    }

    func isLikelyAPFSMetadataBlock(_ block: [UInt8]) -> Bool {
        guard block.count >= 40 else { return false }
        let blockMagic = magic(in: block, at: 32)
        return blockMagic == "BSXN" || blockMagic == "BSPA"
    }

    func extractPrintableStrings(from block: [UInt8]) -> [(offset: Int, value: String)] {
        var strings: [(Int, String)] = []
        var startIndex: Int?

        func flushString(until endIndex: Int) {
            guard let startIndex, endIndex - startIndex >= 6 else {
                reset()
                return
            }
            let slice = block[startIndex ..< endIndex]
            if let candidate = String(bytes: slice, encoding: .utf8) {
                strings.append((startIndex, candidate))
            }
            reset()
        }

        func reset() {
            startIndex = nil
        }

        for (index, byte) in block.enumerated() {
            if (0x20 ... 0x7E).contains(byte) {
                if startIndex == nil {
                    startIndex = index
                }
            } else if startIndex != nil {
                flushString(until: index)
            }
        }

        if startIndex != nil {
            flushString(until: block.count)
        }

        return strings
    }

    func makeHint(from rawValue: String, absoluteOffset: UInt64) -> MetadataHint? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastComponent = trimmed.split(separator: "/").last else { return nil }
        let fileName = String(lastComponent)
        guard let dotIndex = fileName.lastIndex(of: ".") else { return nil }

        let ext = String(fileName[fileName.index(after: dotIndex)...]).lowercased()
        guard let signature = signature(forExtension: ext), signature.category == .image else {
            return nil
        }

        return MetadataHint(
            absoluteOffset: absoluteOffset,
            path: trimmed,
            fileName: fileName,
            signature: signature
        )
    }

    func detectImageCandidates(
        in data: Data,
        absoluteStart: UInt64,
        dedupeFloor: UInt64
    ) -> [ImageCandidate] {
        let buffer = [UInt8](data)
        guard !buffer.isEmpty else { return [] }

        let candidateStartBytes: Set<UInt8> = [0x00, 0x42, 0x47, 0x49, 0x4D, 0x52, 0x89, 0xFF]
        let startIndex = max(0, Int(dedupeFloor.saturatingSubtract(absoluteStart)))
        var candidates: [ImageCandidate] = []
        var position = startIndex

        while position < buffer.count {
            let byte = buffer[position]
            guard candidateStartBytes.contains(byte) else {
                position += 1
                continue
            }

            if let signature = signatureMatcher.matchSignatureAt(
                buffer: buffer,
                position: position,
                cameraProfile: .generic
            ), signature.category == .image {
                candidates.append(
                    ImageCandidate(
                        absoluteOffset: absoluteStart + UInt64(position),
                        signature: signature
                    )
                )
                position += max(signature.magicBytes.count, 4)
            } else {
                position += 1
            }
        }

        return candidates
    }

    func bestHintIndex(for candidate: ImageCandidate, in hints: [MetadataHint]) -> Int? {
        var bestIndex: Int?
        var bestDistance: UInt64 = .max

        for (index, hint) in hints.enumerated() {
            guard hint.signature == candidate.signature else { continue }
            guard candidate.absoluteOffset >= hint.absoluteOffset else { continue }

            let distance = candidate.absoluteOffset - hint.absoluteOffset
            guard distance <= maxHintDistance else { continue }
            if distance < bestDistance {
                bestIndex = index
                bestDistance = distance
            }
        }

        return bestIndex
    }

    func pruneHints(_ hints: [MetadataHint], minimumOffset: UInt64) -> [MetadataHint] {
        hints.filter { hint in
            hint.absoluteOffset >= minimumOffset.saturatingSubtract(maxHintDistance)
        }
    }

    func emitRecoveredFiles(
        from candidates: [ImageCandidate],
        totalBytes: UInt64,
        recoveryState: inout RecoveryMatchState,
        reader: any PrivilegedDiskReading,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        for candidate in candidates {
            try Task.checkCancellation()
            guard !recoveryState.seenOffsets.contains(candidate.absoluteOffset) else { continue }
            guard let hintIndex = bestHintIndex(for: candidate, in: recoveryState.pendingHints) else {
                continue
            }

            let hint = recoveryState.pendingHints.remove(at: hintIndex)
            guard let size = try await estimateSize(
                for: candidate.signature,
                at: candidate.absoluteOffset,
                reader: reader
            ) else {
                continue
            }

            let cappedSize = min(
                size,
                Int64(max(0, Int64(totalBytes) - Int64(candidate.absoluteOffset)))
            )
            guard cappedSize > 0 else { continue }

            let baseName = baseName(from: hint.fileName, fallbackOffset: candidate.absoluteOffset)
            let file = RecoverableFile(
                id: UUID(),
                fileName: baseName,
                fileExtension: candidate.signature.fileExtension,
                fileType: .image,
                sizeInBytes: cappedSize,
                offsetOnDisk: candidate.absoluteOffset,
                signatureMatch: candidate.signature,
                source: .fastScan,
                filePath: hint.path,
                isLikelyContiguous: true,
                fragmentMap: [
                    FragmentRange(
                        start: candidate.absoluteOffset,
                        length: UInt64(cappedSize)
                    ),
                ]
            )

            continuation.yield(.fileFound(file))
            recoveryState.seenOffsets.insert(candidate.absoluteOffset)
        }
    }
}

extension UInt64 {
    fileprivate func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
