import Foundation
import XCTest
@testable import Vivacity

final class FileRecoveryServiceTests: XCTestCase {
    private struct MissingAPFSScannerHit: Error {}

    func testRecoverWritesBytesAtOffsetToDestination() async throws {
        let sourceData = Data((0 ..< 255).map(UInt8.init))
        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL)
        let file = makeFile(name: "IMG_1001", ext: "jpg", offset: 25, size: 100)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [file],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.recoveredFiles.count, 1)

        let recoveredData = try Data(contentsOf: result.recoveredFiles[0])
        XCTAssertEqual(recoveredData, sourceData.subdata(in: 25 ..< 125))
    }

    func testRecoverContinuesWhenOneFileFails() async throws {
        let sourceData = Data((0 ..< 128).map(UInt8.init))
        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL)
        let validFile = makeFile(name: "clip", ext: "mp4", offset: 10, size: 40)
        let invalidFile = makeFile(name: "broken", ext: "jpg", offset: 5000, size: 64)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [validFile, invalidFile],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.recoveredFiles.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.file.fullFileName, invalidFile.fullFileName)
    }

    func testRecoverRemovesPlaceholderFileWhenRecoveryFails() async throws {
        let sourceData = Data((0 ..< 128).map(UInt8.init))
        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL)
        let invalidFile = makeFile(name: "broken", ext: "jpg", offset: 5000, size: 64)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [invalidFile],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.recoveredFiles.count, 0)
        XCTAssertEqual(result.failures.count, 1)
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(directoryContents.isEmpty)
    }

    func testRecoverUsesCollisionSafeFileNames() async throws {
        let sourceData = Data((0 ..< 64).map(UInt8.init))
        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let existingURL = destinationURL.appendingPathComponent("IMG_1001.jpg")
        _ = FileManager.default.createFile(atPath: existingURL.path, contents: Data([0xAA]), attributes: nil)

        let device = makeDiskImageDevice(at: sourceURL)
        let file = makeFile(name: "IMG_1001", ext: "jpg", offset: 0, size: 32)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [file],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.recoveredFiles.count, 1)
        XCTAssertEqual(result.recoveredFiles[0].lastPathComponent, "IMG_1001 (1).jpg")
    }

    func testRecoverUsesMetadataDrivenNameWhenAvailable() async throws {
        var sourceData = Data(repeating: 0, count: 512)
        sourceData[0] = 0xFF
        sourceData[1] = 0xD8
        let metadataBytes = Array("2024:11:23 18:45:01+02:00 Canon EOS R5".utf8)
        sourceData.replaceSubrange(64 ..< 64 + metadataBytes.count, with: metadataBytes)

        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL)
        let file = makeFile(name: "IMG_1001", ext: "jpg", offset: 0, size: 256)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [file],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.recoveredFiles.count, 1)
        XCTAssertEqual(result.recoveredFiles[0].lastPathComponent, "20241123_184501+0200_Canon.jpg")
    }

    func testRecoverAssemblesFragmentMapRangesInOrder() async throws {
        let sourceData = Data([0x01, 0x02, 0x03, 0xAA, 0xBB, 0x04, 0x05])
        let sourceURL = try makeSourceImage(data: sourceData)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL)
        let file = RecoverableFile(
            id: UUID(),
            fileName: "fragmented",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 5,
            offsetOnDisk: 0,
            signatureMatch: .jpeg,
            source: .fastScan,
            isLikelyContiguous: false,
            fragmentMap: [
                FragmentRange(start: 0, length: 3),
                FragmentRange(start: 5, length: 2),
            ]
        )
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [file],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        let recoveredData = try Data(contentsOf: XCTUnwrap(result.recoveredFiles.first))
        XCTAssertEqual(recoveredData, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testVerifySamplesReturnsMismatchWhenHashesChangeBetweenReads() async throws {
        let device = try makeDiskImageDevice(at: makeSourceImage(data: Data(repeating: 0xAA, count: 512)))
        let file = makeFile(name: "clip", ext: "mov", offset: 0, size: 256)
        let service = FileRecoveryService(diskReaderFactory: { _ in
            FlakySampleReader()
        })

        let results = try await service.verifySamples(files: [file], from: device)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .mismatch)
    }

    func testVerifySamplesReturnsUnreadableWhenReadFails() async throws {
        let device = try makeDiskImageDevice(at: makeSourceImage(data: Data(repeating: 0xAA, count: 512)))
        let file = makeFile(name: "clip", ext: "mov", offset: 0, size: 256)
        let service = FileRecoveryService(diskReaderFactory: { _ in
            UnreadableSampleReader()
        })

        let results = try await service.verifySamples(files: [file], from: device)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .unreadable)
        XCTAssertEqual(
            results.first?.failureReason,
            "head sample pass 1: Privileged helper returned EOF"
        )
    }

    func testVerifySamplesReadsHeadAndTailAcrossFragments() async throws {
        let sourceData = Data([0x10, 0x11, 0x12, 0xAA, 0xBB, 0x20, 0x21, 0x22])
        let device = try makeDiskImageDevice(at: makeSourceImage(data: sourceData))
        let file = RecoverableFile(
            id: UUID(),
            fileName: "fragmented",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 6,
            offsetOnDisk: 0,
            signatureMatch: .jpeg,
            source: .fastScan,
            isLikelyContiguous: false,
            fragmentMap: [
                FragmentRange(start: 0, length: 3),
                FragmentRange(start: 5, length: 3),
            ]
        )
        let service = FileRecoveryService()

        let results = try await service.verifySamples(files: [file], from: device)

        XCTAssertEqual(results.first?.status, .verified)
    }

    func testRecoverScannerEmittedAPFSStructuredFileAssemblesImageBackedFragments() async throws {
        let fixture = APFSTestImageFixture.makeStructuredHEIC(
            pathComponents: ["Users", "Pictures", "deleted_live.heic"]
        )
        let sourceURL = try makeSourceImage(data: fixture.disk)
        let destinationURL = try makeTemporaryDirectory()
        let device = makeDiskImageDevice(at: sourceURL, filesystemType: .apfs)
        let file = try await makeAPFSScannerHit(from: fixture)
        let service = FileRecoveryService()

        let result = try await service.recover(
            files: [file],
            from: device,
            to: destinationURL,
            progressHandler: { _ in }
        )

        XCTAssertEqual(result.failures.count, 0)
        let recoveredData = try Data(contentsOf: XCTUnwrap(result.recoveredFiles.first))
        XCTAssertEqual(recoveredData, fixture.fileData)
    }

    func testVerifySamplesScannerEmittedAPFSStructuredFileReadsImageBackedFragments() async throws {
        let fixture = APFSTestImageFixture.makeStructuredHEIC(
            pathComponents: ["Users", "Pictures", "deleted_live.heic"]
        )
        let sourceURL = try makeSourceImage(data: fixture.disk)
        let device = makeDiskImageDevice(at: sourceURL, filesystemType: .apfs)
        let file = try await makeAPFSScannerHit(from: fixture)
        let service = FileRecoveryService()

        let results = try await service.verifySamples(files: [file], from: device)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .verified)
    }
}

