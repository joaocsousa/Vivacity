import Foundation
@testable import Vivacity

enum APFSTestImageFixture {
    struct StructuredSpec {
        let pathComponents: [String]
        let fileID: UInt64
        let privateID: UInt64
        let fragments: [Data]
        let physicalBlocks: [Int]
    }

    struct Output {
        let disk: Data
        let fileData: Data
        let fragmentMap: [FragmentRange]
        let filePath: String
        let fileName: String
        let volumeInfo: VolumeInfo
    }

    static let blockSize = 4096

    static func makeStructuredImage(
        spec: StructuredSpec,
        totalBlocks: Int? = nil
    ) -> Output {
        precondition(
            spec.pathComponents.count >= 2,
            "Structured APFS test image requires at least one directory and a file"
        )
        precondition(spec.fragments.count == spec.physicalBlocks.count, "Fragments and physical blocks must match")

        let dataEndBlocks = spec.physicalBlocks.enumerated().map { index, physicalBlock in
            let fragmentBlocks = max(1, Int(ceil(Double(spec.fragments[index].count) / Double(blockSize))))
            return physicalBlock + fragmentBlocks
        }
        let requiredBlocks = max((dataEndBlocks.max() ?? 0) + 1, 3)
        let blockCount = max(totalBlocks ?? requiredBlocks, requiredBlocks)

        var disk = makeAPFSDisk(blockCount: blockCount)
        let fileName = spec.pathComponents.last ?? "Recovered.jpg"
        let fileData = spec.fragments.reduce(into: Data()) { partial, fragment in
            partial.append(fragment)
        }

        var directoryRecords: [(key: Data, value: Data)] = []
        var currentParentID: UInt64 = 1
        let directoryIDs = intermediateDirectoryIDs(count: spec.pathComponents.count - 1)

        for (index, directoryName) in spec.pathComponents.dropLast().enumerated() {
            let directoryID = directoryIDs[index]
            directoryRecords.append(
                makeDirectoryRecord(parentID: currentParentID, fileID: directoryID, name: directoryName)
            )
            currentParentID = directoryID
        }

        directoryRecords.append(
            makeDirectoryRecord(parentID: currentParentID, fileID: spec.fileID, name: fileName)
        )

        let inodeRecord = makeInodeRecord(
            objectID: spec.fileID,
            parentID: currentParentID,
            privateID: spec.privateID,
            size: UInt64(fileData.count)
        )

        var extentRecords: [(key: Data, value: Data)] = []
        var logicalOffset: UInt64 = 0
        var fragmentMap: [FragmentRange] = []

        for (index, fragment) in spec.fragments.enumerated() {
            let physicalBlock = spec.physicalBlocks[index]
            extentRecords.append(
                makeExtentRecord(
                    ownerID: spec.privateID,
                    logicalAddress: logicalOffset,
                    physicalBlock: UInt64(physicalBlock),
                    length: UInt64(fragment.count)
                )
            )
            let physicalOffset = physicalBlock * blockSize
            writeData(fragment, to: &disk, offset: physicalOffset)
            fragmentMap.append(
                FragmentRange(
                    start: UInt64(physicalOffset),
                    length: UInt64(fragment.count)
                )
            )
            logicalOffset += UInt64(fragment.count)
        }

        let leafBlock = makeLeafNode(
            records: directoryRecords + [inodeRecord] + extentRecords,
            blockSize: blockSize
        )
        writeBlock(leafBlock, to: &disk, blockIndex: 1)

        return Output(
            disk: disk,
            fileData: fileData,
            fragmentMap: fragmentMap,
            filePath: "/" + spec.pathComponents.joined(separator: "/"),
            fileName: fileName,
            volumeInfo: makeVolumeInfo()
        )
    }

