import XCTest
@testable import Vivacity

final class FastScanServiceTests: XCTestCase {
    func testScanFindsSupportedFilesInTrashAndIgnoresUnsupported() async throws {
        let volumeRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: volumeRoot) }

        let trashDir = volumeRoot.appendingPathComponent(".Trashes/501", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let recoverableImage = trashDir.appendingPathComponent("deleted_photo.jpg")
        let ignoredText = trashDir.appendingPathComponent("notes.txt")

        try makeJPEGFile(at: recoverableImage)
        try Data("hello".utf8).write(to: ignoredText)

        let service = FastScanService(
            diskReaderFactory: { _ in FakePrivilegedDiskReader() },
            runTMUtilClosure: { _, _ in nil }
        )

        let events = try await collectEvents(from: service.scan(device: makeDevice(volumeRoot: volumeRoot)))

        let foundNames = events.compactMap { event -> String? in
            if case let .fileFound(file) = event {
                return file.fullFileName
            }
            return nil
        }

        XCTAssertEqual(foundNames, ["deleted_photo.jpg"])
        XCTAssertTrue(events.contains { event in
            if case let .progress(value) = event {
                return value == 1.0
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed = event {
                return true
            }
            return false
        })
    }

    func testScanAPFSSnapshotsEmitsOnlyFilesMissingFromLiveVolume() async throws {
        let volumeRoot = try makeTemporaryDirectory()
        let snapshotRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: volumeRoot)
            try? FileManager.default.removeItem(at: snapshotRoot)
        }

        let device = makeDevice(volumeRoot: volumeRoot)
        let detectedFS = VolumeInfo.detect(for: device).filesystemType
        guard detectedFS == .apfs else {
            throw XCTSkip("APFS snapshot flow is only valid on APFS volumes (detected: \(detectedFS.rawValue)).")
        }

        let deletedInLivePath = "DCIM/deleted_from_live.jpg"
        let stillInLivePath = "DCIM/still_live.jpg"

        let deletedInSnapshot = snapshotRoot.appendingPathComponent(deletedInLivePath)
        let stillInSnapshot = snapshotRoot.appendingPathComponent(stillInLivePath)
        let stillInLive = volumeRoot.appendingPathComponent(stillInLivePath)

        try FileManager.default.createDirectory(
            at: deletedInSnapshot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeJPEGFile(at: deletedInSnapshot)
        try makeJPEGFile(at: stillInSnapshot)

        try FileManager.default.createDirectory(
            at: stillInLive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeJPEGFile(at: stillInLive)

        let snapshotName = "com.apple.TimeMachine.2026-03-03-000000.local"
        let service = FastScanService(
            diskReaderFactory: { _ in FakePrivilegedDiskReader() },
            runTMUtilClosure: { _, _ in snapshotName },
            mountSnapshotClosure: { name, _, _ in
                XCTAssertEqual(name, snapshotName)
                return snapshotRoot
            },
            unmountSnapshotClosure: { _, _ in }
        )

        let events = try await collectEvents(from: service.scan(device: device))

        let foundNames = events.compactMap { event -> String? in
            if case let .fileFound(file) = event {
                return file.fullFileName
            }
            return nil
        }

        XCTAssertEqual(foundNames, ["deleted_from_live.jpg"])
    }

    private func collectEvents(from stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> [ScanEvent] {
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastscan-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeJPEGFile(at url: URL) throws {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        try Data(bytes).write(to: url)
    }

    private func makeDevice(volumeRoot: URL) -> StorageDevice {
        StorageDevice(
            id: volumeRoot.absoluteString,
            name: "TestVolume",
            volumePath: volumeRoot,
            volumeUUID: UUID().uuidString,
            filesystemType: .apfs,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 1_000_000,
            availableCapacity: 500_000
        )
    }
}
