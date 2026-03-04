import Foundation
import os

/// Handles reassembly of fragmented video files, particularly those from action cameras and drones.
protocol FragmentedVideoAssembling: Sendable {
    /// Attempts to reassemble fragmented chunks of video files based on camera profiles.
    func assemble(from files: [RecoverableFile], reader: PrivilegedDiskReading) -> [RecoverableFile]
}

struct FragmentedVideoAssembler: FragmentedVideoAssembling {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "FragmentedVideoAssembler")
    private let scanWindowBytes: UInt64 = 32 * 1024 * 1024
    private let scanStride: UInt64 = 8

    func assemble(from files: [RecoverableFile], reader: PrivilegedDiskReading) -> [RecoverableFile] {
        var assembledFiles = files

        for i in 0 ..< assembledFiles.count {
            let file = assembledFiles[i]
            guard file.fileType == .video, file.sizeInBytes <= 0 else { continue }
            guard ["mp4", "mov", "m4v", "3gp"].contains(file.fileExtension.lowercased()) else { continue }

            let assembled = inferFragmentAssembly(startOffset: file.offsetOnDisk, reader: reader)
            if assembled.hasPlayableStructure, assembled.endOffset > file.offsetOnDisk {
                assembledFiles[i] = RecoverableFile(
                    id: file.id,
                    fileName: file.fileName,
                    fileExtension: file.fileExtension,
                    fileType: file.fileType,
                    sizeInBytes: Int64(assembled.endOffset - file.offsetOnDisk),
                    offsetOnDisk: file.offsetOnDisk,
                    signatureMatch: file.signatureMatch,
                    source: file.source,
                    filePath: file.filePath,
                    isLikelyContiguous: false,
                    confidenceScore: max(file.confidenceScore ?? 0, 0.5)
                )
            } else {
                logger.debug("Unable to infer playable fragmented layout for \(file.fileName)")
            }
        }

        return assembledFiles
    }

    private struct FragmentAssemblyCandidate {
        let hasPlayableStructure: Bool
        let endOffset: UInt64
    }

    private func inferFragmentAssembly(
        startOffset: UInt64,
        reader: PrivilegedDiskReading
    ) -> FragmentAssemblyCandidate {
        var currentOffset = startOffset
        let maxOffset = startOffset + scanWindowBytes
        var foundMoov = false
        var foundMoof = false
        var foundMdat = false
        var maxEnd = startOffset

        while currentOffset < maxOffset {
            guard let header = readBoxHeader(at: currentOffset, reader: reader) else {
                currentOffset += scanStride
                continue
            }
            guard isPlausible(header) else {
                currentOffset += scanStride
                continue
            }

            switch header.type {
            case "moov":
                foundMoov = true
            case "moof":
                foundMoof = true
            case "mdat":
                foundMdat = true
            default:
                break
            }

            let end = currentOffset + header.size
            maxEnd = max(maxEnd, end)
            currentOffset = end > currentOffset ? end : currentOffset + scanStride

            if foundMdat, foundMoov || foundMoof {
                return FragmentAssemblyCandidate(hasPlayableStructure: true, endOffset: maxEnd)
            }
        }

        return FragmentAssemblyCandidate(hasPlayableStructure: false, endOffset: maxEnd)
    }

    private func readBoxHeader(at offset: UInt64, reader: PrivilegedDiskReading) -> MP4BoxHeader? {
        var buffer = [UInt8](repeating: 0, count: 16)
        let read = buffer.withUnsafeMutableBytes { raw in
            reader.read(into: raw.baseAddress!, offset: offset, length: 16)
        }
        guard read >= 8 else { return nil }

        let size = (UInt64(buffer[0]) << 24)
            | (UInt64(buffer[1]) << 16)
            | (UInt64(buffer[2]) << 8)
            | UInt64(buffer[3])
        let type = String(bytes: buffer[4 ..< 8], encoding: .ascii) ?? ""
        guard type.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return nil }
        guard size >= 8 else { return nil }

        if size == 1 {
            guard read >= 16 else { return nil }
            let extSize = (UInt64(buffer[8]) << 56)
                | (UInt64(buffer[9]) << 48)
                | (UInt64(buffer[10]) << 40)
                | (UInt64(buffer[11]) << 32)
                | (UInt64(buffer[12]) << 24)
                | (UInt64(buffer[13]) << 16)
                | (UInt64(buffer[14]) << 8)
                | UInt64(buffer[15])
            guard extSize >= 16 else { return nil }
            return MP4BoxHeader(type: type, size: extSize, headerLength: 16)
        }

        return MP4BoxHeader(type: type, size: size, headerLength: 8)
    }

    private func isPlausible(_ box: MP4BoxHeader) -> Bool {
        let knownTopLevel: Set<String> = [
            "ftyp", "moov", "moof", "mdat", "free", "skip", "wide", "udta", "trak", "meta",
        ]
        if box.type == "mdat" {
            return box.size <= 64 * 1024 * 1024 * 1024
        }
        if knownTopLevel.contains(box.type) {
            return box.size <= 4 * 1024 * 1024 * 1024
        }
        return false
    }
}
