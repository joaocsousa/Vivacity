import SwiftUI

/// Main scan screen showing progressive file discovery with a single unified scan.
///
/// Layout matches the Stitch designs:
/// 1. Header with status/progress bar and stop button
/// 2. Scrolling file list with checkboxes
/// 3. Footer with select all/deselect, file count, and recover button
struct FileScanView: View {
    struct RecoveryNavigationState: Identifiable, Hashable {
        let id = UUID()
        let device: StorageDevice
        let selectedFiles: [RecoverableFile]
    }

    let device: StorageDevice
    let sessionToResume: ScanSession?

    @State private var viewModel = AppEnvironment.makeFileScanViewModel()
    @State private var recoveryNavigationState: RecoveryNavigationState?
    @State private var verificationWarningMessage: String?
    @State private var pendingRecoveryFiles: [RecoverableFile] = []

    init(device: StorageDevice, sessionToResume: ScanSession? = nil) {
        self.device = device
        self.sessionToResume = sessionToResume
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FilterToolbar(
                fileNameQuery: $viewModel.fileNameQuery,
                fileTypeFilter: $viewModel.fileTypeFilter,
                fileSizeFilter: $viewModel.fileSizeFilter,
                isEnabled: viewModel.hasFiles
            )

            if viewModel.permissionDenied {
                PermissionDeniedView(
                    onTryAgain: { checkPermissionsAndScan() },
                    onContinueLimited: {
                        viewModel.permissionDenied = false
                    }
                )
            } else if viewModel.foundFiles.isEmpty, viewModel.isScanning {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .padding(.bottom, 8)

                    Text("Scanning for files...")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("Found files will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 300, idealWidth: 350)

                    FilePreviewView(
                        file: viewModel.previewFile,
                        device: device
                    )
                    .frame(minWidth: 350, idealWidth: 450, maxWidth: .infinity)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 580)
        .background(Color(.windowBackgroundColor))
        .task {
            if let session = sessionToResume {
                viewModel.resumeSession(session, device: device)
            } else {
                checkPermissionsAndScan()
            }
        }
        .onDisappear {
            if viewModel.isScanning {
                viewModel.stopScanning()
            }
        }
        .alert(
            "Scan Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                if let message = viewModel.errorMessage {
                    Text(message)
                }
            }
        )
        .alert(
            "Sample Verification Warning",
            isPresented: Binding(
                get: { verificationWarningMessage != nil },
                set: { if !$0 { verificationWarningMessage = nil } }
            ),
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Continue Recovery", role: .destructive) {
                    recoveryNavigationState = RecoveryNavigationState(
                        device: device,
                        selectedFiles: pendingRecoveryFiles
                    )
                }
            },
            message: {
                if let warning = verificationWarningMessage {
                    Text(warning)
                }
            }
        )
        .navigationDestination(item: $recoveryNavigationState) { state in
            RecoveryDestinationView(scannedDevice: state.device, selectedFiles: state.selectedFiles)
        }
    }

    // MARK: - Scan Helpers

    /// Starts the unified scan immediately, combining all available methods.
    private func checkPermissionsAndScan() {
        viewModel.startScan(device: device)
    }

    private var selectedFilesForRecovery: [RecoverableFile] {
        viewModel.foundFiles.filter { viewModel.selectedFileIDs.contains($0.id) }
    }

    private func verifyThenRecover() async {
        let selectedFiles = selectedFilesForRecovery
        guard !selectedFiles.isEmpty else { return }
        pendingRecoveryFiles = selectedFiles

        guard let summary = await viewModel.verifySelectedSamples(device: device) else {
            return
        }

        if summary.hasWarnings {
            verificationWarningMessage = summary.warningMessage
        } else {
            recoveryNavigationState = RecoveryNavigationState(
                device: device,
                selectedFiles: selectedFiles
            )
        }
    }

    private func verifySamplesOnly() async {
        _ = await viewModel.verifySelectedSamples(device: device)
    }
}

