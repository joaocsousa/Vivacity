import Foundation

final class PrivilegedHelperDelegate: NSObject, NSXPCListenerDelegate {
    static let machServiceName = "com.joao.Vivacity.PrivilegedHelper"

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedReaderXPCProtocol.self)
        newConnection.exportedObject = PrivilegedReaderService()
        newConnection.resume()
        return true
    }
}

final class PrivilegedReaderService: NSObject, PrivilegedReaderXPCProtocol {
    private let maxReadLength = 4 * 1024 * 1024

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func readBytes(
        devicePath: String,
        offset: UInt64,
        length: Int,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        guard isAllowedDevicePath(devicePath) else {
            reply(nil, "Device path not allowed")
            return
        }

        guard length > 0, length <= maxReadLength else {
            reply(nil, "Requested length is out of bounds")
            return
        }

        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            reply(nil, "open failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        var buffer = Data(count: length)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return pread(fd, base, length, off_t(offset))
        }

        guard bytesRead >= 0 else {
            reply(nil, "pread failed: \(String(cString: strerror(errno)))")
            return
        }

        if bytesRead == 0 {
            reply(Data(), nil)
            return
        }

        reply(buffer.prefix(bytesRead), nil)
    }

    private func isAllowedDevicePath(_ path: String) -> Bool {
        path.hasPrefix("/dev/disk") || path.hasPrefix("/dev/rdisk")
    }
}
