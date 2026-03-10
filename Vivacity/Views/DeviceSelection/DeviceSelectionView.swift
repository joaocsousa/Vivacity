import SwiftUI

/// Screen that lists all available storage devices and lets the user select one to scan.
struct DeviceSelectionView: View {
    @State private var viewModel = AppEnvironment.makeDeviceSelectionViewModel()
    @State private var navigationTarget: NavigationDestination?
    @State private var showHelperUninstallDialog = false

    enum NavigationDestination: Hashable {
        case device(StorageDevice)
        case deviceWithSession(StorageDevice, ScanSession)
    }

    var body: some View {
        VStack(spacing: 0) {
            topSection
            Divider()
            deviceList
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 540)
        .background(Color(.windowBackgroundColor))
        .navigationDestination(item: $navigationTarget) { destination in
            switch destination {
            case let .device(device):
                FileScanView(device: device)
            case let .deviceWithSession(device, session):
                FileScanView(device: device, sessionToResume: session)
            }
        }
        .task {
            await viewModel.load()
        }
        .task {
            await viewModel.observeVolumeChanges()
        }
        .onChange(of: viewModel.pendingScanDevice) { _, _ in
            navigateToPendingScanIfNeeded()
        }
        .alert(
            "Error",
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
            item: Binding(
                get: { viewModel.helperFeedbackAlert },
                set: { if $0 == nil { viewModel.clearHelperFeedbackAlert() } }
            )
        ) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.clearHelperFeedbackAlert()
                }
            )
        }
        .confirmationDialog(
            "Uninstall Recovery Helper?",
            isPresented: $showHelperUninstallDialog,
            titleVisibility: .visible
        ) {
            Button("Uninstall Helper", role: .destructive) {
                viewModel.uninstallHelper()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the privileged recovery helper from this Mac. " +
                    "Disk images will still scan normally, but full raw-disk scans will need it reinstalled."
            )
        }
    }
}

// MARK: - Subviews

extension DeviceSelectionView {
    private func navigateToPendingScanIfNeeded() {
        guard let device = viewModel.consumePendingScanDevice() else { return }
        navigationTarget = .device(device)
    }

    private var topSection: some View {
        VStack(spacing: 0) {
            header
            helperManagementCard
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            // Icon in a rounded-square background
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 52, height: 52)

                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
            }
            .padding(.top, 24)

            Text("Select a Device")
                .font(.system(size: 20, weight: .bold))

