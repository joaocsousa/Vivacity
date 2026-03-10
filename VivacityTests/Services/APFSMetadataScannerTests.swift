import XCTest
@testable import Vivacity

final class APFSMetadataScannerTests: XCTestCase {
    func testScanEmitsJPEGFromStructuredAPFSRecords() async throws {
        let fixture = APFSTestImageFixture.makeStructuredJPEG(
            pathComponents: ["Users", "Pictures", "deleted_photo.jpg"]
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        let file = try XCTUnwrap(foundFiles(in: events).first)

        XCTAssertEqual(file.fileName, "deleted_photo")
        XCTAssertEqual(file.fileExtension, "jpg")
        XCTAssertEqual(file.filePath, fixture.filePath)
        XCTAssertEqual(file.offsetOnDisk, fixture.fragmentMap.first?.start)
        XCTAssertEqual(file.sizeInBytes, Int64(fixture.fileData.count))
        XCTAssertEqual(file.fragmentMap, fixture.fragmentMap)
    }

    func testScanEmitsHEICFromStructuredMultiExtentAPFSRecords() async throws {
        let fixture = APFSTestImageFixture.makeStructuredHEIC(
            pathComponents: ["Users", "Pictures", "deleted_live.heic"]
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        let file = try XCTUnwrap(foundFiles(in: events).first)

        XCTAssertEqual(file.fileName, "deleted_live")
        XCTAssertEqual(file.fileExtension, "heic")
        XCTAssertEqual(file.sizeInBytes, Int64(fixture.fileData.count))
        XCTAssertEqual(file.fragmentMap, fixture.fragmentMap)
    }

    func testScanSuppressesStructuredAPFSFilesWithoutResolvableExtents() async throws {
        let fixture = APFSTestImageFixture.makeStructuredImage(
            spec: .init(
                pathComponents: ["Users", "Pictures", "missing_photo.jpg"],
                fileID: 32,
                privateID: 302,
                fragments: [],
                physicalBlocks: []
            ),
            totalBlocks: 4
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        XCTAssertTrue(foundFiles(in: events).isEmpty)
    }

    func testScanIgnoresStructuredAPFSNonImageRecords() async throws {
        let fixture = APFSTestImageFixture.makeStructuredImage(
            spec: .init(
                pathComponents: ["Users", "Documents", "notes.txt"],
                fileID: 33,
                privateID: 303,
                fragments: [Data("hello world".utf8)],
                physicalBlocks: [3]
            ),
            totalBlocks: 5
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        XCTAssertTrue(foundFiles(in: events).isEmpty)
    }

    func testScanEmitsJPEGFromAPFSMetadataHint() async throws {
        let jpegData = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xD9,
        ])
        let fixture = APFSTestImageFixture.makeHintImage(
            path: "Users/demo/Pictures/deleted_photo.jpg",
            fileData: jpegData,
            dataOffset: 5000,
            totalBytes: 8192
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        let file = try XCTUnwrap(foundFiles(in: events).first)

        XCTAssertEqual(file.fileName, "deleted_photo")
        XCTAssertEqual(file.fileExtension, "jpg")
        XCTAssertEqual(file.offsetOnDisk, fixture.fragmentMap.first?.start)
        XCTAssertEqual(file.fragmentMap, fixture.fragmentMap)
    }

    func testScanEmitsHEICFromAPFSMetadataHint() async throws {
        let heicData = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63, 0x00, 0x00, 0x00, 0x00,
            0x68, 0x65, 0x69, 0x63, 0x6D, 0x69, 0x66, 0x31,
            0x00, 0x00, 0x00, 0x10, 0x6D, 0x64, 0x61, 0x74,
            0xDE, 0xAD, 0xBE, 0xEF, 0xAA, 0xBB, 0xCC, 0xDD,
        ])
        let fixture = APFSTestImageFixture.makeHintImage(
            path: "Users/demo/Pictures/deleted_live.heic",
            fileData: heicData,
            dataOffset: 7000,
            totalBytes: 12288
        )

        let events = try await collectEvents(for: fixture.disk, volumeInfo: fixture.volumeInfo)
        let file = try XCTUnwrap(foundFiles(in: events).first)

        XCTAssertEqual(file.fileName, "deleted_live")
        XCTAssertEqual(file.fileExtension, "heic")
        XCTAssertEqual(file.offsetOnDisk, fixture.fragmentMap.first?.start)
        XCTAssertEqual(file.sizeInBytes, Int64(fixture.fileData.count))
    }

    private func collectEvents(for disk: Data, volumeInfo: VolumeInfo) async throws -> [ScanEvent] {
        let scanner = APFSMetadataScanner()
        let reader = FakePrivilegedDiskReader(buffer: disk)
        return try await collectEvents { continuation in
            try await scanner.scan(
                volumeInfo: volumeInfo,
                reader: reader,
                totalBytes: UInt64(disk.count),
                continuation: continuation
            )
        }
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

    private func foundFiles(in events: [ScanEvent]) -> [RecoverableFile] {
        events.compactMap { event in
            if case let .fileFound(file) = event {
                return file
            }
            return nil
        }
    }
}
