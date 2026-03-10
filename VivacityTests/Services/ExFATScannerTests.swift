import XCTest
@testable import Vivacity

final class ExFATScannerTests: XCTestCase {
    func testScanFindsDeletedExFATEntrySet() async throws {
        var disk = Data(repeating: 0, count: 2048)

        // ExFAT boot sector
        writeASCII("EXFAT   ", to: &disk, offset: 3)
        disk[108] = 9 // bytes/sector = 2^9 = 512
        disk[109] = 0 // sectors/cluster = 1
        writeUInt32(1, to: &disk, offset: 88) // cluster heap starts at sector 1
        writeUInt32(32, to: &disk, offset: 92) // total clusters
        writeUInt32(2, to: &disk, offset: 96) // root dir cluster

        // Root directory (cluster 2) at offset 512
        let dirOffset = 512

        // Deleted file entry
        disk[dirOffset + 0] = 0x05
        disk[dirOffset + 1] = 0x02 // secondary count = stream + filename

        // Deleted stream extension (entry 1)
        let streamOffset = dirOffset + 32
        disk[streamOffset + 0] = 0x40
        writeUInt32(3, to: &disk, offset: streamOffset + 20) // starting cluster
        writeUInt64(120, to: &disk, offset: streamOffset + 24) // file size

        // Deleted file name entry (entry 2)
        let fileNameOffset = dirOffset + 64
        disk[fileNameOffset + 0] = 0x41
        writeUTF16LE("photo.jpg", to: &disk, offset: fileNameOffset + 2, maxChars: 15)

        // End-of-directory marker
        disk[dirOffset + 96] = 0x00

        // File bytes at cluster 3 offset: 1024
        let fileOffset = 1024
        let jpegHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10, 0x45, 0x78, 0x69, 0x66]
        for (i, b) in jpegHeader.enumerated() {
            disk[fileOffset + i] = b
        }

        let reader = FakePrivilegedDiskReader(buffer: disk)
        let scanner = ExFATScanner()

        let events = try await collectEvents {
            try await scanner.scan(
                volumeInfo: VolumeInfo(
                    filesystemType: .exfat,
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
        XCTAssertEqual(files.first?.fileName, "photo")
        XCTAssertEqual(files.first?.fileExtension, "jpg")
        XCTAssertEqual(files.first?.signatureMatch, .jpeg)
        XCTAssertEqual(files.first?.sizeInBytes, 120)
        XCTAssertEqual(files.first?.offsetOnDisk, 1024)
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

    private func writeUInt64(_ value: UInt64, to data: inout Data, offset: Int) {
        for i in 0 ..< 8 {
            data[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    private func writeASCII(_ string: String, to data: inout Data, offset: Int) {
        for (i, byte) in string.utf8.enumerated() {
            data[offset + i] = byte
        }
    }

    private func writeUTF16LE(_ string: String, to data: inout Data, offset: Int, maxChars: Int) {
        let codeUnits = Array(string.utf16.prefix(maxChars))
        for (index, codeUnit) in codeUnits.enumerated() {
            data[offset + index * 2] = UInt8(codeUnit & 0xFF)
            data[offset + index * 2 + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
    }
}