            Text("Choose a storage device to scan for recoverable files.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var helperManagementCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(helperAccentColor.opacity(0.12))
                        .frame(width: 44, height: 44)

                    Image(systemName: helperSymbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(helperAccentColor)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(viewModel.helperStatusTitle)
                            .font(.system(size: 16, weight: .semibold))

                        Spacer()

                        helperStatusPill
                    }

                    Text(viewModel.helperStatusMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if let primaryActionTitle = viewModel.helperPrimaryActionTitle {
                    Button(primaryActionTitle) {
                        viewModel.installOrUpdateHelper()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(helperAccentColor)
                }

                if viewModel.helperShowsDestructiveAction {
                    Button("Uninstall Helper") {
                        showHelperUninstallDialog = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isLoading || viewModel.isCreatingImage)
                }

                Spacer()

                Text("Required for full physical-disk scans")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let callout = viewModel.helperAttentionCallout {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: callout.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(helperAccentColor)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(callout.title)
                            .font(.system(size: 12, weight: .semibold))

                        Text(callout.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(helperAccentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    viewModel.helperNeedsAttention
                        ? helperAccentColor.opacity(0.06)
                        : Color(nsColor: .controlBackgroundColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    helperAccentColor.opacity(viewModel.helperStatus == .updateRequired ? 0.38 : 0.18),
                    lineWidth: viewModel.helperStatus == .updateRequired ? 1.4 : 1
                )
        )
        .shadow(
            color: helperAccentColor.opacity(viewModel.helperStatus == .updateRequired ? 0.16 : 0),
            radius: 16,
            y: 8
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.helperStatus)
    }

    private var deviceList: some View {
        ZStack {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Discovering devices…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices Found",
                    systemImage: "externaldrive.trianglebadge.exclamationmark",
                    description: Text("Connect a storage device and try again.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.devices) { device in
                            DeviceRow(
                                device: device,
                                isSelected: viewModel.selectedDevice == device
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if viewModel.selectedDevice == device {
                                        viewModel.selectedDevice = nil
                                    } else {
                                        viewModel.selectedDevice = device
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    Task { await viewModel.searchForLostPartitions(on: device) }
                                } label: {
                                    Label("Find Lost Partitions", systemImage: "magnifyingglass")
                                }

                                if !device.isDiskImage {
                                    Divider()
                                    Button {
                                        let panel = NSSavePanel()
                                        panel.allowedContentTypes = [.data]
                                        panel.nameFieldStringValue = "\(device.name)_Image.dd"
                                        panel.title = "Save Disk Image"

                                        if panel.runModal() == .OK, let url = panel.url {
                                            Task { await viewModel.createImage(for: device, to: url) }
                                        }
                                    } label: {
                                        Label("Create Disk Image...", systemImage: "opticaldiscdrive")
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if viewModel.isCreatingImage {
                ZStack {
                    Color.primary.opacity(0.2)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.imageCreationProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 200)

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
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await viewModel.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)

            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canCreateDirectories = false
                panel.allowedContentTypes = [.data, .diskImage, .rawImage]
                panel.title = "Select Disk Image"

                if panel.runModal() == .OK, let url = panel.url {
                    viewModel.loadDiskImageAndQueueScan(at: url)
                }
            } label: {
                Label("Load Image...", systemImage: "doc.badge.plus")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)

            Spacer()

            // Selection count
            if viewModel.selectedDevice != nil {
                Text("1 device selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let selected = viewModel.selectedDevice {
                Button {
                    Task { await viewModel.searchForLostPartitions(on: selected) }
                } label: {
                    Text("Find Lost Partitions")
                }
                .disabled(viewModel.isLoading)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.trailing, 8)

                if let helperActionTitle = viewModel.selectedDeviceHelperActionTitle {
                    Button(helperActionTitle) {
                        viewModel.installOrUpdateHelper()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(helperAccentColor)
                    .disabled(viewModel.isLoading || viewModel.isCreatingImage)
                } else if let session = viewModel.savedSessions[selected.id] {
                    Button {
                        navigationTarget = .device(selected)
                    } label: {
                        Text("New Scan")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isLoading)

                    Button {
                        navigationTarget = .deviceWithSession(selected, session)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Resume Scan")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isLoading)
                } else {
                    Button {
                        navigationTarget = .device(selected)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Start Scanning")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isLoading)
                }
            } else {
                Button {
                    // Disabled state
                } label: {
                    HStack(spacing: 4) {
                        Text("Start Scanning")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var helperStatusPill: some View {
        Text(helperStatusLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(helperAccentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(helperAccentColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var helperStatusLabel: String {
        switch viewModel.helperStatus {
        case .installed:
            "Installed"
        case .notInstalled:
            "Not Installed"
        case .updateRequired:
            "Mismatch Detected"
        }
    }

    private var helperSymbolName: String {
        switch viewModel.helperStatus {
        case .installed:
            "checkmark.shield.fill"
        case .notInstalled:
            "lock.shield.fill"
        case .updateRequired:
            "exclamationmark.triangle.fill"
        }
    }

    private var helperAccentColor: Color {
        switch viewModel.helperStatus {
        case .installed:
            .green
        case .notInstalled:
            .orange
        case .updateRequired:
            .orange
        }
    }
}

// MARK: - Preview

#Preview {
    DeviceSelectionView()
}
