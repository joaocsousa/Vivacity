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
        if currentStatus() == .installed {
            return
        }
        if let blessHelperAction {
            try blessHelperAction()
        } else {
            try blessHelper()
        }
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
            let status: PrivilegedHelperStatus = compare(
                installedVersion: installedVersion,
                embeddedVersion: embeddedVersion
            ) == .orderedAscending ? .updateRequired : .installed
            let versionLogMessage =
                "Helper version status=\(status.rawValue) " +
                "installed=\(installedVersion.description) " +
                "embedded=\(embeddedVersion.description)"
            logger.info("\(versionLogMessage, privacy: .public)")
            return status
        } catch {
            // If we cannot determine versions, preserve existing behavior and
            // treat the installed helper as valid.
            let errorMessage =
                "Helper status version parsing failed: \(error.localizedDescription). " +
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
        let connection = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedReaderXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? PrivilegedReaderXPCProtocol
        else {
            return false
        }

        proxy.ping { ok in
            reachable = ok
            semaphore.signal()
        }

        return semaphore.wait(timeout: .now() + timeout) == .success && reachable
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

    private func compare(installedVersion: HelperVersion, embeddedVersion: HelperVersion) -> ComparisonResult {
        if let installedBundle = installedVersion.bundleVersion,
           let embeddedBundle = embeddedVersion.bundleVersion,
           !installedBundle.isEmpty,
           !embeddedBundle.isEmpty
        {
            return installedBundle.compare(embeddedBundle, options: .numeric)
        }

        if let installedShort = installedVersion.shortVersion,
           let embeddedShort = embeddedVersion.shortVersion,
           !installedShort.isEmpty,
           !embeddedShort.isEmpty
        {
            return installedShort.compare(embeddedShort, options: .numeric)
        }

        return .orderedSame
    }

    private func blessHelper() throws {
        var authRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        var status = AuthorizationCreate(nil, nil, flags, &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
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
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }

        var cfError: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, &cfError) else {
            let reason: String
            if let error = cfError?.takeRetainedValue() {
                let domain = CFErrorGetDomain(error) as String
                let code = CFErrorGetCode(error)
                let description = CFErrorCopyDescription(error) as String? ?? "unknown"
                reason = "\(description) [domain=\(domain) code=\(code)]"
            } else {
                reason = "unknown"
            }
            throw PrivilegedHelperInstallError.blessFailed(reason)
        }
    }

    private func removeHelper() throws {
        let authRef = try createAuthorization(rightName: kSMRightModifySystemDaemons)
        defer { AuthorizationFree(authRef, []) }

        var cfError: Unmanaged<CFError>?
        guard SMJobRemove(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, true, &cfError) else {
            let reason: String
            if let error = cfError?.takeRetainedValue() {
                let domain = CFErrorGetDomain(error) as String
                let code = CFErrorGetCode(error)
                let description = CFErrorCopyDescription(error) as String? ?? "unknown"
                reason = "\(description) [domain=\(domain) code=\(code)]"
            } else {
                reason = "unknown"
            }
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
            throw PrivilegedHelperInstallError.authorizationFailed(status)
        }

        return authRef
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
            "Privileged helper authorization failed (status: \(status))"
        case let .blessFailed(reason):
            "SMJobBless failed: \(reason)"
        case let .removeFailed(reason):
            "SMJobRemove failed: \(reason)"
        case let .versionReadFailed(reason):
            "Failed to read helper version: \(reason)"
        }
    }
}

private struct HelperVersion {
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
