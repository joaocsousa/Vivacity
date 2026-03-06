import XCTest
@testable import Vivacity

final class PrivilegedHelperInstallServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testInstallIfNeededSkipsBlessWhenInstalledHelperMatchesEmbeddedHelper() throws {
        let installedRoot = try makeTemporaryDirectory()
        let embeddedRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: installedRoot) }
        defer { try? fileManager.removeItem(at: embeddedRoot) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: installedRoot.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: installedRoot)
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: embeddedRoot.appendingPathComponent(label).path
        )

        var blessCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: installedRoot.path,
            installedLaunchDaemonRoot: installedRoot.path,
            embeddedHelperRoot: embeddedRoot.path,
            helperReachabilityProbe: { true },
            blessHelperAction: { blessCallCount += 1 }
        )

        try service.installIfNeeded()

        XCTAssertEqual(blessCallCount, 0)
    }

    func testInstallIfNeededCallsBlessWhenInstalledHelperVersionIsOlderThanEmbeddedVersion() throws {
        let installedRoot = try makeTemporaryDirectory()
        let embeddedRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: installedRoot) }
        defer { try? fileManager.removeItem(at: embeddedRoot) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: installedRoot.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: installedRoot)
        try writeExecutable(
            helperBinaryData(bundleVersion: "2"),
            to: embeddedRoot.appendingPathComponent(label).path
        )

        var blessCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: installedRoot.path,
            installedLaunchDaemonRoot: installedRoot.path,
            embeddedHelperRoot: embeddedRoot.path,
            helperReachabilityProbe: { true },
            blessHelperAction: { blessCallCount += 1 }
        )

        try service.installIfNeeded()

        XCTAssertEqual(blessCallCount, 1)
    }

    func testInstallIfNeededSkipsBlessWhenInstalledHelperIsNotExecutableByCurrentUser() throws {
        let installedRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: installedRoot) }

        let label = "com.test.vivacity.helper"
        let installedPath = installedRoot.appendingPathComponent(label).path
        fileManager.createFile(atPath: installedPath, contents: helperBinaryData(bundleVersion: "1"))
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedPath)
        try writeLaunchDaemonPlist(for: label, to: installedRoot)

        var blessCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: installedRoot.path,
            installedLaunchDaemonRoot: installedRoot.path,
            helperReachabilityProbe: { true },
            blessHelperAction: { blessCallCount += 1 }
        )

        try service.installIfNeeded()

        XCTAssertEqual(blessCallCount, 0)
    }

    func testInstallIfNeededCallsBlessWhenHelperIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        var blessCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: "com.test.vivacity.missing",
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            blessHelperAction: { blessCallCount += 1 }
        )

        try service.installIfNeeded()

        XCTAssertEqual(blessCallCount, 1)
    }

    func testCurrentStatusReturnsNotInstalledWhenArtifactsExistButHelperIsUnreachable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: root.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: root)

        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            helperReachabilityProbe: { false }
        )

        XCTAssertEqual(service.currentStatus(), .notInstalled)
    }

    func testCurrentStatusReturnsNotInstalledWhenOnlyHelperBinaryExists() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: root.appendingPathComponent(label).path
        )

        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            helperReachabilityProbe: { true }
        )

        XCTAssertEqual(service.currentStatus(), .notInstalled)
    }

    func testInstallIfNeededSkipsBlessWhenEmbeddedHelperUnavailable() throws {
        let installedRoot = try makeTemporaryDirectory()
        let embeddedRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: installedRoot) }
        defer { try? fileManager.removeItem(at: embeddedRoot) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            Data("helper-v1".utf8),
            to: installedRoot.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: installedRoot)

        var blessCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: installedRoot.path,
            installedLaunchDaemonRoot: installedRoot.path,
            embeddedHelperRoot: embeddedRoot.path,
            helperReachabilityProbe: { true },
            blessHelperAction: { blessCallCount += 1 }
        )

        try service.installIfNeeded()

        XCTAssertEqual(blessCallCount, 0)
    }

    func testInstallIfNeededPropagatesBlessErrorWhenHelperIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let service = PrivilegedHelperInstallService(
            helperLabel: "com.test.vivacity.error",
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            blessHelperAction: { throw InstallError.syntheticFailure }
        )

        XCTAssertThrowsError(try service.installIfNeeded()) { error in
            guard let installError = error as? InstallError else {
                XCTFail("Unexpected error type: \(type(of: error))")
                return
            }
            XCTAssertEqual(installError, .syntheticFailure)
        }
    }

    func testUninstallIfInstalledSkipsRemovalWhenHelperIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        var removeCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: "com.test.vivacity.missing",
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            removeHelperAction: { removeCallCount += 1 }
        )

        try service.uninstallIfInstalled()

        XCTAssertEqual(removeCallCount, 0)
    }

    func testUninstallIfInstalledCallsRemovalWhenHelperExists() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: root.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: root)

        var removeCallCount = 0
        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            removeHelperAction: { removeCallCount += 1 }
        )

        try service.uninstallIfInstalled()

        XCTAssertEqual(removeCallCount, 1)
    }

    func testUninstallIfInstalledPropagatesRemovalErrors() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let label = "com.test.vivacity.helper"
        try writeExecutable(
            helperBinaryData(bundleVersion: "1"),
            to: root.appendingPathComponent(label).path
        )
        try writeLaunchDaemonPlist(for: label, to: root)

        let service = PrivilegedHelperInstallService(
            helperLabel: label,
            fileManager: fileManager,
            installedHelperRoot: root.path,
            installedLaunchDaemonRoot: root.path,
            removeHelperAction: { throw InstallError.syntheticFailure }
        )

        XCTAssertThrowsError(try service.uninstallIfInstalled()) { error in
            guard let installError = error as? InstallError else {
                XCTFail("Unexpected error type: \(type(of: error))")
                return
            }
            XCTAssertEqual(installError, .syntheticFailure)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("vivacity-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ contents: Data, to path: String) throws {
        fileManager.createFile(atPath: path, contents: contents)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func writeLaunchDaemonPlist(for label: String, to root: URL) throws {
        let contents =
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
            </dict>
            </plist>
            """
        let path = root.appendingPathComponent("\(label).plist").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func helperBinaryData(bundleVersion: String) -> Data {
        Data(
            """
            \u{0}
            noise
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleShortVersionString</key>
                <string>1.0</string>
                <key>CFBundleVersion</key>
                <string>\(bundleVersion)</string>
            </dict>
            </plist>
            tail
            """.utf8
        )
    }
}

private enum InstallError: Error, Equatable {
    case syntheticFailure
}
