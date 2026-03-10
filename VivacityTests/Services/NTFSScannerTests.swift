import XCTest
@testable import Vivacity

final class NTFSScannerTests: XCTestCase {
    func testScanFindsDeletedMFTRecord() async throws {
        var disk = Data(repeating: 0, count: 2200)

        // NTFS boot sector
        writeASCII("NTFS    ", to: &disk, offset: 3)
        disk[11] = 0x00
        disk[12] = 0x02 // 512 bytes/sector
        disk[13] = 0x01 // sectors/cluster
        writeUInt64(1, to: &disk, offset: 48) // MFT at cluster 1 => offset 512
        disk[64] = 0xF6 // -10 => 2^10 = 1024-byte records

        // First MFT record at offset 512
        let recordOffset = 512
        writeASCII("FILE", to: &disk, offset: recordOffset)
        writeUInt16(56, to: &disk, offset: recordOffset + 20) // first attr offset
        writeUInt16(0, to: &disk, offset: recordOffset + 22) // deleted, not directory

        // Filename attribute (resident) at offset 56
        let fileNameAttrOffset = recordOffset + 56
        writeUInt32(0x30, to: &disk, offset: fileNameAttrOffset)
        writeUInt32(128, to: &disk, offset: fileNameAttrOffset + 4)
        disk[fileNameAttrOffset + 8] = 0 // resident
        writeUInt16(24, to: &disk, offset: fileNameAttrOffset + 20) // content offset

        let fileNameContentOffset = fileNameAttrOffset + 24
        disk[fileNameContentOffset + 64] = 9 // name length
        disk[fileNameContentOffset + 65] = 1 // Win32 namespace
        writeUTF16LE("photo.jpg", to: &disk, offset: fileNameContentOffset + 66)

        // Data attribute (non-resident) after filename attribute
        let dataAttrOffset = fileNameAttrOffset + 128
        writeUInt32(0x80, to: &disk, offset: dataAttrOffset)
        writeUInt32(80, to: &disk, offset: dataAttrOffset + 4)
        disk[dataAttrOffset + 8] = 1 // non-resident
        writeUInt16(64, to: &disk, offset: dataAttrOffset + 32) // data run offset
        writeUInt64(200, to: &disk, offset: dataAttrOffset + 48) // file size

        // First data run: length=1 cluster, offset=+3 clusters
        disk[dataAttrOffset + 64] = 0x11 // length bytes=1, offset bytes=1
        disk[dataAttrOffset + 65] = 0x01
        disk[dataAttrOffset + 66] = 0x03
        disk[dataAttrOffset + 67] = 0x00

        // End marker
        writeUInt32(0xFFFF_FFFF, to: &disk, offset: dataAttrOffset + 80)

        // File bytes at cluster 3 offset: 1536
        let fileOffset = 1536
        let jpegHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        for (i, b) in jpegHeader.enumerated() {
            disk[fileOffset + i] = b
        }

        let reader = FakePrivilegedDiskReader(buffer: disk)
        let scanner = NTFSScanner()
        let events = try await collectEvents {
            try await scanner.scan(
                volumeInfo: VolumeInfo(
                    filesystemType: .ntfs,
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
        XCTAssertEqual(files.first?.sizeInBytes, 200)
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

    private func writeUInt16(_ value: UInt16, to data: inout Data, offset: Int) {
        data[offset + 0] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
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

    private func writeUTF16LE(_ string: String, to data: inout Data, offset: Int) {
        for (i, codeUnit) in string.utf16.enumerated() {
            data[offset + i * 2] = UInt8(codeUnit & 0xFF)
            data[offset + i * 2 + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
    }
}
