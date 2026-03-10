import Foundation

struct StructuredNodeLayout {
    let recordCount: Int
    let tocStart: Int
    let keyAreaStart: Int
    let valueAreaStart: Int
    let valueAreaEnd: Int
}

extension APFSMetadataScanner.StructuredRecordBatch {
    fileprivate var isEmpty: Bool {
        inodes.isEmpty && directoryRecords.isEmpty && extents.isEmpty
    }
}

extension APFSMetadataScanner {
    func extractStructuredRecords(
        from data: Data,
        absoluteStart: UInt64,
        blockSize: Int,
        minimumOffset: UInt64
    ) -> StructuredRecordBatch {
        guard blockSize > 0, data.count >= blockSize else { return StructuredRecordBatch() }

        let bytes = [UInt8](data)
        var batch = StructuredRecordBatch()
        var blockOffset = 0

        while blockOffset + blockSize <= bytes.count {
            let baseOffset = absoluteStart + UInt64(blockOffset)
            guard baseOffset >= minimumOffset else {
                blockOffset += blockSize
                continue
            }

            let block = Array(bytes[blockOffset ..< blockOffset + blockSize])
            if let records = parseStructuredLeafRecords(from: block, blockSize: blockSize) {
                batch.inodes.append(contentsOf: records.inodes)
                batch.directoryRecords.append(contentsOf: records.directoryRecords)
                batch.extents.append(contentsOf: records.extents)
            }

            blockOffset += blockSize
        }

        return batch
    }

    func parseStructuredLeafRecords(
        from block: [UInt8],
        blockSize: Int
    ) -> StructuredRecordBatch? {
        guard let layout = parseStructuredNodeLayout(from: block, blockSize: blockSize) else {
            return nil
        }

        let locations = extractKeyValueLocations(
            from: block,
            recordCount: layout.recordCount,
            tocStart: layout.tocStart,
            keyAreaStart: layout.keyAreaStart,
            valueAreaEnd: layout.valueAreaEnd
        )
        guard !locations.isEmpty else { return nil }

        var batch = StructuredRecordBatch()

        for location in locations {
            guard let payload = extractPayload(
                from: block,
                location: location,
                layout: layout
            ) else {
                continue
            }
            appendStructuredRecord(key: payload.key, value: payload.value, to: &batch)
        }

        return batch.isEmpty ? nil : batch
    }

    func parseStructuredNodeLayout(
        from block: [UInt8],
        blockSize: Int
    ) -> StructuredNodeLayout? {
        guard block.count >= blockSize, block.count >= fixedNodeHeaderSize else { return nil }
        let objectType = readLittleEndianUInt32(block, at: 24) & objectTypeMask
        guard objectType == btreeNodeObjectType else { return nil }

        let nodeFlags = readLittleEndianUInt16(block, at: 32)
        let level = readLittleEndianUInt16(block, at: 34)
        let recordCount = Int(readLittleEndianUInt32(block, at: 36))
        guard recordCount > 0, nodeFlags & btreeLeafFlag != 0, level == 0 else { return nil }

        let tableOffset = Int(readLittleEndianUInt16(block, at: 40))
        let tableLength = Int(readLittleEndianUInt16(block, at: 42))
        let freeOffset = Int(readLittleEndianUInt16(block, at: 44))
        let freeLength = Int(readLittleEndianUInt16(block, at: 46))

        let tocStart = fixedNodeHeaderSize + tableOffset
        let requiredTableLength = recordCount * kvLocationSize
        let keyAreaStart = tocStart + tableLength
        let valueAreaEnd = blockSize - (nodeFlags & btreeRootFlag != 0 ? btreeInfoSize : 0)
        let valueAreaStart = keyAreaStart + freeOffset + freeLength

        guard tableLength >= requiredTableLength,
              tocStart >= fixedNodeHeaderSize,
              keyAreaStart <= blockSize,
              valueAreaStart <= valueAreaEnd,
              valueAreaEnd <= blockSize
        else {
            return nil
        }

        return StructuredNodeLayout(
            recordCount: recordCount,
            tocStart: tocStart,
            keyAreaStart: keyAreaStart,
            valueAreaStart: valueAreaStart,
            valueAreaEnd: valueAreaEnd
        )
    }

