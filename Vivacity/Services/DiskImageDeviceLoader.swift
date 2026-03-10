import Foundation

enum DiskImageDeviceLoader {
    static func makeStorageDevice(from url: URL) -> StorageDevice {
        let path = url.path
        let fileSize = fileSize(at: path)
        let filesystemType = DiskImageFilesystemDetector.detect(at: path)

        return StorageDevice(
            id: url.absoluteString,
            name: url.lastPathComponent,
            volumePath: url,
            volumeUUID: UUID().uuidString,
            filesystemType: filesystemType,
            isExternal: true,
            isDiskImage: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: fileSize,
            availableCapacity: 0
        )
    }

    static func fileSize(at path: String) -> Int64 {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber
        {
            return size.int64Value
        }
        return 0
    }
}

enum DiskImageFilesystemDetector {
    static func detect(at path: String) -> FilesystemType {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return .other
        }
        defer { try? handle.close() }

        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if head.count >= 36 {
            let apfsMagic = String(bytes: head[32 ..< 36], encoding: .ascii) ?? ""
            if apfsMagic == "BSXN" || apfsMagic == "BSPA" {
                return .apfs
            }
        }

        if head.count >= 11 {
            let ntfsMagic = String(bytes: head[3 ..< 11], encoding: .ascii) ?? ""
            if ntfsMagic == "NTFS    " {
                return .ntfs
            }
            let exfatMagic = String(bytes: head[3 ..< 11], encoding: .ascii) ?? ""
            if exfatMagic == "EXFAT   " {
                return .exfat
            }
        }

        if head.count >= 90 {
            let fat32Magic = String(bytes: head[82 ..< 90], encoding: .ascii) ?? ""
            if fat32Magic.hasPrefix("FAT32") {
                return .fat32
            }
        }

        if head.count >= 62 {
            let fat16Magic = String(bytes: head[54 ..< 62], encoding: .ascii) ?? ""
            if fat16Magic.hasPrefix("FAT") {
                return .fat32
            }
        }

        if let volumeHeader = try? readBytes(handle: handle, offset: 1024, length: 2),
           let signature = String(data: volumeHeader, encoding: .ascii),
           signature == "H+" || signature == "HX"
        {
            return .hfsPlus
        }

        return .other
    }

    private static func readBytes(handle: FileHandle, offset: UInt64, length: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}
