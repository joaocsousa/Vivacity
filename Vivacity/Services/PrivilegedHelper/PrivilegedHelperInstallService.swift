import Foundation
import os
import Security
import ServiceManagement

enum PrivilegedHelperStatus: String, Sendable, Equatable {
    case installed
    case notInstalled
    case updateRequired
}

protocol PrivilegedHelperInstalling {
    func installIfNeeded() throws
}

protocol PrivilegedHelperUninstalling {
    func uninstallIfInstalled() throws
}

protocol PrivilegedHelperStatusProviding {
    func currentStatus() -> PrivilegedHelperStatus
}

protocol PrivilegedHelperManaging:
    PrivilegedHelperInstalling,
    PrivilegedHelperUninstalling,
    PrivilegedHelperStatusProviding
{}

final class PrivilegedHelperInstallService {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "PrivilegedHelper")
    private let helperLabel: String
    private let fileManager: FileManager
    private let installedHelperRoot: String
    private let installedLaunchDaemonRoot: String
    private let embeddedHelperRoot: String?
    private let helperReachabilityProbe: (() -> Bool)?
    private let blessHelperAction: (() throws -> Void)?
    private let removeHelperAction: (() throws -> Void)?

    init(
        helperLabel: String,
        fileManager: FileManager = .default,
        installedHelperRoot: String = "/Library/PrivilegedHelperTools",
        installedLaunchDaemonRoot: String = "/Library/LaunchDaemons",
        embeddedHelperRoot: String? = nil,
        helperReachabilityProbe: (() -> Bool)? = nil,
        blessHelperAction: (() throws -> Void)? = nil,
        removeHelperAction: (() throws -> Void)? = nil
    ) {
        self.helperLabel = helperLabel
        self.fileManager = fileManager
        self.installedHelperRoot = installedHelperRoot
        self.installedLaunchDaemonRoot = installedLaunchDaemonRoot
        self.embeddedHelperRoot = embeddedHelperRoot
        self.helperReachabilityProbe = helperReachabilityProbe
        self.blessHelperAction = blessHelperAction
        self.removeHelperAction = removeHelperAction
    }

    func installIfNeeded() throws {
        let statusBefore = currentStatus()
        let requestMessage =
            "Helper install requested statusBefore=\(statusBefore.rawValue) " +
            "helperLabel=\(helperLabel)"
        logger.info("\(requestMessage, privacy: .public)")
        logDiagnosticLines(context: "install-preflight", asError: false)

        if statusBefore == .installed {
            logger.info("Helper install skipped because helper is already installed")
            return
        }

        do {
            if let blessHelperAction {
                try blessHelperAction()
            } else {
                try blessHelper()
            }
        } catch {
            let errorDescription = describe(error: error)
            logger.error("Helper install failed during bless: \(errorDescription, privacy: .public)")
            logDiagnosticLines(context: "install-failed", asError: true)
            throw error
        }

        let statusAfter = currentStatus()
        logger.info("Helper install finished statusAfter=\(statusAfter.rawValue, privacy: .public)")
        logDiagnosticLines(
            context: "install-postflight",
            asError: statusAfter != .installed
        )
    }

    func uninstallIfInstalled() throws {
        let before = installedArtifactSnapshot()
        guard before.helperExists || before.launchDaemonExists else {
            logger.info("Helper uninstall skipped: helper artifacts are absent")
            return
        }

        let pingBefore = isHelperReachable(timeout: 0.35)
        let launchctlBefore = launchctlServiceStateSummary()
        let beforeMessage =
            "Helper uninstall requested helperExists=\(before.helperExists) " +
            "launchDaemonExists=\(before.launchDaemonExists) ping=\(pingBefore) " +
            "launchctl=\(launchctlBefore)"
        logger.info("\(beforeMessage, privacy: .public)")

        if let removeHelperAction {
            try removeHelperAction()
        } else {
            try removeHelper()
        }

        let after = installedArtifactSnapshot()
        let pingAfter = isHelperReachable(timeout: 0.35)
        let launchctlAfter = launchctlServiceStateSummary()
        let afterMessage =
            "Helper uninstall finished helperExists=\(after.helperExists) " +
            "launchDaemonExists=\(after.launchDaemonExists) ping=\(pingAfter) " +
            "launchctl=\(launchctlAfter)"
        logger.info("\(afterMessage, privacy: .public)")
    }

    func currentStatus() -> PrivilegedHelperStatus {
        let artifacts = installedArtifactSnapshot()
        guard artifacts.helperExists, artifacts.launchDaemonExists else {
            if artifacts.helperExists || artifacts.launchDaemonExists {
                let launchctlState = launchctlServiceStateSummary()
                let partialMessage =
                    "Helper status: partial install helperExists=\(artifacts.helperExists) " +
                    "launchDaemonExists=\(artifacts.launchDaemonExists) " +
                    "launchctl=\(launchctlState)"
                logger.warning("\(partialMessage, privacy: .public)")
                logDiagnosticLines(context: "status-partial", asError: true)
            } else {
                let missingMessage =
                    "Helper status: not installed helperPath=\(artifacts.helperPath) " +
                    "launchDaemonPath=\(artifacts.launchDaemonPath)"
                logger.info("\(missingMessage, privacy: .public)")
            }
            return .notInstalled
        }

        guard isHelperReachable(timeout: 0.35) else {
            let launchctlState = launchctlServiceStateSummary()
            let unreachableMessage =
                "Helper status: artifacts exist but helper service is unreachable " +
                "launchctl=\(launchctlState)"
            logger.warning("\(unreachableMessage, privacy: .public)")
            logDiagnosticLines(context: "status-unreachable", asError: true)
            return .notInstalled
        }

        guard let embeddedPath = embeddedHelperPath(),
              fileManager.fileExists(atPath: embeddedPath)
        else {
            // If we cannot inspect the embedded helper, preserve existing behavior and
            // treat the installed helper as valid.
            logger.info("Helper status: installed (embedded helper unavailable)")
            return .installed
        }

        do {
            let installedVersion = try helperVersion(atPath: artifacts.helperPath)
            let embeddedVersion = try helperVersion(atPath: embeddedPath)
            let versionComparison = PrivilegedHelperBinaryComparator.compare(
                installedVersion: installedVersion,
                embeddedVersion: embeddedVersion
            )
            let binariesDiffer: Bool = if versionComparison != .orderedAscending {
                try PrivilegedHelperBinaryComparator.binariesDiffer(
                    installedPath: artifacts.helperPath,
                    embeddedPath: embeddedPath,
                    fileManager: fileManager
                )
            } else {
                false
            }
            let status: PrivilegedHelperStatus = if versionComparison == .orderedAscending || binariesDiffer {
                .updateRequired
            } else {
                .installed
            }
            let versionLogMessage =
                "Helper version status=\(status.rawValue) " +
                "installed=\(installedVersion.description) " +
                "embedded=\(embeddedVersion.description) " +
                "binariesDiffer=\(binariesDiffer)"
            logger.info("\(versionLogMessage, privacy: .public)")
            return status
        } catch {
            // If we cannot determine versions, preserve existing behavior and
            // treat the installed helper as valid.
            let errorMessage =
                "Helper status version/binary comparison failed: \(error.localizedDescription). " +
                "Falling back to installed."
            logger.error("\(errorMessage, privacy: .public)")
            return .installed
        }
    }

    private func embeddedHelperPath() -> String? {
        if let embeddedHelperRoot {
            return helperPath(root: embeddedHelperRoot)
        }

        let bundledHelperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent(helperLabel, isDirectory: false)
        return bundledHelperURL.path
    }

    private func helperPath(root: String) -> String {
        (root as NSString).appendingPathComponent(helperLabel)
    }

    private func launchDaemonPath(root: String) -> String {
        (root as NSString).appendingPathComponent("\(helperLabel).plist")
    }

    private func installedArtifactSnapshot() -> HelperArtifactSnapshot {
        let helperPath = helperPath(root: installedHelperRoot)
        let launchDaemonPath = launchDaemonPath(root: installedLaunchDaemonRoot)
        return HelperArtifactSnapshot(
            helperPath: helperPath,
            launchDaemonPath: launchDaemonPath,
            helperExists: fileManager.fileExists(atPath: helperPath),
            launchDaemonExists: fileManager.fileExists(atPath: launchDaemonPath)
        )
    }

    private func isHelperReachable(timeout: TimeInterval) -> Bool {
        if let helperReachabilityProbe {
            return helperReachabilityProbe()
        }
        return helperRespondsToPing(timeout: timeout)
    }

    private func helperRespondsToPing(timeout: TimeInterval) -> Bool {
        let helperLabel = helperLabel
        let pingStartMessage =
            "Helper ping started machService=\(helperLabel) timeout=\(timeout)s"
        logger.info("\(pingStartMessage, privacy: .public)")
        let connection = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedReaderXPCProtocol.self)
        connection.invalidationHandler = { [logger, helperLabel] in
            logger.error(
                "Helper ping connection invalidated machService=\(helperLabel, privacy: .public)"
            )
        }
        connection.interruptionHandler = { [logger, helperLabel] in
            logger.error(
                "Helper ping connection interrupted machService=\(helperLabel, privacy: .public)"
            )
        }
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        var proxyErrorDescription: String?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [logger, helperLabel] error in
            let nsError = error as NSError
            let message =
                "\(nsError.domain)(\(nsError.code)): " +
                "\(nsError.localizedDescription)"
            proxyErrorDescription = message
            let proxyMessage =
                "Helper ping proxy error machService=\(helperLabel) error=\(message)"
            logger.error("\(proxyMessage, privacy: .public)")
            semaphore.signal()
        }) as? PrivilegedReaderXPCProtocol
        else {
            let proxyCreationMessage =
                "Helper ping failed to create privileged proxy machService=\(helperLabel)"
            logger.error("\(proxyCreationMessage, privacy: .public)")
            return false
        }

        proxy.ping { [logger, helperLabel] ok in
            reachable = ok
            if ok {
                let successMessage = "Helper ping reply succeeded machService=\(helperLabel)"
                logger.info("\(successMessage, privacy: .public)")
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            let timeoutMessage =
                "Helper ping timed out machService=\(helperLabel) timeout=\(timeout)s"
            logger.error("\(timeoutMessage, privacy: .public)")
            return false
        }

        if reachable {
            logger.info("Helper ping succeeded machService=\(helperLabel, privacy: .public)")
        } else {
            let proxySuffix = proxyErrorDescription.map { " proxyError=\($0)" } ?? ""
            let failureMessage =
                "Helper ping failed machService=\(helperLabel)\(proxySuffix)"
            logger.error("\(failureMessage, privacy: .public)")
        }

        return reachable
    }

    private func launchctlServiceStateSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(helperLabel)"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let firstLine = output.split(separator: "\n", maxSplits: 1)
                .first
                .map(String.init) ?? "no-output"
            if process.terminationStatus == 0 {
                return "loaded(\(firstLine))"
            }
            return "unavailable(exit=\(process.terminationStatus), line=\(firstLine))"
        } catch {
            return "error(\(error.localizedDescription))"
        }
    }

    private func helperVersion(atPath path: String) throws -> HelperVersion {
        let plist = try helperInfoPlist(atPath: path)
        return HelperVersion(
            shortVersion: plist["CFBundleShortVersionString"] as? String,
            bundleVersion: plist["CFBundleVersion"] as? String
        )
    }

    private func helperInfoPlist(atPath path: String) throws -> [String: Any] {
        let contents = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)

        guard let startRange = contents.range(of: startMarker),
              let endRange = contents.range(of: endMarker, in: startRange.lowerBound ..< contents.endIndex)
        else {
            throw PrivilegedHelperInstallError.versionReadFailed("Missing plist section in helper binary")
        }

        let plistData = contents[startRange.lowerBound ..< endRange.upperBound]
        let plistObject = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        )
        guard let plist = plistObject as? [String: Any] else {
            throw PrivilegedHelperInstallError.versionReadFailed("Invalid helper plist structure")
        }

        return plist
    }

    private func blessHelper() throws {
        let helperLabel = helperLabel
        let blessStartMessage = "SMJobBless starting helperLabel=\(helperLabel)"
        logger.info("\(blessStartMessage, privacy: .public)")
        logDiagnosticLines(context: "smjobbless-before", asError: false)

        var authRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        var status = AuthorizationCreate(nil, nil, flags, &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
            let authCreateMessage =
                "AuthorizationCreate failed status=\(authorizationStatusDescription(status))"
            logger.error("\(authCreateMessage, privacy: .public)")
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }
        defer { AuthorizationFree(authRef, []) }

        status = kSMRightBlessPrivilegedHelper.withCString { rightName in
            var authItem = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &authItem) { itemPointer in
                var authRights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(authRef, &authRights, nil, flags, nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            let authCopyMessage =
                "AuthorizationCopyRights failed right=\(kSMRightBlessPrivilegedHelper) " +
                "status=\(authorizationStatusDescription(status))"
            logger.error("\(authCopyMessage, privacy: .public)")
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }
        logger.info("AuthorizationCopyRights succeeded right=\(kSMRightBlessPrivilegedHelper, privacy: .public)")

        var cfError: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, &cfError) else {
            let reason: String = if let error = cfError?.takeRetainedValue() {
                describe(cfError: error)
            } else {
                "unknown"
            }
            let blessFailureMessage =
                "SMJobBless failed helperLabel=\(helperLabel) reason=\(reason)"
            logger.error("\(blessFailureMessage, privacy: .public)")
            logDiagnosticLines(context: "smjobbless-failure", asError: true)
            throw PrivilegedHelperInstallError.blessFailed(reason)
        }

        let blessSuccessMessage = "SMJobBless succeeded helperLabel=\(helperLabel)"
        logger.info("\(blessSuccessMessage, privacy: .public)")
        logDiagnosticLines(context: "smjobbless-after", asError: false)
    }

    private func removeHelper() throws {
        let helperLabel = helperLabel
        let authRef = try createAuthorization(rightName: kSMRightModifySystemDaemons)
        defer { AuthorizationFree(authRef, []) }

        var cfError: Unmanaged<CFError>?
        guard SMJobRemove(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, true, &cfError) else {
            let reason: String = if let error = cfError?.takeRetainedValue() {
                describe(cfError: error)
            } else {
                "unknown"
            }
            let removeFailureMessage =
                "SMJobRemove failed helperLabel=\(helperLabel) reason=\(reason)"
            logger.error("\(removeFailureMessage, privacy: .public)")
            logDiagnosticLines(context: "smjobremove-failure", asError: true)
            throw PrivilegedHelperInstallError.removeFailed(reason)
        }
    }

    private func createAuthorization(rightName: UnsafePointer<CChar>) throws -> AuthorizationRef {
        var authRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        var status = AuthorizationCreate(nil, nil, flags, &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }

        var authItem = AuthorizationItem(
            name: rightName,
            valueLength: 0,
            value: nil,
            flags: 0
        )
        status = withUnsafeMutablePointer(to: &authItem) { itemPointer in
            var authRights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(authRef, &authRights, nil, flags, nil)
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authRef, [])
            let authCopyMessage =
                "AuthorizationCopyRights failed right=\(String(cString: rightName)) " +
                "status=\(authorizationStatusDescription(status))"
            logger.error("\(authCopyMessage, privacy: .public)")
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }

        return authRef
    }
}