    func extractKeyValueLocations(
        from block: [UInt8],
        recordCount: Int,
        tocStart: Int,
        keyAreaStart: Int,
        valueAreaEnd: Int
    ) -> [KeyValueLocation] {
        var locations: [KeyValueLocation] = []

        for index in 0 ..< recordCount {
            let entryOffset = tocStart + (index * kvLocationSize)
            guard entryOffset + kvLocationSize <= block.count else { break }

            let keyOffset = Int(readLittleEndianUInt16(block, at: entryOffset))
            let keyLength = Int(readLittleEndianUInt16(block, at: entryOffset + 2))
            let valueOffset = Int(readLittleEndianUInt16(block, at: entryOffset + 4))
            let valueLength = Int(readLittleEndianUInt16(block, at: entryOffset + 6))

            guard keyLength > 0,
                  valueLength > 0,
                  keyAreaStart + keyOffset + keyLength <= block.count,
                  valueOffset <= valueAreaEnd,
                  valueAreaEnd - valueOffset >= 0
            else {
                continue
            }

            locations.append(
                KeyValueLocation(
                    keyOffset: keyOffset,
                    keyLength: keyLength,
                    valueOffset: valueOffset,
                    valueLength: valueLength
                )
            )
        }

        return locations
    }

    func extractPayload(
        from block: [UInt8],
        location: KeyValueLocation,
        layout: StructuredNodeLayout
    ) -> (key: [UInt8], value: [UInt8])? {
        let keyStart = layout.keyAreaStart + location.keyOffset
        let valueStart = layout.valueAreaEnd - location.valueOffset

        guard keyStart >= layout.keyAreaStart,
              keyStart + location.keyLength <= block.count,
              valueStart >= layout.valueAreaStart,
              valueStart + location.valueLength <= layout.valueAreaEnd
        else {
            return nil
        }

        let key = Array(block[keyStart ..< keyStart + location.keyLength])
        let value = Array(block[valueStart ..< valueStart + location.valueLength])
        guard key.count >= 8 else { return nil }
        return (key, value)
    }

    func appendStructuredRecord(
        key: [UInt8],
        value: [UInt8],
        to batch: inout StructuredRecordBatch
    ) {
        let header = readLittleEndianUInt64(key, at: 0)
        let objectID = header & objectIDMask
        let recordType = header >> recordTypeShift

        switch recordType {
        case inodeRecordType:
            if let inode = parseInodeRecord(objectID: objectID, value: value) {
                batch.inodes.append(inode)
            }

        case directoryRecordType:
            if let record = parseDirectoryRecord(parentID: objectID, key: key, value: value) {
                batch.directoryRecords.append(record)
            }

        case fileExtentRecordType:
            if let extent = parseExtentRecord(ownerID: objectID, key: key, value: value) {
                batch.extents.append(extent)
            }

        default:
            break
        }
    }

    func parseInodeRecord(
        objectID: UInt64,
        value: [UInt8]
    ) -> StructuredInodeRecord? {
        guard value.count >= 92 else { return nil }

        let parentID = readLittleEndianUInt64(value, at: 0)
        let privateID = readLittleEndianUInt64(value, at: 8)
        let mode = readLittleEndianUInt16(value, at: 80)
        let uncompressedSize = readLittleEndianUInt64(value, at: 84)
        guard uncompressedSize > 0 else { return nil }

        return StructuredInodeRecord(
            objectID: objectID,
            parentID: parentID,
            privateID: privateID,
            uncompressedSize: uncompressedSize,
            mode: mode
        )
    }

