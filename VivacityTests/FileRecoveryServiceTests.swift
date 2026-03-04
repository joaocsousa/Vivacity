import Foundation
import XCTest
@testable import Vivacity

final class FileRecoveryServiceTests: XCTestCase {
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

    private func makeDiskImageDevice(at url: URL) -> StorageDevice {
        StorageDevice(
            id: UUID().uuidString,
            name: "Disk Image",
            volumePath: url,
            volumeUUID: "DISK-IMAGE-UUID",
            filesystemType: .other,
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
}