extension PrivilegedHelperInstallService {
    private func logDiagnosticLines(context: String, asError: Bool) {
        for line in diagnosticLines(context: context) {
            if asError {
                logger.error("\(line, privacy: .public)")
            } else {
                logger.info("\(line, privacy: .public)")
            }
        }
    }

    private func diagnosticLines(context: String) -> [String] {
        let artifacts = installedArtifactSnapshot()
        let diagnosticContext = PrivilegedHelperDiagnosticContext(
            context: context,
            helperLabel: helperLabel,
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? "nil",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "nil",
            embeddedPath: embeddedHelperPath(),
            installedHelperPath: artifacts.helperPath,
            launchDaemonPath: artifacts.launchDaemonPath,
            launchDaemonExists: artifacts.launchDaemonExists,
            fileManager: fileManager
        )

        return PrivilegedHelperDiagnostics.diagnosticLines(context: diagnosticContext) { path in
            do {
                return try helperVersion(atPath: path).description
            } catch {
                return "error=\(describe(error: error))"
            }
        }
    }

    private func authorizationStatusDescription(_ status: OSStatus) -> String {
        PrivilegedHelperDiagnostics.authorizationStatusDescription(status)
    }

    private func describe(cfError: CFError) -> String {
        PrivilegedHelperDiagnostics.describe(error: cfError as Error)
    }