    func parseDirectoryRecord(
        parentID: UInt64,
        key: [UInt8],
        value: [UInt8]
    ) -> StructuredDirectoryRecord? {
        guard key.count >= 12, value.count >= 8 else { return nil }

        let nameLengthAndHash = readLittleEndianUInt32(key, at: 8)
        let nameLength = Int(nameLengthAndHash & directoryNameLengthMask)
        guard nameLength > 0, 12 + nameLength <= key.count else { return nil }

        let rawName = Array(key[12 ..< 12 + nameLength])
        let nameBytes = Array(rawName.prefix { $0 != 0 })
        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty else { return nil }

        return StructuredDirectoryRecord(
            parentID: parentID,
            fileID: readLittleEndianUInt64(value, at: 0),
            name: name
        )
    }

    func parseExtentRecord(
        ownerID: UInt64,
        key: [UInt8],
        value: [UInt8]
    ) -> StructuredExtentRecord? {
        guard key.count >= 16, value.count >= 16 else { return nil }

        let logicalAddress = readLittleEndianUInt64(key, at: 8)
        let lengthAndFlags = readLittleEndianUInt64(value, at: 0)
        let length = lengthAndFlags & fileExtentLengthMask
        let physicalBlockNumber = readLittleEndianUInt64(value, at: 8)
        guard length > 0, physicalBlockNumber > 0 else { return nil }

        return StructuredExtentRecord(
            ownerID: ownerID,
            logicalAddress: logicalAddress,
            physicalBlockNumber: physicalBlockNumber,
            length: length
        )
    }

    func emitStructuredRecoveredFiles(
        geometry: StructuredScanGeometry,
        structuredState: inout StructuredRecoveryState,
        recoveryState: inout RecoveryMatchState,
        reader: any PrivilegedDiskReading,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) throws {
        let inodes = structuredState.inodesByID.values.sorted { $0.objectID < $1.objectID }

        for inode in inodes {
            try Task.checkCancellation()
            guard !structuredState.emittedFileIDs.contains(inode.objectID) else { continue }
            guard let file = makeRecoverableImage(
                for: inode,
                geometry: geometry,
                structuredState: &structuredState,
                recoveryState: &recoveryState,
                reader: reader
            ) else {
                continue
            }

            continuation.yield(.fileFound(file))
        }
    }

    func makeRecoverableImage(
        for inode: StructuredInodeRecord,
        geometry: StructuredScanGeometry,
        structuredState: inout StructuredRecoveryState,
        recoveryState: inout RecoveryMatchState,
        reader: any PrivilegedDiskReading
    ) -> RecoverableFile? {
        guard inode.isRegularFile else { return nil }
        guard let directoryRecord = preferredDirectoryRecord(for: inode, in: structuredState) else {
            return nil
        }
        guard let expectedSignature = signature(forFileName: directoryRecord.name) else { return nil }
        guard let fragmentMap = resolveFragmentMap(
            for: inode,
            blockSize: geometry.blockSize,
            totalBytes: geometry.totalBytes,
            in: structuredState
        ) else {
            return nil
        }
        guard let signature = verifyStructuredSignature(
            expectedSignature: expectedSignature,
            fragmentMap: fragmentMap,
            reader: reader
        ) else {
            return nil
        }

        let firstOffset = fragmentMap.first?.start ?? 0
        guard !recoveryState.seenOffsets.contains(firstOffset) else {
            structuredState.emittedFileIDs.insert(inode.objectID)
            return nil
        }

        let resolvedPath = buildPath(for: directoryRecord, in: structuredState) ?? "/\(directoryRecord.name)"
        let file = RecoverableFile(
            id: UUID(),
            fileName: baseName(from: directoryRecord.name, fallbackOffset: firstOffset),
            fileExtension: signature.fileExtension,
            fileType: .image,
            sizeInBytes: Int64(inode.uncompressedSize),
            offsetOnDisk: firstOffset,
            signatureMatch: signature,
            source: .fastScan,
            filePath: resolvedPath,
            isLikelyContiguous: fragmentMap.count == 1,
            fragmentMap: fragmentMap
        )

        structuredState.emittedFileIDs.insert(inode.objectID)
        recoveryState.seenOffsets.insert(firstOffset)

        let logMessage =
            "APFS structured recovery emitted fileID=\(inode.objectID) " +
            "path=\(resolvedPath) extents=\(fragmentMap.count)"
        logger.info("\(logMessage, privacy: .public)")

        return file
    }

