import Foundation
import XCTest
@testable import Vivacity

@MainActor
final class FileScanSampleVerificationTests: XCTestCase {
    func testVerifySelectedSamplesBuildsWarningSummary() async {
        let file = makeFile(id: 1, source: .deepScan)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.fileFound(file), .completed]),
            deepScanService: FakeDeepScanService(events: []),
            fileSampleVerifier: FakeSampleVerifier(
                results: [FileSampleVerification(file: file, status: .mismatch, headHash: nil, tailHash: nil)]
            )
        )

        let device = makeDevice()
        sut.startFastScan(device: device)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let summary = await sut.verifySelectedSamples(device: device)
        XCTAssertEqual(summary?.verifiedCount, 0)
        XCTAssertEqual(summary?.mismatchCount, 1)
        XCTAssertEqual(summary?.unreadableCount, 0)
        XCTAssertEqual(summary?.hasWarnings, true)
    }

    func testVerifySelectedSamplesBlockingMessageIncludesUnreadableReason() async {
        let file = makeFile(id: 3, source: .deepScan)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.fileFound(file), .completed]),
            deepScanService: FakeDeepScanService(events: []),
            fileSampleVerifier: FakeSampleVerifier(
                results: [
                    FileSampleVerification(
                        file: file,
                        status: .unreadable,
                        headHash: nil,
                        tailHash: nil,
                        failureReason: "head sample pass 1: Privileged helper returned EOF"
                    ),
                ]
            )
        )

        let device = makeDevice()
        sut.startFastScan(device: device)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let summary = await sut.verifySelectedSamples(device: device)
        XCTAssertEqual(
            summary?.blockingMessage,
            "1 file(s) could not be read during sample verification. " +
                "Reason: head sample pass 1: Privileged helper returned EOF (1) " +
                "Preview and recovery are unavailable until the source bytes can be read again."
        )
    }

    func testVerifySelectedSamplesReturnsNilWhenNothingSelected() async {
        let file = makeFile(id: 2, source: .deepScan)
        let sut = FileScanViewModel(
            fastScanService: FakeFastScanService(events: [.fileFound(file), .completed]),
            deepScanService: FakeDeepScanService(events: []),
            fileSampleVerifier: FakeSampleVerifier(results: [])
        )

        let device = makeDevice()
        sut.startFastScan(device: device)
        try? await Task.sleep(nanoseconds: 50_000_000)
        sut.deselectAll()

        let summary = await sut.verifySelectedSamples(device: device)
        XCTAssertNil(summary)
    }

    private func makeDevice() -> StorageDevice {
        StorageDevice(
            id: UUID().uuidString,
            name: "Fake",
            volumePath: URL(fileURLWithPath: "/"),
            volumeUUID: "fake-uuid",
            filesystemType: .apfs,
            isExternal: true,
            isDiskImage: false,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 10_000_000,
            availableCapacity: 5_000_000
        )
    }

    private func makeFile(id: Int, source: ScanSource) -> RecoverableFile {
        RecoverableFile(
            id: UUID(),
            fileName: "file_\(id)",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 1024,
            offsetOnDisk: UInt64(id * 4096),
            signatureMatch: .jpeg,
            source: source,
            isLikelyContiguous: true
        )
    }
}

private struct FakeSampleVerifier: FileSampleVerifying {
    let results: [FileSampleVerification]

    func verifySamples(files _: [RecoverableFile], from _: StorageDevice) async throws -> [FileSampleVerification] {
        results
    }
}
