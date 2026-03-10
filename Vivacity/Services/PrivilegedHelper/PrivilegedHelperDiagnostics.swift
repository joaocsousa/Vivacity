import Foundation
import Security

enum PrivilegedHelperDiagnostics {
    static func diagnosticLines(
        context: PrivilegedHelperDiagnosticContext,
        versionSummary: (String) -> String
    ) -> [String] {
        let launchctlSummary = commandSummary(
            executablePath: "/bin/launchctl",
            arguments: ["print", "system/\(context.helperLabel)"]
        )
        let appCodeSign = codesignSummary(path: context.bundlePath, fileManager: context.fileManager)
        let installedHelper = helperBinarySummary(
            path: context.installedHelperPath,
            fileManager: context.fileManager,
            versionSummary: versionSummary
        )
        let launchDaemonFile = fileSummary(
            path: context.launchDaemonPath,
            fileManager: context.fileManager
        )
        let embeddedHelper = context.embeddedPath.map {
            helperBinarySummary(
                path: $0,
                fileManager: context.fileManager,
                versionSummary: versionSummary
            )
        }
        let launchDaemonPlist = context.launchDaemonExists
            ? launchDaemonPlistSummary(path: context.launchDaemonPath)
            : nil

        var lines = [
            "Helper diagnostics [\(context.context)] " +
                "bundlePath=\(context.bundlePath) executablePath=\(context.executablePath) " +
                "bundleIdentifier=\(context.bundleIdentifier) helperLabel=\(context.helperLabel)",
            "Helper diagnostics [\(context.context)] appCodeSign=\(appCodeSign)",
            "Helper diagnostics [\(context.context)] installedHelper=\(installedHelper)",
            "Helper diagnostics [\(context.context)] launchDaemonFile=\(launchDaemonFile)",
            "Helper diagnostics [\(context.context)] launchctl=\(launchctlSummary)",
        ]

        if let embeddedHelper {
            lines.append("Helper diagnostics [\(context.context)] embeddedHelper=\(embeddedHelper)")
        } else {
            lines.append("Helper diagnostics [\(context.context)] embeddedHelper=unresolved")
        }

        if let launchDaemonPlist {
            lines.append(
                "Helper diagnostics [\(context.context)] launchDaemonPlist=\(launchDaemonPlist)"
            )
        }

        return lines
    }

    static func authorizationStatusDescription(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(status) (\(message))"
    }

    static func describe(error: Error) -> String {
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

    private static func helperBinarySummary(
        path: String,
        fileManager: FileManager,
        versionSummary: (String) -> String
    ) -> String {
        let base = fileSummary(path: path, fileManager: fileManager)
        guard fileManager.fileExists(atPath: path) else {
            return base
        }

        return base +
            " version=\(versionSummary(path)) " +
            "codesign=\(codesignSummary(path: path, fileManager: fileManager))"
    }

    private static func fileSummary(path: String, fileManager: FileManager) -> String {
        guard fileManager.fileExists(atPath: path) else {
            return "path=\(path) exists=false"
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? "nil"
            let permissionsValue = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let permissions = permissionsValue.map { String($0, radix: 8) } ?? "nil"
            let owner = attributes[.ownerAccountName] as? String ?? "nil"
            let group = attributes[.groupOwnerAccountName] as? String ?? "nil"
            let modified = (attributes[.modificationDate] as? Date)?.description ?? "nil"
            return [
                "path=\(path)",
                "exists=true",
                "size=\(size)",
                "perms=\(permissions)",
                "owner=\(owner)",
                "group=\(group)",
                "modified=\(modified)",
            ].joined(separator: " ")
        } catch {
            return "path=\(path) exists=true attributeError=\(describe(error: error))"
        }
    }

    private static func launchDaemonPlistSummary(path: String) -> String {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let plistObject = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let plist = plistObject as? [String: Any] else {
                return "invalidPlistType=\(String(describing: type(of: plistObject)))"
            }

            let label = plist["Label"] as? String ?? "nil"
            let runAtLoad = (plist["RunAtLoad"] as? Bool).map(String.init) ?? "nil"
            let machServices = (plist["MachServices"] as? [String: Any])?
                .keys
                .sorted()
                .joined(separator: ",") ?? "nil"
            let programArguments = (plist["ProgramArguments"] as? [String])?
                .joined(separator: " ") ?? "nil"

            return [
                "label=\(label)",
                "runAtLoad=\(runAtLoad)",
                "machServices=\(machServices)",
                "programArguments=\(programArguments)",
            ].joined(separator: " ")
        } catch {
            return "error=\(describe(error: error))"
        }
    }

    private static func codesignSummary(path: String, fileManager: FileManager) -> String {
        guard fileManager.fileExists(atPath: path) else {
            return "missing"
        }

        let details = runCommand(
            executablePath: "/usr/bin/codesign",
            arguments: ["-dvv", path]
        )
        let requirements = runCommand(
            executablePath: "/usr/bin/codesign",
            arguments: ["-d", "-r-", path]
        )

        let interestingPrefixes = ["Identifier=", "TeamIdentifier=", "Authority=", "Signature="]
        let detailLines = details.output
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                interestingPrefixes.contains { line.hasPrefix($0) }
            }

        let requirementLine = requirements.output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("designated =>") } ?? "designated => unavailable"

        var components = ["status=\(details.statusDescription)"]
        if !detailLines.isEmpty {
            components.append(detailLines.joined(separator: " | "))
        } else {
            components.append("details=\(details.summary)")
        }
        components.append(requirementLine)
        return components.joined(separator: " | ")
    }

    private static func commandSummary(executablePath: String, arguments: [String]) -> String {
        runCommand(executablePath: executablePath, arguments: arguments).summary
    }

    private static func runCommand(executablePath: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            return CommandResult(
                terminationStatus: process.terminationStatus,
                output: output
            )
        } catch {
            return CommandResult(
                terminationStatus: nil,
                output: "processError=\(describe(error: error))"
            )
        }
    }
}

private struct CommandResult {
    let terminationStatus: Int32?
    let output: String

    var statusDescription: String {
        terminationStatus.map(String.init) ?? "error"
    }

    var summary: String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "status=\(statusDescription) output=<empty>"
        }

        let lines = trimmed
            .split(separator: "\n")
            .prefix(8)
            .map(String.init)
        let joined = lines.joined(separator: " | ")
        let suffix = trimmed.split(separator: "\n").count > lines.count ? " | ..." : ""
        return "status=\(statusDescription) output=\(joined)\(suffix)"
    }
}

struct PrivilegedHelperDiagnosticContext {
    let context: String
    let helperLabel: String
    let bundlePath: String
    let executablePath: String
    let bundleIdentifier: String
    let embeddedPath: String?
    let installedHelperPath: String
    let launchDaemonPath: String
    let launchDaemonExists: Bool
    let fileManager: FileManager
}
