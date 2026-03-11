import XCTest
@testable import Vivacity

final class APFSSpaceManagerTests: XCTestCase {
    
    func testAPFSSpaceManagerFailsGracefully() async {
        let fakeReader = FakePrivilegedDiskReader(buffer: Data(repeating: 0, count: 4096))
        let mapper = APFSSpaceManager(reader: fakeReader) // Using fallback stub
        
        var ranges: [FreeSpaceRange] = []
        var caughtError: Error?
        
        do {
            for try await range in mapper.freeSpaceRanges() {
                ranges.append(range)
            }
        } catch {
            caughtError = error
        }
        
        XCTAssertNotNil(caughtError, "Should throw an unsupportedSpaceman error")
        XCTAssertTrue(ranges.isEmpty, "APFS Spaceman fallback should return empty map for now")
    }
}
