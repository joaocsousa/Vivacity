import Foundation
import os

final class PrivilegedHelperDelegate: NSObject, NSXPCListenerDelegate {
    static let machServiceName = "com.joao.Vivacity.PrivilegedHelper"
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedHelperService")

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        let acceptMessage =
            "Accepted helper XPC connection machService=\(Self.machServiceName) pid=\(pid)"
        logger.info("\(acceptMessage, privacy: .public)")
        newConnection.interruptionHandler = { [logger] in
            logger.error("Helper XPC connection interrupted")
        }
        newConnection.invalidationHandler = { [logger] in
            logger.error("Helper XPC connection invalidated")
        }
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedReaderXPCProtocol.self)
        newConnection.exportedObject = PrivilegedReaderService()
        newConnection.resume()
        return true
    }
}

final class PrivilegedReaderService: NSObject, PrivilegedReaderXPCProtocol {
    private let maxReadLength = 4 * 1024 * 1024
    private let defaultBlockSize = 512
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedHelperService")
    private var requestCount = 0
    private var successfulReadCount = 0
    private var deviceBlockSizeCache: [String: Int] = [:]

    func ping(withReply reply: @escaping (Bool) -> Void) {
        logger.debug("Helper ping received")
        reply(true)
    }

    func readBytes(
        devicePath: String,
        offset: UInt64,
        length: Int,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        requestCount += 1
        let requestID = requestCount
        if shouldLogRead(count: requestID) {
            let requestMessage =
                "Helper read request id=\(requestID) device=\(devicePath) offset=\(offset) " +
                "length=\(length) user=\(Self.userContextDescription())"
            logger.debug("\(requestMessage, privacy: .public)")
        }

        guard isAllowedDevicePath(devicePath) else {
            let rejectionMessage =
                "Helper read rejected id=\(requestID) device=\(devicePath) reason=device path not allowed"
            logger.error("\(rejectionMessage, privacy: .public)")
            reply(nil, "Device path not allowed: \(devicePath)")
            return
        }

        guard length > 0, length <= maxReadLength else {
            let boundsMessage =
                "Helper read rejected id=\(requestID) device=\(devicePath) " +
                "length=\(length) maxLength=\(maxReadLength) reason=out of bounds"
            logger.error("\(boundsMessage, privacy: .public)")
            reply(nil, "Requested length is out of bounds: \(length)")
            return
        }

        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            let errorDescription = Self.describeErrno(errno)
            let failureMessage =
                "Helper open failed id=\(requestID) device=\(devicePath) error=\(errorDescription) " +
                "user=\(Self.userContextDescription())"
            logger.error("\(failureMessage, privacy: .public)")
            reply(nil, "open failed: \(errorDescription)")
            return
        }
        defer { close(fd) }

        let blockSize = deviceBlockSize(for: devicePath, requestID: requestID)
        guard let readPlan = RawDeviceReadPlan.make(offset: offset, length: length, blockSize: blockSize) else {
            let invalidPlanMessage =
                "Helper read rejected id=\(requestID) device=\(devicePath) offset=\(offset) " +
                "length=\(length) blockSize=\(blockSize) reason=invalid alignment plan"
            logger.error("\(invalidPlanMessage, privacy: .public)")
            reply(nil, "Invalid raw read alignment plan for offset=\(offset) length=\(length)")
            return
        }

        if readPlan.requiresBounceBuffer {
            let bounceMessage =
                "Helper aligned raw read id=\(requestID) device=\(devicePath) " +
                "requestedOffset=\(offset) requestedLength=\(length) " +
                "alignedOffset=\(readPlan.alignedOffset) alignedLength=\(readPlan.alignedLength) " +
                "blockSize=\(blockSize)"
            logger.debug("\(bounceMessage, privacy: .public)")
        }

        var buffer = Data(count: readPlan.alignedLength)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return pread(fd, base, readPlan.alignedLength, off_t(readPlan.alignedOffset))
        }

        guard bytesRead >= 0 else {
            let errorDescription = Self.describeErrno(errno)
            let failureMessage =
                "Helper pread failed id=\(requestID) device=\(devicePath) " +
                "requestedOffset=\(offset) requestedLength=\(length) " +
                "alignedOffset=\(readPlan.alignedOffset) alignedLength=\(readPlan.alignedLength) " +
                "blockSize=\(blockSize) error=\(errorDescription)"
            logger.error("\(failureMessage, privacy: .public)")
            reply(nil, "pread failed: \(errorDescription)")
            return
        }

        guard let payloadRange = readPlan.payloadRange(for: bytesRead) else {
            let eofMessage =
                "Helper read reached EOF id=\(requestID) device=\(devicePath) " +
                "requestedOffset=\(offset) requestedLength=\(length) " +
                "alignedOffset=\(readPlan.alignedOffset) alignedLength=\(readPlan.alignedLength) " +
                "bytesRead=\(bytesRead)"
            logger.error("\(eofMessage, privacy: .public)")
            reply(Data(), nil)
            return
        }

        let payload = buffer.subdata(in: payloadRange)
        successfulReadCount += 1
        if shouldLogRead(count: successfulReadCount) {
            let successMessage =
                "Helper read succeeded id=\(requestID) device=\(devicePath) " +
                "requestedOffset=\(offset) requestedLength=\(length) " +
                "alignedOffset=\(readPlan.alignedOffset) alignedLength=\(readPlan.alignedLength) " +
                "payloadBytes=\(payload.count) rawBytesRead=\(bytesRead) successCount=\(successfulReadCount)"
            logger.debug("\(successMessage, privacy: .public)")
        }
        reply(payload, nil)
    }

    private func isAllowedDevicePath(_ path: String) -> Bool {
        path.hasPrefix("/dev/disk") || path.hasPrefix("/dev/rdisk")
    }

    private func shouldLogRead(count: Int) -> Bool {
        count <= 5 || count.isMultiple(of: 128)
    }

    private func deviceBlockSize(for devicePath: String, requestID: Int) -> Int {
        if let cachedBlockSize = deviceBlockSizeCache[devicePath] {
            return cachedBlockSize
        }

        let lookedUpBlockSize = Self.lookupDeviceBlockSize(for: devicePath)
        let resolvedBlockSize = lookedUpBlockSize ?? defaultBlockSize
        deviceBlockSizeCache[devicePath] = resolvedBlockSize
        let source = lookedUpBlockSize == nil ? "default" : "diskutil"
        let blockSizeMessage =
            "Helper resolved device block size id=\(requestID) device=\(devicePath) " +
            "blockSize=\(resolvedBlockSize) source=\(source)"
        logger.info("\(blockSizeMessage, privacy: .public)")
        return resolvedBlockSize
    }

    private static func lookupDeviceBlockSize(for devicePath: String) -> Int? {
        let diskutilPath = normalizedDiskutilDevicePath(for: devicePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", diskutilPath]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let plistData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        if let blockSize = dictionary["DeviceBlockSize"] as? Int, blockSize > 0 {
            return blockSize
        }
        if let blockSize = dictionary["DeviceBlockSize"] as? NSNumber, blockSize.intValue > 0 {
            return blockSize.intValue
        }
        return nil
    }

    private static func normalizedDiskutilDevicePath(for devicePath: String) -> String {
        guard devicePath.hasPrefix("/dev/rdisk") else { return devicePath }
        return devicePath.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
    }

    private static func describeErrno(_ err: Int32) -> String {
        "errno=\(err) message=\(String(cString: strerror(err)))"
    }

    private static func userContextDescription() -> String {
        "uid=\(getuid()) euid=\(geteuid()) gid=\(getgid()) egid=\(getegid())"
    }
}
