import XCTest
@testable import Vivacity

final class FragmentedVideoAssemblerTests: XCTestCase {
    
    func testAssembleReturnsFiles() {
        let fakeReader = FakePrivilegedDiskReader(buffer: Data())
        let assembler = FragmentedVideoAssembler()
        
        let file1 = RecoverableFile(
            id: UUID(),
            fileName: "GOPR0001",
            fileExtension: "mp4",
            fileType: .video,
            sizeInBytes: 0,
            offsetOnDisk: 1024,
            signatureMatch: .mp4,
            source: .deepScan
        )
        
        let files = [file1]
        let result = assembler.assemble(from: files, reader: fakeReader)
        
        // Currently, it just passes them through while logging heuristics
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.fileName, "GOPR0001")
        XCTAssertEqual(result.first?.sizeInBytes, 0)
    }
}