    func preferredDirectoryRecord(
        for inode: StructuredInodeRecord,
        in state: StructuredRecoveryState
    ) -> StructuredDirectoryRecord? {
        guard let records = state.directoryRecordsByFileID[inode.objectID], !records.isEmpty else {
            return nil
        }

        if let matchingParent = records.first(where: { $0.parentID == inode.parentID }) {
            return matchingParent
        }

        return records.min { lhs, rhs in
            if lhs.parentID == rhs.parentID {
                return lhs.name < rhs.name
            }
            return lhs.parentID < rhs.parentID
        }
    }

    func buildPath(
        for leafRecord: StructuredDirectoryRecord,
        in state: StructuredRecoveryState
    ) -> String? {
        var components = [leafRecord.name]
        var currentParentID = leafRecord.parentID
        var visited: Set<UInt64> = [leafRecord.fileID]

        while !visited.contains(currentParentID) {
            visited.insert(currentParentID)
            guard let parentRecord = state.directoryRecordsByFileID[currentParentID]?.first else {
                break
            }
            components.append(parentRecord.name)
            currentParentID = parentRecord.parentID
        }

        guard !components.isEmpty else { return nil }
        return "/" + components.reversed().joined(separator: "/")
    }

    func resolveFragmentMap(
        for inode: StructuredInodeRecord,
        blockSize: Int,
        totalBytes: UInt64,
        in state: StructuredRecoveryState
    ) -> [FragmentRange]? {
        let extentCandidates = combinedExtentCandidates(for: inode, in: state)
        guard !extentCandidates.isEmpty else { return nil }

        var fragmentMap: [FragmentRange] = []
        var remainingBytes = inode.uncompressedSize

        for extent in extentCandidates where remainingBytes > 0 {
            let physicalStart = extent.physicalBlockNumber * UInt64(blockSize)
            guard physicalStart < totalBytes else { continue }

            let availableOnImage = totalBytes - physicalStart
            let bytesToTake = min(extent.length, remainingBytes, availableOnImage)
            guard bytesToTake > 0 else { continue }

            fragmentMap.append(FragmentRange(start: physicalStart, length: bytesToTake))
            remainingBytes -= bytesToTake
        }

        guard remainingBytes == 0, !fragmentMap.isEmpty else { return nil }
        return fragmentMap
    }

    func combinedExtentCandidates(
        for inode: StructuredInodeRecord,
        in state: StructuredRecoveryState
    ) -> [StructuredExtentRecord] {
        var extents: [StructuredExtentRecord] = []

        if let byPrivateID = state.extentsByOwnerID[inode.privateID] {
            extents.append(contentsOf: byPrivateID)
        }
        if inode.privateID != inode.objectID, let byObjectID = state.extentsByOwnerID[inode.objectID] {
            extents.append(contentsOf: byObjectID)
        }

        return Set(extents).sorted { lhs, rhs in
            if lhs.logicalAddress == rhs.logicalAddress {
                return lhs.physicalBlockNumber < rhs.physicalBlockNumber
            }
            return lhs.logicalAddress < rhs.logicalAddress
        }
    }

    func verifyStructuredSignature(
        expectedSignature: FileSignature,
        fragmentMap: [FragmentRange],
        reader: any PrivilegedDiskReading
    ) -> FileSignature? {
        guard let startOffset = fragmentMap.first?.start else { return nil }
        guard let header = readHeader(reader: reader, at: startOffset, maxBytes: readVerificationBytes) else {
            return nil
        }
        return signatureMatcher.verifyMagicBytes(header, expectedExtension: expectedSignature.fileExtension)
    }

    func readHeader(
        reader: any PrivilegedDiskReading,
        at offset: UInt64,
        maxBytes: Int
    ) -> [UInt8]? {
        guard maxBytes > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            reader.read(
                into: rawBuffer.baseAddress!,
                offset: offset,
                length: maxBytes
            )
        }
        guard bytesRead > 0 else { return nil }
        return Array(buffer.prefix(bytesRead))
    }
}
