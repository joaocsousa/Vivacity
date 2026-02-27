import SwiftUI

/// Screen that lists all available storage devices and lets the user select one to scan.
struct DeviceSelectionView: View {
    @State private var viewModel = AppEnvironment.makeDeviceSelectionViewModel()
    @State private var navigationTarget: NavigationDestination?

    enum NavigationDestination: Hashable {
        case device(StorageDevice)
        case deviceWithSession(StorageDevice, ScanSession)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
            await viewModel.loadDevices()
        }
        .task {
            await viewModel.observeVolumeChanges()
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
    }
}

// MARK: - Subviews

extension DeviceSelectionView {
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
                .padding(.bottom, 16)
        }
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
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.imageCreationProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 200)

                        Text("Creating Byte-to-Byte Disk Image...")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("\(Int(viewModel.imageCreationProgress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
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
                Task { await viewModel.loadDevices() }
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
                    viewModel.loadDiskImage(at: url)
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

                if let session = viewModel.savedSessions[selected.id] {
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
}

// MARK: - Preview

#Preview {
    DeviceSelectionView()
}
