import Foundation
import os

struct PartitionSearchService: Sendable {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PartitionSearch")

    func findPartitions(on devicePath: String, reader: PrivilegedDiskReading) async throws -> [StorageDevice] {
        logger.info("Starting partition search on \(devicePath)")

        try reader.start()
        defer { reader.stop() }

        var partitions: [StorageDevice] = []

        // Read LBA 1 (GPT Header) assuming 512-byte sectors
        // 512 bytes starting at offset 512
        let blockSize = 512
        var gptHeaderBlock = [UInt8](repeating: 0, count: blockSize)

        let headerRead = gptHeaderBlock.withUnsafeMutableBytes { ptr in
            reader.read(into: ptr.baseAddress!, offset: 512, length: blockSize)
        }

        if headerRead == blockSize {
            // Check for EFI PART signature
            let signatureBytes = gptHeaderBlock[0 ..< 8]
            if String(bytes: signatureBytes, encoding: .ascii) == "EFI PART" {
                logger.debug("Found valid GPT header.")

                // Read Number of partition entries (4 bytes at offset 80)
                let numEntries = gptHeaderBlock
                    .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
                // Read size of entry (4 bytes at offset 84)
                let entrySize = gptHeaderBlock.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 84, as: UInt32.self) }
                // Read Starting LBA of array (8 bytes at offset 72)
                let arrayStartLBA = gptHeaderBlock.withUnsafeBytes { $0.loadUnaligned(
                    fromByteOffset: 72,
                    as: UInt64.self
                ) }

                logger.debug("GPT Array at LBA \(arrayStartLBA), \(numEntries) entries of size \(entrySize)")

                let arrayOffset = arrayStartLBA * UInt64(blockSize)
                let arrayBytesToRead = Int(numEntries * entrySize)

                // Read the whole partition array
                var arrayBlock = [UInt8](repeating: 0, count: arrayBytesToRead)
                let arrayRead = arrayBlock.withUnsafeMutableBytes { ptr in
                    reader.read(into: ptr.baseAddress!, offset: arrayOffset, length: arrayBytesToRead)
                }

                if arrayRead == arrayBytesToRead {
                    for i in 0 ..< Int(numEntries) {
                        let entryStart = i * Int(entrySize)
                        let typeGUIDBytes = arrayBlock[entryStart ..< entryStart + 16]

                        // If type GUID is all zeros, it's an unused entry
                        if typeGUIDBytes.allSatisfy({ $0 == 0 }) {
                            continue
                        }

                        // First LBA at offset 32 (8 bytes)
                        let firstLBA = arrayBlock.withUnsafeBytes { $0.loadUnaligned(
                            fromByteOffset: entryStart + 32,
                            as: UInt64.self
                        ) }
                        // Last LBA at offset 40 (8 bytes)
                        let lastLBA = arrayBlock.withUnsafeBytes { $0.loadUnaligned(
                            fromByteOffset: entryStart + 40,
                            as: UInt64.self
                        ) }

                        let partitionOffset = firstLBA * UInt64(blockSize)
                        let partitionSize = (lastLBA - firstLBA + 1) * UInt64(blockSize)

                        let formattedOffset = ByteCountFormatter.string(
                            fromByteCount: Int64(partitionOffset),
                            countStyle: .file
                        )
                        let device = StorageDevice(
                            id: "\(devicePath)-part-\(i)",
                            name: "Lost Partition @ \(formattedOffset)",
                            volumePath: URL(fileURLWithPath: devicePath),
                            volumeUUID: "VIRTUAL-\(UUID().uuidString)",
                            filesystemType: .other, // Will refine this later inside Phase 2 optionally
                            isExternal: true,
                            partitionOffset: partitionOffset,
                            partitionSize: Int64(partitionSize),
                            totalCapacity: Int64(partitionSize),
                            availableCapacity: 0
                        )
                        partitions.append(device)
                    }
                }
            }
        }

        logger.info("Found \(partitions.count) partitions on \(devicePath).")
        return partitions
    }
}
