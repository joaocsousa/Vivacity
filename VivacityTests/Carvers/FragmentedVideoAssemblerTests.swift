import XCTest
@testable import Vivacity

final class FragmentedVideoAssemblerTests: XCTestCase {
    private func makeBox(type: String, size: UInt32) -> Data {
        var data = Data()
        var bigEndianSize = size.bigEndian
        data.append(Data(bytes: &bigEndianSize, count: 4))
        data.append(type.data(using: .ascii)!)
        let payload = Int(size) - 8
        if payload > 0 {
            data.append(Data(repeating: 0x11, count: payload))
        }
        return data
    }

    func testAssembleInfersPlayableFragmentedMP4Size() {
        var buffer = Data()
        buffer.append(makeBox(type: "moov", size: 32))
        buffer.append(Data(repeating: 0x00, count: 512))
        buffer.append(makeBox(type: "mdat", size: 128))

        let fakeReader = FakePrivilegedDiskReader(buffer: buffer)
        let assembler = FragmentedVideoAssembler()

        let file1 = RecoverableFile(
            id: UUID(),
            fileName: "GOPR0001",
            fileExtension: "mp4",
            fileType: .video,
            sizeInBytes: 0,
            offsetOnDisk: 0,
            signatureMatch: .mp4,
            source: .deepScan
        )

        let files = [file1]
        let result = assembler.assemble(from: files, reader: fakeReader)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.fileName, "GOPR0001")
        XCTAssertGreaterThan(result.first?.sizeInBytes ?? 0, 0)
        XCTAssertEqual(result.first?.isLikelyContiguous, false)
    }

    func testAssembleLeavesUnknownLayoutAsUnbounded() {
        let fakeReader = FakePrivilegedDiskReader(buffer: Data(repeating: 0x00, count: 4096))
        let assembler = FragmentedVideoAssembler()

        let file = RecoverableFile(
            id: UUID(),
            fileName: "clip",
            fileExtension: "mp4",
            fileType: .video,
            sizeInBytes: 0,
            offsetOnDisk: 0,
            signatureMatch: .mp4,
            source: .deepScan
        )

        let result = assembler.assemble(from: [file], reader: fakeReader)
        XCTAssertEqual(result.first?.sizeInBytes, 0)
    }
}
