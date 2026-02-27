import SwiftUI

/// Main scan screen showing progressive file discovery with dual-scan phases.
///
/// Layout matches the Stitch designs:
/// 1. Header with status/progress bar and stop button
/// 2. Deep Scan prompt card (shown after fast scan completes)
/// 3. Scrolling file list with checkboxes
/// 4. Footer with select all/deselect, file count, and recover button
struct FileScanView: View {
    let device: StorageDevice
    @State private var viewModel = AppEnvironment.makeFileScanViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deepScanPrompt

            if viewModel.permissionDenied {
                PermissionDeniedView(
                    onTryAgain: { startDeepScan() },
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
            checkPermissionsAndScan()
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
    }

    // MARK: - Scan Helpers

    /// Starts fast scan immediately — no elevated access required.
    ///
    /// Fast Scan uses FileManager to walk the mounted filesystem, which
    /// macOS allows without special permissions for external volumes.
    private func checkPermissionsAndScan() {
        viewModel.startFastScan(device: device)
    }

    /// Starts deep scan. PrivilegedDiskReader handles authorization
    /// internally — it will show the macOS password dialog if the device
    /// is not directly accessible.
    private func startDeepScan() {
        viewModel.startDeepScan(device: device)
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

        case .fastScanning:
            VStack(spacing: 8) {
                HStack {
                    Text("Fast Scan in Progress…")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                ProgressView(value: viewModel.progress)
                    .tint(.blue)
            }

        case .fastComplete:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast Scan Complete")
                        .font(.system(size: 15, weight: .semibold))
                    if let duration = viewModel.fastScanDuration {
                        Text("Completed in \(Int(duration)) seconds")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

        case .deepScanning:
            VStack(spacing: 8) {
                HStack {
                    Text("Deep Scan in Progress…")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.purple)
                }

                ProgressView(value: viewModel.progress)
                    .tint(.purple)
            }

        case .complete:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)

                Text("Scan Complete")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()
            }
        }
    }
}

// MARK: - Deep Scan Prompt

extension FileScanView {
    @ViewBuilder
    private var deepScanPrompt: some View {
        if viewModel.scanPhase == .fastComplete {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 44, height: 44)

                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.foundFiles.count) files found. Run Deep Scan for more?")
                            .font(.system(size: 14, weight: .semibold))

                        Text(
                            "Deep Scan reads every sector of the drive to find older or " +
                                "corrupted files. This may take several hours but yields more thorough results."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    }
                }

                HStack(spacing: 12) {
                    Spacer()

                    Button {
                        viewModel.skipDeepScan()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        startDeepScan()
                    } label: {
                        Text("Start Deep Scan")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - File List

extension FileScanView {
    private var fileList: some View {
        ZStack {
            if viewModel.foundFiles.isEmpty, !viewModel.isScanning {
                ContentUnavailableView(
                    "No Files Found",
                    systemImage: "doc.questionmark.fill",
                    description: Text("No recoverable files were found on this device.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Deep scan prompt card
                        deepScanPrompt

                        // Section: Fast Scan Results
                        if !viewModel.fastScanFiles.isEmpty {
                            sectionHeader(
                                title: "FAST SCAN RESULTS",
                                count: viewModel.fastScanFiles.count
                            )

                            ForEach(viewModel.fastScanFiles) { file in
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

                        // Section: Deep Scan Results
                        if !viewModel.deepScanFiles.isEmpty {
                            sectionHeader(
                                title: "DEEP SCAN RESULTS",
                                count: viewModel.deepScanFiles.count
                            )

                            ForEach(viewModel.deepScanFiles) { file in
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
                Button("Select All") { viewModel.selectAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
                    .disabled(viewModel.foundFiles.isEmpty)

                Button("Deselect All") { viewModel.deselectAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
                    .disabled(viewModel.selectedFileIDs.isEmpty)
            }

            Spacer()

            // File count
            Text("\(viewModel.foundFiles.count) files found")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            // Recover button
            Button {
                // TODO: Navigate to recovery destination (M4)
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
            .disabled(!viewModel.canRecover)
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
