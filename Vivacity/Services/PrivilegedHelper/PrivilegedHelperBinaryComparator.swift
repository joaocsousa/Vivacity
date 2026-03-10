import Foundation

enum PrivilegedHelperBinaryComparator {
    static func compare(
        installedVersion: HelperVersion,
        embeddedVersion: HelperVersion
    ) -> ComparisonResult {
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

    static func binariesDiffer(
        installedPath: String,
        embeddedPath: String,
        fileManager: FileManager
    ) throws -> Bool {
        let installedAttributes = try fileManager.attributesOfItem(atPath: installedPath)
        let embeddedAttributes = try fileManager.attributesOfItem(atPath: embeddedPath)
        let installedSize = installedAttributes[.size] as? NSNumber
        let embeddedSize = embeddedAttributes[.size] as? NSNumber
        if installedSize != embeddedSize {
            return true
        }

        let installedData = try Data(
            contentsOf: URL(fileURLWithPath: installedPath),
            options: [.mappedIfSafe]
        )
        let embeddedData = try Data(
            contentsOf: URL(fileURLWithPath: embeddedPath),
            options: [.mappedIfSafe]
        )
        return installedData != embeddedData
    }
}
