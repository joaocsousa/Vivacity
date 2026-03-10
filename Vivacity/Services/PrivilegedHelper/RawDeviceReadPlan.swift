import Foundation

struct RawDeviceReadPlan: Sendable, Equatable {
    let requestedOffset: UInt64
    let requestedLength: Int
    let blockSize: Int
    let alignedOffset: UInt64
    let alignedLength: Int
    let payloadOffset: Int

    var requiresBounceBuffer: Bool {
        alignedOffset != requestedOffset || alignedLength != requestedLength
    }

    static func make(offset: UInt64, length: Int, blockSize: Int) -> RawDeviceReadPlan? {
        guard length > 0, blockSize > 0 else { return nil }

        let blockSize64 = UInt64(blockSize)
        let alignedOffset = offset - (offset % blockSize64)
        let payloadOffset64 = offset - alignedOffset
        let requestedLength64 = UInt64(length)
        let (requestedEnd, endOverflow) = offset.addingReportingOverflow(requestedLength64)
        guard !endOverflow else { return nil }

        let endRemainder = requestedEnd % blockSize64
        let alignmentPadding = endRemainder == 0 ? UInt64(0) : blockSize64 - endRemainder
        let (alignedEnd, alignedEndOverflow) = requestedEnd.addingReportingOverflow(alignmentPadding)
        guard !alignedEndOverflow else { return nil }

        let alignedLength64 = alignedEnd - alignedOffset
        guard
            payloadOffset64 <= UInt64(Int.max),
            alignedLength64 <= UInt64(Int.max)
        else {
            return nil
        }

        return RawDeviceReadPlan(
            requestedOffset: offset,
            requestedLength: length,
            blockSize: blockSize,
            alignedOffset: alignedOffset,
            alignedLength: Int(alignedLength64),
            payloadOffset: Int(payloadOffset64)
        )
    }

    func payloadRange(for bytesRead: Int) -> Range<Int>? {
        guard bytesRead > payloadOffset else { return nil }

        let upperBound = min(bytesRead, payloadOffset + requestedLength)
        guard upperBound > payloadOffset else { return nil }
        return payloadOffset ..< upperBound
    }
}
