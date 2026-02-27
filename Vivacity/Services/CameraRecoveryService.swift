import Foundation

/// Analyzes files discovered during Fast Scan to deduce the camera profile of the volume.
protocol CameraRecoveryServicing: Sendable {
    /// Inspects the file paths of recovered files and returns a best-guess CameraProfile.
    func detectProfile(from files: [RecoverableFile]) -> CameraProfile
}

struct CameraRecoveryService: CameraRecoveryServicing {
    func detectProfile(from files: [RecoverableFile]) -> CameraProfile {
        // Collect all directory names from the files found during Fast Scan
        // We only care about fast scan results because deep scan doesn't have directory structures.
        var directoryCounts: [String: Int] = [:]

        for file in files where file.source == .fastScan {
            guard let path = file.filePath else { continue }

            let url = URL(fileURLWithPath: path)
            // Extract the immediate parent directory or directories leading up to the file
            let components = url.pathComponents
            for component in components {
                // Ignore empty, root, and current dir components
                if component != "/", component != ".", !component.isEmpty {
                    directoryCounts[component.uppercased(), default: 0] += 1
                }
            }
        }

        // We weight evidence. If multiple profiles match, the highest score wins.
        var profileScores: [CameraProfile: Int] = [
            .goPro: 0,
            .canon: 0,
            .sony: 0,
            .dji: 0,
        ]

        // Check our directory counts against known clues
        for (directory, count) in directoryCounts {
            for profile in CameraProfile.allCases where profile != .generic {
                if profile.directoryClues.contains(directory) {
                    profileScores[profile, default: 0] += count
                }
            }
        }

        // Find the profile with the highest non-zero score
        let bestMatch = profileScores.max(by: { $0.value < $1.value })

        if let best = bestMatch, best.value > 0 {
            return best.key
        }

        return .generic
    }
}
