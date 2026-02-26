import Foundation
import os

/// Scans raw bytes for orphaned HFS+ Catalog B-Tree nodes (carving).
struct HFSPlusCarver {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "HFSPlusCarver")

    /// A file discovered heuristically by the carver.
    struct CarvedFile {
        let fileName: String
        let fileExtension: String
        let sizeInBytes: Int64
        let offsetOnDisk: UInt64
    }

    /// Scan a raw byte buffer for HFS+ B-Tree nodes.
    /// - Parameters:
    ///   - buffer: The raw byte buffer (expected to be a multiple of sector size).
    ///   - baseOffset: The absolute disk offset of this buffer.
    func carveChunk(
        buffer: UnsafeRawBufferPointer,
        baseOffset: UInt64
    ) -> [CarvedFile] {
        var results: [CarvedFile] = []

        // In HFS+, nodes are often 4096 or 8192 bytes. We scan by 512-byte sector alignment
        // to catch nodes that might start on any sector boundary if the FS was defragmented/moved.
        let sectorSize = 512
        var i = 0

        // Minimum size of a node descriptor + some records
        let minNodeSize = 256

        while i <= buffer.count - minNodeSize {
            let slice = UnsafeRawBufferPointer(rebasing: buffer[i...])

            if isPlausibleBTNode(slice) {
                let parsedFiles = parseNode(slice: slice, sliceOffset: baseOffset + UInt64(i))
                results.append(contentsOf: parsedFiles)

                // If we found a valid node, we can skip ahead a bit (often 4KB),
                // but to be safe against varying node sizes, we just move by the 
                // typical minimum node size.
                i += 4096
            } else {
                i += sectorSize
            }
        }

        return results
    }

    private func isPlausibleBTNode(_ slice: UnsafeRawBufferPointer) -> Bool {
        // BTNodeDescriptor is 14 bytes:
        // UInt32 fLink
        // UInt32 bLink
        // Int8   kind
        // UInt8  height
        // UInt16 numRecords
        // UInt16 reserved

        // We are looking for leaf nodes (kind == -1 == 0xFF)
        let kind = slice[8]
        if kind != 0xFF { return false }

        // Height should be 1 for leaf nodes
        let height = slice[9]
        if height != 1 { return false }

        let numRecords = UInt16(slice[10]) << 8 | UInt16(slice[11])
        // A plausible number of records in a 4K-8K node
        if numRecords == 0 || numRecords > 500 { return false }

        // Reserved must be 0
        let reserved = UInt16(slice[12]) << 8 | UInt16(slice[13])
        if reserved != 0 { return false }

        return true
    }

    private func parseNode(slice: UnsafeRawBufferPointer, sliceOffset: UInt64) -> [CarvedFile] {
        var files: [CarvedFile] = []
        let numRecords = Int(UInt16(slice[10]) << 8 | UInt16(slice[11]))

        // HFS+ B-Trees have record offsets at the *end* of the node.
        // Since we don't know the node size for sure (4K vs 8K) if it's orphaned,
        // we'll try to parse records sequentially from the start, as long as they
        // look like valid HFSPlusCatalogKeys.

        var currentOffset = 14 // Start after BTNodeDescriptor

        for _ in 0..<numRecords {
            // Ensure we have enough space for a key length and some data
            if currentOffset + 6 > slice.count { break }

            // HFSPlusCatalogKey
            let keyLength = Int(UInt16(slice[currentOffset]) << 8 | UInt16(slice[currentOffset+1]))
            if keyLength < 6 || currentOffset + 2 + keyLength > slice.count { break }

            // Parent ID is 4 bytes at offset 2
            // let parentID = UInt32(slice[currentOffset+2]) << 24 | UInt32(slice[currentOffset+3]) << 16 | UInt32(slice[currentOffset+4]) << 8 | UInt32(slice[currentOffset+5])

            // Node Name is a Unicode string (HFSUniStr255) at offset 6
            let nameLength = Int(UInt16(slice[currentOffset+6]) << 8 | UInt16(slice[currentOffset+7]))

            var fileName = ""
            if nameLength > 0 && nameLength <= 255 {
                let nameStart = currentOffset + 8
                let nameEnd = nameStart + (nameLength * 2)
                if nameEnd <= currentOffset + 2 + keyLength {
                    var chars: [unichar] = []
                    for k in stride(from: nameStart, to: nameEnd, by: 2) {
                        let char = unichar(slice[k]) << 8 | unichar(slice[k+1])
                        chars.append(char)
                    }
                    fileName = String(utf16CodeUnits: chars, count: chars.count)
                }
            }

            // Move offset past the key
            currentOffset += 2 + keyLength

            // Alignment: data records in HFS+ are not necessarily aligned in the Catalog file,
            // but the leaf nodes contain HFSPlusCatalogFolder or HFSPlusCatalogFile records.
            if currentOffset + 2 > slice.count { break }

            let recordType = UInt16(slice[currentOffset]) << 8 | UInt16(slice[currentOffset+1])

            // 0x0002 is kHFSPlusFileRecord
            if recordType == 2 && currentOffset + 248 <= slice.count && !fileName.isEmpty {
                // Parse HFSPlusCatalogFile
                // struct HFSPlusCatalogFile {
                //      SInt16      recordType;       // == kHFSPlusFileRecord (2)
                //      UInt16      flags;            // 2
                //      UInt32      reserved1;        // 4
                //      UInt32      fileID;           // 8
                //      UInt32      createDate;       // 12
                //      UInt32      contentModDate;   // 16
                //      UInt32      attributeModDate; // 20
                //      UInt32      accessDate;       // 24
                //      UInt32      backupDate;       // 28
                //      HFSPlusBSDInfo permissions;   // 32 (16 bytes)
                //      UserInfo    userInfo;         // 48 (16 bytes) -> FinderInfo etc
                //      FinderInfo  finderInfo;       // 64 (16 bytes)
                //      UInt32      textEncoding;     // 80
                //      UInt32      reserved2;        // 84
                //      HFSPlusForkData dataFork;     // 88 (80 bytes)
                //      HFSPlusForkData resourceFork; // 168 (80 bytes)
                // } 248 bytes total.

                // dataFork starts at offset 88.
                // struct HFSPlusForkData {
                //      UInt64                  logicalSize;    // 88
                //      UInt32                  clumpSize;      // 96
                //      UInt32                  totalBlocks;    // 100
                //      HFSPlusExtentRecord     extents;        // 104 (8 extent descriptors, 8 bytes each = 64 bytes)
                // }

                let logicalSizeHigh = UInt32(slice[currentOffset+88]) << 24 |
                                      UInt32(slice[currentOffset+89]) << 16 |
                                      UInt32(slice[currentOffset+90]) << 8 |
                                      UInt32(slice[currentOffset+91])
                let logicalSizeLow = UInt32(slice[currentOffset+92]) << 24 |
                                     UInt32(slice[currentOffset+93]) << 16 |
                                     UInt32(slice[currentOffset+94]) << 8 |
                                     UInt32(slice[currentOffset+95])
                let logicalSize = UInt64(logicalSizeHigh) << 32 | UInt64(logicalSizeLow)

                // Extents start at 104
                // HFSPlusExtentDescriptor {
                //      UInt32                  startBlock;
                //      UInt32                  blockCount;
                // }
                let startBlock = UInt32(slice[currentOffset+104]) << 24 |
                                 UInt32(slice[currentOffset+105]) << 16 |
                                 UInt32(slice[currentOffset+106]) << 8 |
                                 UInt32(slice[currentOffset+107])

                // If it has a data fork and it starts somewhere
                if logicalSize > 0 && startBlock > 0 {
                    // Note: We need the HFS+ Allocation Block Size to convert startBlock to a physical disk offset.
                    // Since we are carving orphaned nodes, we don't have the Volume Header.
                    // HFS+ default block size is 4096 bytes. We will assume 4096 as a heuristic.
                    let assumedBlockSize: UInt64 = 4096
                    let fileDiskOffset = UInt64(startBlock) * assumedBlockSize

                    let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()

                    files.append(CarvedFile(
                        fileName: fileName,
                        fileExtension: ext,
                        sizeInBytes: Int64(logicalSize),
                        offsetOnDisk: fileDiskOffset
                    ))
                }
            }

            // We need to jump to the next record. Since records are variable length,
            // we'd normally use the record offsets at the end of the node.
            // Since we're doing a forward scan heuristic and the node size varies,
            // finding the next record cleanly is tricky. We'll simply break out
            // rather than trying to walk a potentially corrupted linked list of unknown length.
            // A more robust carver would assume node sizes of 4096 and 8192 and check the offsets.
            break
        }

        return files
    }
}