/// Toolbar for filtering scan results by type, size, and name.
private struct FilterToolbar: View {
    @Binding var fileNameQuery: String
    @Binding var fileTypeFilter: FileScanViewModel.FileTypeFilter
    @Binding var fileSizeFilter: FileScanViewModel.FileSizeFilter
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("Filter")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Picker("Type", selection: $fileTypeFilter) {
                ForEach(FileScanViewModel.FileTypeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Picker("Size", selection: $fileSizeFilter) {
                ForEach(FileScanViewModel.FileSizeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField("Search filename or path", text: $fileNameQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if isEnabled {
                Button("Clear") {
                    fileNameQuery = ""
                    fileTypeFilter = .all
                    fileSizeFilter = .any
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color(.separatorColor)),
            alignment: .bottom
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: - Header

extension FileScanView {
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                // Device name
                HStack(spacing: 6) {
                    Image(systemName: device.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Stop button (only visible during scanning)
                if viewModel.isScanning {
                    Button(role: .destructive) {
                        viewModel.stopScanning()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                            Text("Stop Scanning")
                                .font(.system(size: 13))
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if viewModel.scanPhase == .complete {
                    Button {
                        Task {
                            await viewModel.saveSession(device: device)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                            Text("Save Session")
                                .font(.system(size: 13))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Phase label + progress
            scanStatusView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var scanStatusView: some View {
        switch viewModel.scanPhase {
        case .idle:
            EmptyView()

        case .scanning:
            VStack(spacing: 8) {
                HStack {
                    Text("Scanning in Progress…")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(viewModel.progressPercentageText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                ProgressView(value: viewModel.progress)
                    .tint(.blue)

                if let eta = viewModel.estimatedTimeRemainingText {
                    HStack {
                        Text("About \(eta) remaining")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

        case .complete:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)

                Text("Scan Complete")
                    .font(.system(size: 15, weight: .semibold))

                if let duration = viewModel.scanDurationText {
                    Text("in \(duration)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }
}

// MARK: - File List

extension FileScanView {
    private var fileList: some View {
        ZStack {
            if viewModel.showFilteredEmptyState, !viewModel.isScanning {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No files match the current filters.")
                )
            } else if viewModel.foundFiles.isEmpty, !viewModel.isScanning {
                ContentUnavailableView(
                    "No Files Found",
                    systemImage: "doc.questionmark.fill",
                    description: Text("No recoverable files were found on this device.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !viewModel.filteredFiles.isEmpty {
                            sectionHeader(
                                title: "SCAN RESULTS",
                                count: viewModel.filteredFiles.count
                            )

                            ForEach(viewModel.filteredFiles) { file in
                                FileRow(
                                    file: file,
                                    isSelected: viewModel.selectedFileIDs.contains(file.id),
                                    isPreviewSelected: viewModel.previewFileID == file.id,
                                    onToggle: { viewModel.toggleSelection(file.id) },
                                    onSelectForPreview: { viewModel.previewFileID = file.id }
                                )
                                Divider().opacity(0.2)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            Spacer()

            Text("\(count) files")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.unemphasizedSelectedContentBackgroundColor))
    }
}

// MARK: - Footer

extension FileScanView {
    private var footer: some View {
        HStack {
            // Select All / Deselect All
            HStack(spacing: 12) {
                Button("Select All") { viewModel.selectAllFiltered() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
                    .disabled(viewModel.filteredFiles.isEmpty)

                Button("Deselect All") { viewModel.deselectFiltered() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
                    .disabled(viewModel.selectedFilteredCount == 0)
            }

            Spacer()

            // File count
            HStack(spacing: 8) {
                Text(viewModel.filteredCountLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if let selectionLabel = viewModel.selectedCountLabel {
                    Text(selectionLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task {
                    await verifySamplesOnly()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11))
                    Text(viewModel.isVerifyingSamples ? "Verifying…" : "Verify Sample")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.canRecover || viewModel.isVerifyingSamples)

            // Recover button
            Button {
                Task {
                    await verifyThenRecover()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 11, weight: .semibold))
                    if viewModel.selectedCount > 0 {
                        Text("Recover Selected (\(viewModel.selectedCount))")
                    } else {
                        Text("Recover Selected")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canRecover || viewModel.isVerifyingSamples)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview {
    FileScanView(
        device: StorageDevice(
            id: "preview",
            name: "Samsung T7",
            volumePath: URL(fileURLWithPath: "/Volumes/USB"),
            volumeUUID: "preview-samsung",
            filesystemType: .exfat,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 2_000_000_000_000,
            availableCapacity: 1_200_000_000_000
        )
    )
}