    private func describe(error: Error) -> String {
        PrivilegedHelperDiagnostics.describe(error: error)
    }
}

extension PrivilegedHelperInstallService: PrivilegedHelperInstalling {}
extension PrivilegedHelperInstallService: PrivilegedHelperUninstalling {}
extension PrivilegedHelperInstallService: PrivilegedHelperStatusProviding {}
extension PrivilegedHelperInstallService: PrivilegedHelperManaging {}

enum PrivilegedHelperInstallError: LocalizedError {
    case authorizationFailed(OSStatus)
    case blessFailed(String)
    case removeFailed(String)
    case versionReadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Privileged helper authorization failed (status: \(status), message: \(message))"
        case let .blessFailed(reason):
            return "SMJobBless failed: \(reason)"
        case let .removeFailed(reason):
            return "SMJobRemove failed: \(reason)"
        case let .versionReadFailed(reason):
            return "Failed to read helper version: \(reason)"
        }
    }
}

struct HelperVersion {
    let shortVersion: String?
    let bundleVersion: String?

    var description: String {
        let shortComponent = shortVersion ?? "nil"
        let bundleComponent = bundleVersion ?? "nil"
        return "short=\(shortComponent),bundle=\(bundleComponent)"
    }
}

private struct HelperArtifactSnapshot {
    let helperPath: String
    let launchDaemonPath: String
    let helperExists: Bool
    let launchDaemonExists: Bool
}
