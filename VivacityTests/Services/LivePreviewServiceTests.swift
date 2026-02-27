import XCTest
@testable import Vivacity

final class LivePreviewServiceTests: XCTestCase {
    
    var sut: LivePreviewService!
    var mockReader: FakePrivilegedDiskReader!
    
    override func setUp() async throws {
        try await super.setUp()
        sut = LivePreviewService()
        await sut.clearCache()
        mockReader = FakePrivilegedDiskReader()
    }
    
    override func tearDown() async throws {
        await sut.clearCache()
        sut = nil
        mockReader = nil
        try await super.tearDown()
    }
    
    func testGeneratePreviewURL_withFastScanFile_returnsNil() async throws {
        let file = RecoverableFile(
            id: UUID(),
            fileName: "test",
            fileExtension: "txt",
            fileType: .document,
            sizeInBytes: 100,
            offsetOnDisk: 0,
            signatureMatch: nil,
            source: .fastScan
        )
        
        let url = try await sut.generatePreviewURL(for: file, reader: mockReader)
        XCTAssertNil(url, "Should return nil for Fast Scan files as they don't need extraction")
    }
    
    func testGeneratePreviewURL_withDeepScanFile_extractsCorrectly() async throws {
        // Prepare some fake data representing the disk contents
        let fileData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let offset: UInt64 = 1024
        
        var diskBuffer = Data(repeating: 0, count: Int(offset))
        diskBuffer.append(fileData)
        diskBuffer.append(Data(repeating: 0, count: 500)) // Trailing zeros
        
        mockReader.buffer = diskBuffer
        
        let file = RecoverableFile(
            id: UUID(),
            fileName: "test",
            fileExtension: "bin",
            fileType: .document,
            sizeInBytes: UInt64(fileData.count),
            offsetOnDisk: offset,
            signatureMatch: nil,
            source: .deepScan
        )
        
        let url = try await sut.generatePreviewURL(for: file, reader: mockReader)
        XCTAssertNotNil(url)
        
        let extractedData = try Data(contentsOf: url!)
        XCTAssertEqual(extractedData, fileData, "Extracted data should exactly match the mock disk contents")
    }
    
    func testGeneratePreviewURL_cachesResult() async throws {
        let fileData = Data([0xAA, 0xBB])
        mockReader.buffer = fileData
        
        let file = RecoverableFile(
            id: UUID(),
            fileName: "cached",
            fileExtension: "bin",
            fileType: .document,
            sizeInBytes: UInt64(fileData.count),
            offsetOnDisk: 0,
            signatureMatch: nil,
            source: .deepScan
        )
        
        let firstURL = try await sut.generatePreviewURL(for: file, reader: mockReader)
        XCTAssertNotNil(firstURL)
        
        // Change disk buffer. If it reads again, the data would change.
        mockReader.buffer = Data([0xCC, 0xDD])
        
        let secondURL = try await sut.generatePreviewURL(for: file, reader: mockReader)
        XCTAssertEqual(firstURL, secondURL, "Should return the same URL from cache")
        
        let extractedData = try Data(contentsOf: secondURL!)
        XCTAssertEqual(extractedData, fileData, "Data should match the first extraction due to caching")
    }
}
