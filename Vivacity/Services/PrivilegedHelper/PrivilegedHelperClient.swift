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
            self?.logger.error("Privileged helper connection invalidated")
        }
        connection.interruptionHandler = { [weak self] in
            self?.logger.error("Privileged helper connection interrupted")
        }
        connection.resume()
        return connection
    }()

    deinit {
        connection.invalidate()
    }

    func prepareForPrivilegedAccess() {
        guard !didAttemptInstall else { return }
        didAttemptInstall = true

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
        let semaphore = DispatchSemaphore(value: 0)
        var available = false

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? PrivilegedReaderXPCProtocol else {
            return false
        }

        proxy.ping { ok in
            available = ok
            semaphore.signal()
        }

        return semaphore.wait(timeout: .now() + timeout) == .success && available
    }

    func read(devicePath: String, offset: UInt64, length: Int, timeout: TimeInterval = 2.0) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: String?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            responseError = error.localizedDescription
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
            throw PrivilegedHelperClientError.readFailed(responseError)
        }

        return responseData ?? Data()
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
