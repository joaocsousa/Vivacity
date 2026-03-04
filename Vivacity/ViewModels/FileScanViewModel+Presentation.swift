import Foundation

extension FileScanViewModel {
    struct SampleVerificationSummary: Sendable, Equatable {
        let verifiedCount: Int
        let mismatchCount: Int
        let unreadableCount: Int

        var hasWarnings: Bool {
            mismatchCount > 0 || unreadableCount > 0
        }

        var warningMessage: String {
            var parts: [String] = []
            if mismatchCount > 0 {
                parts.append("\(mismatchCount) file(s) changed between reads")
            }
            if unreadableCount > 0 {
                parts.append("\(unreadableCount) file(s) could not be read")
            }
            return parts.joined(separator: ", ")
        }
    }

    enum FileTypeFilter: String, CaseIterable, Sendable {
        case all = "All"
        case images = "Images"
        case videos = "Videos"
    }

    enum FileSizeFilter: String, CaseIterable, Sendable {
        case any = "Any Size"
        case under5MB = "Under 5 MB"
        case between5And100MB = "5-100 MB"
        case over100MB = "Over 100 MB"

        var byteRange: ClosedRange<Int64>? {
            switch self {
            case .any:
                nil
            case .under5MB:
                0 ... 5_000_000
            case .between5And100MB:
                5_000_001 ... 100_000_000
            case .over100MB:
                100_000_001 ... Int64.max
            }
        }
    }

    var progressPercentageText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var estimatedTimeRemainingText: String? {
        guard isScanning, let remaining = estimatedTimeRemaining, remaining.isFinite else {
            return nil
        }
        if remaining <= 60 {
            return "< 1 min"
        }
        return Self.etaFormatter.string(from: remaining)
    }

    var scanDurationText: String? {
        guard let duration = scanDuration else { return nil }
        return Self.durationFormatter.string(from: duration)
    }

    var previewFile: RecoverableFile? {
        guard let id = previewFileID else { return nil }
        return foundFiles.first { $0.id == id }
    }

    var selectedCount: Int {
        selectedFileIDs.count
    }

    var selectedFilteredCount: Int {
        let filteredIDs = Set(filteredFiles.map(\.id))
        return selectedFileIDs.intersection(filteredIDs).count
    }

    var isFiltering: Bool {
        !fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || fileTypeFilter != .all
            || fileSizeFilter != .any
    }

    var canRecover: Bool {
        scanPhase == .complete && !selectedFileIDs.isEmpty
    }

    var isScanning: Bool {
        scanPhase == .scanning
    }

    var hasFiles: Bool {
        !foundFiles.isEmpty
    }

    var filteredFiles: [RecoverableFile] {
        let normalizedQuery = fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return foundFiles.filter { file in
            if !normalizedQuery.isEmpty {
                let nameMatches = file.fullFileName.lowercased().contains(normalizedQuery)
                let pathMatches = file.filePath?.lowercased().contains(normalizedQuery) ?? false
                if !nameMatches, !pathMatches {
                    return false
                }
            }

            switch fileTypeFilter {
            case .all:
                break
            case .images:
                if file.fileType != .image { return false }
            case .videos:
                if file.fileType != .video { return false }
            }

            if let range = fileSizeFilter.byteRange, !range.contains(file.sizeInBytes) {
                return false
            }

            return true
        }
    }

    var showFilteredEmptyState: Bool {
        hasFiles && filteredFiles.isEmpty
    }

    var filteredCountLabel: String {
        if isFiltering {
            return "Showing \(filteredFiles.count) of \(foundFiles.count) files"
        }
        return "\(foundFiles.count) files found"
    }

    var selectedCountLabel: String? {
        guard selectedCount > 0 else { return nil }

        if isFiltering {
            return "Selected \(selectedFilteredCount) of \(filteredFiles.count) shown"
        }

        return "Selected \(selectedCount)"
    }

    func toggleSelection(_ fileID: UUID) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else {
            selectedFileIDs.insert(fileID)
        }
    }

    func selectAll() {
        selectedFileIDs = Set(foundFiles.map(\.id))
    }

    func selectAllFiltered() {
        let filteredIDs = Set(filteredFiles.map(\.id))
        selectedFileIDs.formUnion(filteredIDs)
    }

    func deselectAll() {
        selectedFileIDs.removeAll()
    }

    func deselectFiltered() {
        let filteredIDs = Set(filteredFiles.map(\.id))
        selectedFileIDs.subtract(filteredIDs)
    }
}
