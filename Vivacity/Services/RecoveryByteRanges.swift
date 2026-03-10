import Foundation
import os

extension RecoverableFile {
    var recoveryRanges: [FragmentRange] {
        if let fragmentMap {
            let sanitized = fragmentMap.filter { $0.length > 0 }
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        guard sizeInBytes > 0 else { return [] }
        return [FragmentRange(start: offsetOnDisk, length: UInt64(sizeInBytes))]
    }

    func leadingRecoveryRanges(maxBytes: Int) -> [FragmentRange] {
        trimmedRecoveryRanges(maxBytes: maxBytes, fromStart: true)
    }

    func trailingRecoveryRanges(maxBytes: Int) -> [FragmentRange] {
        trimmedRecoveryRanges(maxBytes: maxBytes, fromStart: false)
    }

    private func trimmedRecoveryRanges(maxBytes: Int, fromStart: Bool) -> [FragmentRange] {
        guard maxBytes > 0 else { return [] }
        let limit = UInt64(maxBytes)
        let source = fromStart ? recoveryRanges : recoveryRanges.reversed()
        var remaining = limit
        var trimmed: [FragmentRange] = []

        for range in source where remaining > 0 {
            let take = min(range.length, remaining)
            guard take > 0 else { continue }
            let start = fromStart ? range.start : range.start + range.length - take
            trimmed.append(FragmentRange(start: start, length: take))
            remaining -= take
        }

        return fromStart ? trimmed : trimmed.reversed()
    }
}

enum RecoveryByteRanges {
    private static let logger = Logger(subsystem: "com.vivacity.app", category: "RecoveryByteRanges")

    static func copy(
        ranges: [FragmentRange],
        from reader: PrivilegedDiskReading,
        chunkSize: Int,
        onChunk: (Data) throws -> Void
    ) throws -> Int64 {
        guard chunkSize > 0 else { return 0 }
        var recoveredBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let rangeCopyStart = "Starting range copy ranges=\(rangeSummary(ranges)) chunkSize=\(chunkSize)"
        logger.debug("\(rangeCopyStart, privacy: .public)")

        for (index, range) in ranges.enumerated() {
            let rangeMessage =
                "Copying range \(index + 1)/\(ranges.count) start=\(range.start) length=\(range.length)"
            logger.debug("\(rangeMessage, privacy: .public)")
            var remainingBytes = range.length
            var readOffset = range.start

            while remainingBytes > 0 {
                let bytesToRead = min(UInt64(chunkSize), remainingBytes)
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    reader.read(
                        into: rawBuffer.baseAddress!,
                        offset: readOffset,
                        length: Int(bytesToRead)
                    )
                }

                guard bytesRead > 0 else {
                    let reason = reader.lastReadFailureDescription ??
                        (bytesRead == 0 ? "Read returned EOF" : "Read failed")
                    let rangeFailureMessage =
                        "Range copy failed offset=\(readOffset) requested=\(bytesToRead) " +
                        "rangeStart=\(range.start) rangeLength=\(range.length) " +
                        "bytesRecovered=\(recoveredBytes) reason=\(reason)"
                    logger.error("\(rangeFailureMessage, privacy: .public)")
                    throw RecoveryByteRangeError.readFailed(
                        offset: readOffset,
                        requestedBytes: Int(bytesToRead),
                        rangeStart: range.start,
                        rangeLength: range.length,
                        reason: reason
                    )
                }

                try onChunk(Data(buffer[..<bytesRead]))

                recoveredBytes += Int64(bytesRead)
                readOffset += UInt64(bytesRead)
                remainingBytes -= UInt64(bytesRead)
            }
        }

        logger.debug("Completed range copy recoveredBytes=\(recoveredBytes)")
        return recoveredBytes
    }

    static func readData(
        ranges: [FragmentRange],
        from reader: PrivilegedDiskReading,
        chunkSize: Int = 128 * 1024
    ) -> Data? {
        do {
            var data = Data()
            let expectedBytes = Int64(ranges.reduce(UInt64(0)) { $0 + $1.length })
            let recoveredBytes = try copy(ranges: ranges, from: reader, chunkSize: chunkSize) { chunk in
                data.append(chunk)
            }
            guard recoveredBytes == expectedBytes, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func rangeSummary(_ ranges: [FragmentRange], limit: Int = 4) -> String {
        let totalBytes = ranges.reduce(UInt64(0)) { $0 + $1.length }
        let listedRanges = ranges.prefix(limit).enumerated().map { index, range in
            "#\(index + 1){start=\(range.start),len=\(range.length)}"
        }
        let suffix = ranges.count > limit ? ", ..." : ""
        return "count=\(ranges.count) totalBytes=\(totalBytes) [\(listedRanges.joined(separator: ", "))\(suffix)]"
    }
}

private enum RecoveryByteRangeError: LocalizedError {
    case readFailed(offset: UInt64, requestedBytes: Int, rangeStart: UInt64, rangeLength: UInt64, reason: String)

    var errorDescription: String? {
        switch self {
        case let .readFailed(offset, requestedBytes, rangeStart, rangeLength, reason):
            "Read failed at offset \(offset) while requesting \(requestedBytes) bytes " +
                "inside range start \(rangeStart) length \(rangeLength). Reason: \(reason)."
        }
    }
}