    static func makeHintImage(
        path: String,
        fileData: Data,
        dataOffset: Int,
        totalBytes: Int
    ) -> Output {
        var disk = Data(repeating: 0, count: totalBytes)
        writeASCII("BSXN", to: &disk, offset: 32)
        writeUInt32(UInt32(blockSize), to: &disk, offset: 36)
        writeASCII("BSPA", to: &disk, offset: blockSize + 32)
        writeASCII(path, to: &disk, offset: 256)
        writeData(fileData, to: &disk, offset: dataOffset)

        return Output(
            disk: disk,
            fileData: fileData,
            fragmentMap: [FragmentRange(start: UInt64(dataOffset), length: UInt64(fileData.count))],
            filePath: path.hasPrefix("/") ? path : "/" + path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            volumeInfo: makeVolumeInfo()
        )
    }

    static func makeVolumeInfo(path: String = "/tmp/apfs.img") -> VolumeInfo {
        VolumeInfo(
            filesystemType: .apfs,
            devicePath: path,
            mountPoint: URL(fileURLWithPath: path),
            blockSize: blockSize,
            isInternal: false,
            isBootable: false,
            isFileVaultEnabled: false
        )
    }

    static func makeStructuredJPEG(
        pathComponents: [String],
        fileID: UInt64 = 30,
        privateID: UInt64 = 300,
        physicalBlocks: [Int] = [3]
    ) -> Output {
        let jpegData = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xD9,
        ])
        return makeStructuredImage(
            spec: StructuredSpec(
                pathComponents: pathComponents,
                fileID: fileID,
                privateID: privateID,
                fragments: [jpegData],
                physicalBlocks: physicalBlocks
            )
        )
    }

    static func makeStructuredHEIC(
        pathComponents: [String],
        fileID: UInt64 = 31,
        privateID: UInt64 = 301,
        physicalBlocks: [Int] = [3, 5]
    ) -> Output {
        let heicData = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63, 0x00, 0x00, 0x00, 0x00,
            0x68, 0x65, 0x69, 0x63, 0x6D, 0x69, 0x66, 0x31,
            0x00, 0x00, 0x00, 0x10, 0x6D, 0x64, 0x61, 0x74,
            0xDE, 0xAD, 0xBE, 0xEF, 0xAA, 0xBB, 0xCC, 0xDD,
        ])
        let first = Data(heicData.prefix(24))
        let second = Data(heicData.dropFirst(24))

        return makeStructuredImage(
            spec: StructuredSpec(
                pathComponents: pathComponents,
                fileID: fileID,
                privateID: privateID,
                fragments: [first, second],
                physicalBlocks: physicalBlocks
            )
        )
    }

    private static func intermediateDirectoryIDs(count: Int) -> [UInt64] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { UInt64(($0 + 1) * 10) }
    }

    private static func makeAPFSDisk(blockCount: Int) -> Data {
        var disk = Data(repeating: 0, count: blockSize * blockCount)
        writeBlock(makeContainerSuperblock(blockSize: blockSize), to: &disk, blockIndex: 0)
        return disk
    }

    private static func makeContainerSuperblock(blockSize: Int) -> Data {
        var block = Data(repeating: 0, count: blockSize)
        writeASCII("BSXN", to: &block, offset: 32)
        writeUInt32(UInt32(blockSize), to: &block, offset: 36)
        return block
    }

    private static func makeLeafNode(
        records: [(key: Data, value: Data)],
        blockSize: Int
    ) -> Data {
        var block = Data(repeating: 0, count: blockSize)
        writeUInt32(3, to: &block, offset: 24)
        writeUInt16(0x0002, to: &block, offset: 32)
        writeUInt16(0, to: &block, offset: 34)
        writeUInt32(UInt32(records.count), to: &block, offset: 36)
        writeUInt16(0, to: &block, offset: 40)
        writeUInt16(UInt16(records.count * 8), to: &block, offset: 42)

        let keyAreaStart = 56 + (records.count * 8)
        var keyCursor = 0
        var valueCursor = blockSize

        for (index, record) in records.enumerated() {
            let keyOffset = keyCursor
            writeData(record.key, to: &block, offset: keyAreaStart + keyOffset)
            keyCursor += record.key.count

            valueCursor -= record.value.count
            writeData(record.value, to: &block, offset: valueCursor)

            let entryOffset = 56 + (index * 8)
            writeUInt16(UInt16(keyOffset), to: &block, offset: entryOffset)
            writeUInt16(UInt16(record.key.count), to: &block, offset: entryOffset + 2)
            writeUInt16(UInt16(blockSize - valueCursor), to: &block, offset: entryOffset + 4)
            writeUInt16(UInt16(record.value.count), to: &block, offset: entryOffset + 6)
        }

        let freeSpaceLength = max(0, valueCursor - (keyAreaStart + keyCursor))
        writeUInt16(UInt16(keyCursor), to: &block, offset: 44)
        writeUInt16(UInt16(freeSpaceLength), to: &block, offset: 46)
        return block
    }

    private static func makeDirectoryRecord(
        parentID: UInt64,
        fileID: UInt64,
        name: String
    ) -> (key: Data, value: Data) {
        var key = Data()
        appendUInt64((9 << 60) | parentID, to: &key)
        appendUInt32(UInt32(name.utf8.count), to: &key)
        key.append(contentsOf: name.utf8)

        var value = Data(repeating: 0, count: 18)
        writeUInt64(fileID, to: &value, offset: 0)
        return (key, value)
    }

    private static func makeInodeRecord(
        objectID: UInt64,
        parentID: UInt64,
        privateID: UInt64,
        size: UInt64
    ) -> (key: Data, value: Data) {
        var key = Data()
        appendUInt64((3 << 60) | objectID, to: &key)

        var value = Data(repeating: 0, count: 92)
        writeUInt64(parentID, to: &value, offset: 0)
        writeUInt64(privateID, to: &value, offset: 8)
        writeUInt16(0x8000, to: &value, offset: 80)
        writeUInt64(size, to: &value, offset: 84)
        return (key, value)
    }

    private static func makeExtentRecord(
        ownerID: UInt64,
        logicalAddress: UInt64,
        physicalBlock: UInt64,
        length: UInt64
    ) -> (key: Data, value: Data) {
        var key = Data()
        appendUInt64((8 << 60) | ownerID, to: &key)
        appendUInt64(logicalAddress, to: &key)

        var value = Data(repeating: 0, count: 24)
        writeUInt64(length, to: &value, offset: 0)
        writeUInt64(physicalBlock, to: &value, offset: 8)
        return (key, value)
    }

    private static func writeBlock(_ block: Data, to disk: inout Data, blockIndex: Int) {
        writeData(block, to: &disk, offset: blockIndex * blockSize)
    }

    private static func writeData(_ source: Data, to data: inout Data, offset: Int) {
        guard offset < data.count else { return }
        let bytesToCopy = min(source.count, data.count - offset)
        data.replaceSubrange(offset ..< offset + bytesToCopy, with: source.prefix(bytesToCopy))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 56) & 0xFF))
    }

    private static func writeUInt16(_ value: UInt16, to data: inout Data, offset: Int) {
        guard offset + 1 < data.count else { return }
        data[offset + 0] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        guard offset + 3 < data.count else { return }
        data[offset + 0] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeUInt64(_ value: UInt64, to data: inout Data, offset: Int) {
        guard offset + 7 < data.count else { return }
        data[offset + 0] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
        data[offset + 4] = UInt8((value >> 32) & 0xFF)
        data[offset + 5] = UInt8((value >> 40) & 0xFF)
        data[offset + 6] = UInt8((value >> 48) & 0xFF)
        data[offset + 7] = UInt8((value >> 56) & 0xFF)
    }

    private static func writeASCII(_ string: String, to data: inout Data, offset: Int) {
        for (index, byte) in string.utf8.enumerated() {
            guard offset + index < data.count else { break }
            data[offset + index] = byte
        }
    }
}
