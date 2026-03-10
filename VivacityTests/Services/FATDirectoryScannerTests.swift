import XCTest
@testable import Vivacity

final class FATDirectoryScannerTests: XCTestCase {
    func testScanFindsDeletedJPEGEntry() async throws {
        var disk = Data(repeating: 0, count: 2048)

        // FAT32 BPB
        disk[11] = 0x00
        disk[12] = 0x02 // 512 bytes/sector
        disk[13] = 0x01 // sectors/cluster
        disk[14] = 0x01 // reserved sectors
        disk[15] = 0x00
        disk[16] = 0x01 // number of FATs
        disk[36] = 0x01 // sectors/FAT
        disk[44] = 0x02 // root cluster
        disk[510] = 0x55
        disk[511] = 0xAA

        // FAT table at offset 512
        writeUInt32(0x0000_0000, to: &disk, offset: 512 + 4 * 2) // cluster 2 (root)
        writeUInt32(0x0000_0000, to: &disk, offset: 512 + 4 * 3) // cluster 3 (file data)

        // Root directory (cluster 2) starts at dataRegionOffset 1024
        let dirOffset = 1024
        disk[dirOffset + 0] = 0xE5 // deleted entry marker
        writeASCII("IMG0001", to: &disk, offset: dirOffset + 1, width: 7)
        writeASCII("JPG", to: &disk, offset: dirOffset + 8, width: 3)
        disk[dirOffset + 11] = 0x20 // archive
        disk[dirOffset + 26] = 0x03 // starting cluster low = 3
        disk[dirOffset + 27] = 0x00
        writeUInt32(100, to: &disk, offset: dirOffset + 28)
        disk[dirOffset + 32] = 0x00 // end-of-directory marker

        // File data at cluster 3 offset (1024 + 512)
        let fileOffset = 1536
        let jpegHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        for (i, b) in jpegHeader.enumerated() {
            disk[fileOffset + i] = b
        }

        let reader = FakePrivilegedDiskReader(buffer: disk)
        let scanner = FATDirectoryScanner()
        let events = try await collectEvents {
            try await scanner.scan(
                volumeInfo: VolumeInfo(
                    filesystemType: .fat32,
                    devicePath: "/dev/fake",
                    mountPoint: URL(fileURLWithPath: "/"),
                    blockSize: 512,
                    isInternal: false,
                    isBootable: false,
                    isFileVaultEnabled: false
                ),
                reader: reader,
                continuation: $0
            )
        }

        let files = events.compactMap { event -> RecoverableFile? in
            if case let .fileFound(file) = event { return file }
            return nil
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.fileExtension, "jpg")
        XCTAssertEqual(files.first?.signatureMatch, .jpeg)
        XCTAssertEqual(files.first?.sizeInBytes, 100)
        XCTAssertEqual(files.first?.offsetOnDisk, 1536)
    }

    private func collectEvents(
        _ scan: @escaping (AsyncThrowingStream<ScanEvent, Error>.Continuation) async throws -> Void
    ) async throws -> [ScanEvent] {
        let stream = AsyncThrowingStream<ScanEvent, Error> { continuation in
            Task {
                do {
                    try await scan(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        data[offset + 0] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeASCII(_ string: String, to data: inout Data, offset: Int, width: Int) {
        let bytes = Array(string.utf8)
        for i in 0 ..< width {
            data[offset + i] = i < bytes.count ? bytes[i] : 0x20
        }
    }
}
