import XCTest
@testable import Vivacity

final class APFSSpaceManagerTests: XCTestCase {
    
    func testAPFSSpaceManagerFailsGracefully() async throws {
        let fakeReader = FakePrivilegedDiskReader(buffer: Data(repeating: 0, count: 4096))
        let mapper = APFSSpaceManager(reader: fakeReader) // Using fallback stub
        
        var ranges: [FreeSpaceRange] = []
        for try await range in mapper.freeSpaceRanges() {
            ranges.append(range)
        }
        
        // The fallback behavior currently yields no ranges so deep scan falls back to contiguous
        XCTAssertTrue(ranges.isEmpty, "APFS Spaceman fallback should return empty map for now")
    }
}
