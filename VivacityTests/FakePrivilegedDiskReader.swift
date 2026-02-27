import Foundation
@testable import Vivacity

#if DEBUG
final class FakePrivilegedDiskReader: PrivilegedDiskReading, @unchecked Sendable {
    var isSeekable: Bool = true
    var buffer: Data

    init(buffer: Data = Data()) {
        self.buffer = buffer
    }

    func start() throws {
        // No-op
    }

    func read(into destBuffer: UnsafeMutableRawPointer, offset: UInt64, length: Int) -> Int {
        let copyOffset = min(Int(offset), buffer.count)
        let copyLength = min(length, buffer.count - copyOffset)

        guard copyLength > 0 else { return 0 }

        buffer.withUnsafeBytes { rawBuffer in
            if let srcBase = rawBuffer.baseAddress {
                destBuffer.copyMemory(from: srcBase + copyOffset, byteCount: copyLength)
            }
        }

        return copyLength
    }

    func stop() {
        // No-op
    }
}
#endif
