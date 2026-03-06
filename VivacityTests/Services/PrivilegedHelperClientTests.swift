import XCTest
@testable import Vivacity

final class PrivilegedHelperClientTests: XCTestCase {
    func testPrepareForPrivilegedAccessAttemptsInstallOnlyOnceOnSuccess() {
        let installer = FakePrivilegedHelperInstaller()
        let client = PrivilegedHelperClient(
            serviceName: "com.test.vivacity.helper",
            installService: installer
        )

        client.prepareForPrivilegedAccess()
        client.prepareForPrivilegedAccess()

        XCTAssertEqual(installer.callCount, 1)
        XCTAssertNil(client.lastInstallErrorDescription)
    }

    func testPrepareForPrivilegedAccessAttemptsInstallOnlyOnceOnFailure() {
        let installer = FakePrivilegedHelperInstaller(error: InstallerError.syntheticFailure)
        let client = PrivilegedHelperClient(
            serviceName: "com.test.vivacity.helper",
            installService: installer
        )

        client.prepareForPrivilegedAccess()
        client.prepareForPrivilegedAccess()

        XCTAssertEqual(installer.callCount, 1)
        XCTAssertNotNil(client.lastInstallErrorDescription)
    }
}

private final class FakePrivilegedHelperInstaller: PrivilegedHelperInstalling {
    private(set) var callCount = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func installIfNeeded() throws {
        callCount += 1
        if let error {
            throw error
        }
    }
}

private enum InstallerError: Error {
    case syntheticFailure
}
