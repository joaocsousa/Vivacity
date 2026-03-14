import Darwin
import Foundation
import Security

enum LegacyServiceManagementAPI {
    private typealias BlessFunction =
        @convention(c) (
            CFString,
            CFString,
            AuthorizationRef?,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Bool

    private typealias RemoveFunction =
        @convention(c) (
            CFString,
            CFString,
            AuthorizationRef?,
            Bool,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Bool

    private static let frameworkPath =
        "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement"

    private static let frameworkHandle: UnsafeMutableRawPointer? = dlopen(
        frameworkPath,
        RTLD_NOW | RTLD_LOCAL
    )

    private static let blessFunction: BlessFunction? = loadSymbol(named: "SMJobBless")
    private static let removeFunction: RemoveFunction? = loadSymbol(named: "SMJobRemove")

    static func bless(
        domain: CFString,
        executableLabel: CFString,
        authorizationRef: AuthorizationRef,
        outError: UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool {
        guard let blessFunction else {
            populateUnavailableError(
                outError,
                operation: "install privileged helper"
            )
            return false
        }

        return blessFunction(domain, executableLabel, authorizationRef, outError)
    }

    static func remove(
        domain: CFString,
        jobLabel: CFString,
        authorizationRef: AuthorizationRef,
        wait: Bool,
        outError: UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool {
        guard let removeFunction else {
            populateUnavailableError(
                outError,
                operation: "remove privileged helper"
            )
            return false
        }

        return removeFunction(domain, jobLabel, authorizationRef, wait, outError)
    }

    private static func loadSymbol<T>(named name: String) -> T? {
        guard let frameworkHandle,
              let symbol = dlsym(frameworkHandle, name)
        else {
            return nil
        }

        return unsafeBitCast(symbol, to: T.self)
    }

    private static func populateUnavailableError(
        _ outError: UnsafeMutablePointer<Unmanaged<CFError>?>?,
        operation: String
    ) {
        let message = "ServiceManagement legacy API unavailable while attempting to \(operation)."
        let userInfo = [kCFErrorLocalizedDescriptionKey as String: message] as CFDictionary
        guard let error = CFErrorCreate(
            kCFAllocatorDefault,
            "com.vivacity.app.PrivilegedHelper" as CFString,
            1,
            userInfo
        ) else {
            outError?.pointee = nil
            return
        }
        outError?.pointee = Unmanaged.passRetained(error)
    }
}
