import Foundation

extension FileScanViewModel {
    /// Verifies selected files by hashing head/tail samples before recovery.
    ///
    /// Returns a summary with counts of verified, mismatched, and unreadable files.
    func verifySelectedSamples(device: StorageDevice) async -> SampleVerificationSummary? {
        let selectedFiles = foundFiles.filter { selectedFileIDs.contains($0.id) }
        guard !selectedFiles.isEmpty else {
            logger.debug("Skipping sample verification because no files are selected")
            return nil
        }

        let verificationStartMessage =
            "Starting pre-recovery sample verification device=\(device.name) " +
            "path=\(device.volumePath.path) selectedFiles=\(selectedFiles.count)"
        logger.info("\(verificationStartMessage, privacy: .public)")

        isVerifyingSamples = true
        defer { isVerifyingSamples = false }

        do {
            let results = try await fileSampleVerifier.verifySamples(files: selectedFiles, from: device)
            let unreadableReasonSummary = summarizedUnreadableReasons(
                from: results.filter { $0.status == .unreadable }
            )
            let summary = SampleVerificationSummary(
                verifiedCount: results.filter { $0.status == .verified }.count,
                mismatchCount: results.filter { $0.status == .mismatch }.count,
                unreadableCount: results.filter { $0.status == .unreadable }.count,
                unreadableReasonSummary: unreadableReasonSummary
            )
            let verificationEndMessage =
                "Completed pre-recovery sample verification device=\(device.name) " +
                "verified=\(summary.verifiedCount) mismatch=\(summary.mismatchCount) " +
                "unreadable=\(summary.unreadableCount) " +
                "reasonSummary=\(summary.unreadableReasonSummary ?? "nil")"
            logger.info("\(verificationEndMessage, privacy: .public)")
            lastSampleVerificationSummary = summary
            return summary
        } catch {
            logger.error("Sample verification failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Sample verification failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func summarizedUnreadableReasons(from results: [FileSampleVerification]) -> String? {
        let reasons = results.compactMap(\.failureReason).filter { !$0.isEmpty }
        guard !reasons.isEmpty else { return nil }

        let grouped = Dictionary(grouping: reasons, by: { $0 })
        let ordered = grouped.sorted { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key < rhs.key
            }
            return lhs.value.count > rhs.value.count
        }

        return ordered.prefix(3).map { reason, matches in
            "\(reason) (\(matches.count))"
        }.joined(separator: ", ")
    }
}
