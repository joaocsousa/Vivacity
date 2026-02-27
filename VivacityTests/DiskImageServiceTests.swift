import XCTest
@testable import Vivacity

final class DiskImageServiceTests: XCTestCase {
    func testCreateImageSuccessfully() async throws {
        // Create 1MB of synthetic data
        let testData = Data(count: 1024 * 1024)
        let fakeReader = FakePrivilegedDiskReader(buffer: testData)
        let service = DiskImageService(diskReader: fakeReader)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dd")

        let device = StorageDevice(
            id: "test",
            name: "Test Device",
            volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "UUID",
            filesystemType: .other,
            isExternal: true,
            isDiskImage: false,
            partitionOffset: 0,
            partitionSize: 1024 * 1024,
            totalCapacity: 1024 * 1024,
            availableCapacity: 0
        )

        var progressValues: [Double] = []
        let stream = service.createImage(from: device, to: url)

        do {
            for try await progress in stream {
                progressValues.append(progress)
            }
        } catch {
            XCTFail("Stream failed with error: \(error)")
        }

        // Assert output file
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let outputData = try Data(contentsOf: url)
        XCTAssertEqual(outputData.count, testData.count)

        // Assert progress progressed
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressValues.last), 1.0, accuracy: 0.01)

        try? FileManager.default.removeItem(at: url)
    }
}
