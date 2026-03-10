import Foundation
import os

final class PrivilegedHelperClient {
    static let defaultServiceName = "com.joao.Vivacity.PrivilegedHelper"
    private let serviceName: String
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedHelper")
    private let installService: any PrivilegedHelperInstalling
    private var didAttemptInstall = false
    private(set) var lastInstallErrorDescription: String?

    init(
        serviceName: String = PrivilegedHelperClient.defaultServiceName,
        installService: (any PrivilegedHelperInstalling)? = nil
    ) {
        self.serviceName = serviceName
        self.installService = installService ?? PrivilegedHelperInstallService(helperLabel: serviceName)
    }

    private lazy var connection: NSXPCConnection = {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedReaderXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            self?.logger.error(
                "Privileged helper connection invalidated service=\(self?.serviceName ?? "nil", privacy: .public)"
            )
        }
        connection.interruptionHandler = { [weak self] in
            self?.logger.error(
                "Privileged helper connection interrupted service=\(self?.serviceName ?? "nil", privacy: .public)"
            )
        }
        connection.resume()
        return connection
    }()

    deinit {
        connection.invalidate()
    }

    func prepareForPrivilegedAccess() {
        let serviceName = serviceName
        guard !didAttemptInstall else { return }
        didAttemptInstall = true
        logger.info("Privileged helper install attempt starting service=\(serviceName, privacy: .public)")

        do {
            try installService.installIfNeeded()
            lastInstallErrorDescription = nil
            logger.info("Privileged helper installed/available via SMJobBless")
        } catch {
            lastInstallErrorDescription = error.localizedDescription
            logger.error("Privileged helper install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isAvailable(timeout: TimeInterval = 1.0) -> Bool {
        let serviceName = serviceName
        let semaphore = DispatchSemaphore(value: 0)
        var available = false
        var proxyErrorDescription: String?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [logger, serviceName] error in
            let message = Self.describe(error: error)
            proxyErrorDescription = message
            let proxyErrorMessage =
                "Privileged helper availability ping failed service=\(serviceName) " +
                "error=\(message)"
            logger.error("\(proxyErrorMessage, privacy: .public)")
            semaphore.signal()
        }) as? PrivilegedReaderXPCProtocol else {
            let proxyCreationMessage =
                "Privileged helper availability ping failed to create proxy service=\(serviceName)"
            logger.error("\(proxyCreationMessage, privacy: .public)")
            return false
        }

        proxy.ping { ok in
            available = ok
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            let timeoutMessage =
                "Privileged helper availability ping timed out service=\(serviceName) " +
                "timeout=\(timeout)s"
            logger.error("\(timeoutMessage, privacy: .public)")
            return false
        }

        if available {
            logger.info("Privileged helper availability ping succeeded service=\(serviceName, privacy: .public)")
        } else {
            let proxySuffix = proxyErrorDescription.map { " proxyError=\($0)" } ?? ""
            let unavailableMessage =
                "Privileged helper availability ping returned unavailable " +
                "service=\(serviceName)\(proxySuffix)"
            logger.error("\(unavailableMessage, privacy: .public)")
        }

        return available
    }

    func read(devicePath: String, offset: UInt64, length: Int, timeout: TimeInterval = 2.0) throws -> Data {
        let serviceName = serviceName
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: String?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [logger, serviceName] error in
            let message = Self.describe(error: error)
            responseError = message
            let proxyErrorMessage =
                "Privileged helper read proxy error service=\(serviceName) error=\(message)"
            logger.error("\(proxyErrorMessage, privacy: .public)")
            semaphore.signal()
        }) as? PrivilegedReaderXPCProtocol else {
            throw PrivilegedHelperClientError.unavailable("Privileged helper proxy unavailable")
        }

        proxy.readBytes(devicePath: devicePath, offset: offset, length: length) { data, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw PrivilegedHelperClientError.timeout
        }

        if let responseError {
            let readFailureMessage =
                "Privileged helper read failed service=\(serviceName) error=\(responseError)"
            logger.error("\(readFailureMessage, privacy: .public)")
            throw PrivilegedHelperClientError.readFailed(responseError)
        }

        return responseData ?? Data()
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        var components = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)",
        ]

        if let failureReason = nsError.localizedFailureReason {
            components.append("failureReason=\(failureReason)")
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion {
            components.append("recoverySuggestion=\(recoverySuggestion)")
        }
        if !nsError.userInfo.isEmpty {
            let userInfo = nsError.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            components.append("userInfo={\(userInfo)}")
        }

        return components.joined(separator: " ")
    }
}

enum PrivilegedHelperClientError: LocalizedError {
    case unavailable(String)
    case timeout
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            "Privileged helper unavailable: \(reason)"
        case .timeout:
            "Privileged helper read timed out"
        case let .readFailed(reason):
            "Privileged helper read failed: \(reason)"
        }
    }
}
