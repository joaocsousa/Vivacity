import Foundation

enum DiskReaderFactoryProvider {
    static func makeReader(for device: StorageDevice) -> any PrivilegedDiskReading {
        let volumeInfo = VolumeInfo.detect(for: device)
        return makeReader(forPath: volumeInfo.devicePath)
    }

    static func makeReader(forPath path: String) -> any PrivilegedDiskReading {
        if path.hasPrefix("/dev/") {
            return PrivilegedDiskReader(devicePath: path)
        }
        return RegularFileDiskReader(filePath: path)
    }
}

/// File-based implementation of `PrivilegedDiskReading` used for local disk image files.
final class RegularFileDiskReader: PrivilegedDiskReading, @unchecked Sendable {
    private let filePath: String
    private var fd: Int32 = -1

    init(filePath: String) {
        self.filePath = filePath
    }

    deinit {
        stop()
    }

    var isSeekable: Bool {
        fd >= 0
    }

    func start() throws {
        let newFD = open(filePath, O_RDONLY)
        if newFD < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fd = newFD
    }

    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        guard fd >= 0 else { return -1 }
        return pread(fd, buffer, length, off_t(offset))
    }

    func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}
