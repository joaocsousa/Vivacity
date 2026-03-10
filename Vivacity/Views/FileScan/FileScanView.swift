import SwiftUI

struct FileScanView: View {
    struct RecoveryNavigationState: Identifiable, Hashable {
        let id = UUID()
        let device: StorageDevice
        let selectedFiles: [RecoverableFile]
    }

    let sessionToResume: ScanSession?
    @State private var activeDevice: StorageDevice
    @State private var viewModel = AppEnvironment.makeFileScanViewModel()
    @State private var recoveryNavigationState: RecoveryNavigationState?
    @State private var verificationWarningMessage: String?
    @State private var pendingRecoveryFiles: [RecoverableFile] = []

    init(device: StorageDevice, sessionToResume: ScanSession? = nil) {
        self.sessionToResume = sessionToResume
        _activeDevice = State(initialValue: device)
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

            if shouldShowScanAccessInterruption {
                scanAccessInterruptionView
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
                        device: activeDevice
                    )
                    .frame(minWidth: 350, idealWidth: 450, maxWidth: .infinity)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 580)
        .background(Color(.windowBackgroundColor))
        .overlay {
            if viewModel.isCreatingImage {
                ZStack {
                    Color.primary.opacity(0.2)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.imageCreationProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)

                        Text("Creating Byte-to-Byte Disk Image...")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("\(Int(viewModel.imageCreationProgress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 10)
                }
            }
        }
        .task {
            if let session = sessionToResume {
                viewModel.refreshHelperStatus()
                viewModel.resumeSession(session, device: activeDevice)
            } else {
                viewModel.beginScanFlow(for: activeDevice)
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
                        device: activeDevice,
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

    private var shouldShowScanAccessInterruption: Bool {
        viewModel.scanPhase == .idle
            && viewModel.scanAccessState != .fullScan
            && viewModel.scanAccessState != .limitedOnly
    }

    @ViewBuilder
    private var scanAccessInterruptionView: some View {
        let canCreateImage = viewModel.canOfferInAppImageCreation(for: activeDevice)
        let canTryAgain = viewModel.canRetryFullScan(for: activeDevice)
        ScanAccessInterruptionView(
            state: viewModel.scanAccessState,
            message: viewModel.scanAccessMessage,
            onCreateImage: canCreateImage ? {
                promptForDiskImageDestination()
            } : nil,
            onLoadImage: {
                promptToLoadDiskImage()
            },
            onContinueLimited: {
                viewModel.continueWithLimitedScan(device: activeDevice)
            },
            onTryAgain: canTryAgain ? {
                viewModel.retryFullScanIfPossible(device: activeDevice)
            } : nil
        )
    }

    private func promptToLoadDiskImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.data, .diskImage, .rawImage]
        panel.title = "Select Disk Image"

        if panel.runModal() == .OK, let url = panel.url {
            loadDiskImage(from: url)
        }
    }

    private func loadDiskImage(from url: URL) {
        activeDevice = viewModel.activateDiskImageScan(from: url)
    }

    private func promptForDiskImageDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "\(activeDevice.name)_Image.dd"
        panel.title = "Save Disk Image"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                if let imageDevice = await viewModel.createDiskImageAndActivateScan(from: activeDevice, to: url) {
                    activeDevice = imageDevice
                }
            }
        }
    }

    private var selectedFilesForRecovery: [RecoverableFile] {
        viewModel.foundFiles.filter { viewModel.selectedFileIDs.contains($0.id) }
    }

    private func verifyThenRecover() async {
        let selectedFiles = selectedFilesForRecovery
        guard !selectedFiles.isEmpty else { return }
        pendingRecoveryFiles = selectedFiles

        guard let summary = await viewModel.verifySelectedSamples(device: activeDevice) else {
            return
        }

        if let blockingMessage = summary.blockingMessage {
            viewModel.errorMessage = blockingMessage
        } else if summary.hasWarnings {
            verificationWarningMessage = summary.warningMessage
        } else {
            recoveryNavigationState = RecoveryNavigationState(
                device: activeDevice,
                selectedFiles: selectedFiles
            )
        }
    }

    private func verifySamplesOnly() async {
        _ = await viewModel.verifySelectedSamples(device: activeDevice)
    }
}

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

extension FileScanView {
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: activeDevice.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(activeDevice.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

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
                            await viewModel.saveSession(device: activeDevice)
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

extension FileScanView {
    private var fileList: some View {
        let filteredFiles = viewModel.filteredFiles
        let selectedFileIDs = viewModel.selectedFileIDs
        let previewFileID = viewModel.previewFileID
        let isScanning = viewModel.isScanning
        let hasFiles = !viewModel.foundFiles.isEmpty

        return ZStack {
            if hasFiles, filteredFiles.isEmpty, !isScanning {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No files match the current filters.")
                )
            } else if !hasFiles, !isScanning {
                ContentUnavailableView(
                    "No Files Found",
                    systemImage: "doc.questionmark.fill",
                    description: Text("No recoverable files were found on this device.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !filteredFiles.isEmpty {
                            Section {
                                ForEach(filteredFiles) { file in
                                    FileRow(
                                        file: file,
                                        isSelected: selectedFileIDs.contains(file.id),
                                        isPreviewSelected: previewFileID == file.id,
                                        onToggle: { viewModel.toggleSelection(file.id) },
                                        onSelectForPreview: { viewModel.previewFileID = file.id }
                                    )
                                    .equatable()
                                    Divider().opacity(0.2)
                                }
                            } header: {
                                sectionHeader(
                                    title: "SCAN RESULTS",
                                    count: filteredFiles.count
                                )
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

extension FileScanView {
    private var footer: some View {
        HStack {
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
