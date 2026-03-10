import XCTest
@testable import Vivacity

final class RawDeviceReadPlanTests: XCTestCase {
    func testMakeLeavesAlignedReadUntouched() {
        let plan = RawDeviceReadPlan.make(offset: 4096, length: 4096, blockSize: 512)

        XCTAssertEqual(
            plan,
            RawDeviceReadPlan(
                requestedOffset: 4096,
                requestedLength: 4096,
                blockSize: 512,
                alignedOffset: 4096,
                alignedLength: 4096,
                payloadOffset: 0
            )
        )
        XCTAssertEqual(plan?.requiresBounceBuffer, false)
    }

    func testMakeExpandsUnalignedOffsetToBlockBoundaries() {
        let plan = RawDeviceReadPlan.make(offset: 3_621_872, length: 4096, blockSize: 512)

        XCTAssertEqual(plan?.alignedOffset, 3_621_376)
        XCTAssertEqual(plan?.alignedLength, 4608)
        XCTAssertEqual(plan?.payloadOffset, 496)
        XCTAssertEqual(plan?.requiresBounceBuffer, true)
    }

    func testMakeExpandsShortReadToWholeBlock() {
        let plan = RawDeviceReadPlan.make(offset: 943_783_936, length: 16, blockSize: 512)

        XCTAssertEqual(plan?.alignedOffset, 943_783_936)
        XCTAssertEqual(plan?.alignedLength, 512)
        XCTAssertEqual(plan?.payloadOffset, 0)
        XCTAssertEqual(plan?.requiresBounceBuffer, true)
    }

    func testPayloadRangeReturnsRequestedSliceWithinAlignedRead() throws {
        let plan = try XCTUnwrap(RawDeviceReadPlan.make(offset: 3_621_872, length: 4096, blockSize: 512))

        XCTAssertEqual(plan.payloadRange(for: 4608), 496 ..< 4592)
    }

    func testPayloadRangeSupportsPartialReadAfterAlignmentPadding() throws {
        let plan = try XCTUnwrap(RawDeviceReadPlan.make(offset: 3_621_872, length: 4096, blockSize: 512))

        XCTAssertEqual(plan.payloadRange(for: 1000), 496 ..< 1000)
    }
}
