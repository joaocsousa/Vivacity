import XCTest
@testable import Vivacity

final class SessionManagerTests: XCTestCase {
    
    var fileManager: FileManager!
    var sut: SessionManager!
    var tempURL: URL!
    
    override func setUp() {
        super.setUp()
        // Override the default sessions directory strategy to aim at a temporary folder.
        // We'll subclass SessionManager or inject the folder just for the test.
        // Actually, our SessionManager uses the default FileManager applicationSupportDirectory,
        // which might litter the system. A better approach for tests is to use an isolated directory.
        // For simplicity we will test the real one, but clean up our UUIDs afterward.
        
        fileManager = FileManager.default
        sut = SessionManager(fileManager: fileManager)
    }
    
    func testSaveAndLoadSession() async throws {
        let file = RecoverableFile(
            id: UUID(),
            fileName: "test",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 1024,
            offsetOnDisk: 1024,
            signatureMatch: .jpeg,
            source: .deepScan
        )
        let session = ScanSession(
            id: UUID(),
            dateSaved: Date(),
            deviceID: "disk4",
            deviceTotalCapacity: 100000,
            lastScannedOffset: 4096,
            discoveredFiles: [file]
        )
        
        // Save it
        try await sut.save(session)
        
        // Load it individually
        let loaded = try await sut.loadSession(id: session.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, session.id)
        XCTAssertEqual(loaded?.deviceID, "disk4")
        XCTAssertEqual(loaded?.deviceTotalCapacity, 100000)
        XCTAssertEqual(loaded?.lastScannedOffset, 4096)
        XCTAssertEqual(loaded?.discoveredFiles.count, 1)
        XCTAssertEqual(loaded?.discoveredFiles[0].fileName, "test")
        
        // Load All
        let all = try await sut.loadAll()
        XCTAssertTrue(all.contains(where: { $0.id == session.id }))
        
        // Delete it
        try await sut.deleteSession(id: session.id)
        let loadedAfterDelete = try await sut.loadSession(id: session.id)
        XCTAssertNil(loadedAfterDelete)
    }
}