extension FileRecoveryServiceTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directoryURL
    }

    private func makeSourceImage(data: Data) throws -> URL {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".img")
        try data.write(to: sourceURL)
        return sourceURL
    }

    private func makeDiskImageDevice(at url: URL, filesystemType: FilesystemType = .other) -> StorageDevice {
        StorageDevice(
            id: UUID().uuidString,
            name: "Disk Image",
            volumePath: url,
            volumeUUID: "DISK-IMAGE-UUID",
            filesystemType: filesystemType,
            isExternal: true,
            isDiskImage: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 1024 * 1024,
            availableCapacity: 1024 * 1024
        )
    }

    private func makeFile(name: String, ext: String, offset: UInt64, size: Int64) -> RecoverableFile {
        RecoverableFile(
            id: UUID(),
            fileName: name,
            fileExtension: ext,
            fileType: .image,
            sizeInBytes: size,
            offsetOnDisk: offset,
            signatureMatch: .jpeg,
            source: .deepScan,
            isLikelyContiguous: true
        )
    }

    private func makeAPFSScannerHit(from fixture: APFSTestImageFixture.Output) async throws -> RecoverableFile {
        let scanner = APFSMetadataScanner()
        let reader = FakePrivilegedDiskReader(buffer: fixture.disk)
        let stream = AsyncThrowingStream<ScanEvent, Error> { continuation in
            Task {
                do {
                    try await scanner.scan(
                        volumeInfo: fixture.volumeInfo,
                        reader: reader,
                        totalBytes: UInt64(fixture.disk.count),
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        for try await event in stream {
            if case let .fileFound(file) = event {
                return file
            }
        }

        XCTFail("Expected APFS structured scanner hit was not emitted.")
        throw MissingAPFSScannerHit()
    }
}

private final class FlakySampleReader: PrivilegedDiskReading, @unchecked Sendable {
    var isSeekable: Bool {
        true
    }

    private var readCount = 0

    func start() throws {}
    func stop() {}

    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        readCount += 1
        let byte: UInt8 = readCount <= 2 ? 0xAB : 0xCD
        memset(buffer, Int32(byte), length)
        return length
    }
}

private final class UnreadableSampleReader: PrivilegedDiskReading, @unchecked Sendable {
    var isSeekable: Bool {
        true
    }

    var lastReadFailureDescription: String? {
        "Privileged helper returned EOF"
    }

    func start() throws {}
    func stop() {}

    func read(into buffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        0
    }
}
