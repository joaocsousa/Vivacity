import SwiftUI

/// Screen that lists all available storage devices and lets the user select one to scan.
struct DeviceSelectionView: View {
    @State private var viewModel = AppEnvironment.makeDeviceSelectionViewModel()
    @State private var navigationTarget: StorageDevice?

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
        .navigationDestination(item: $navigationTarget) { device in
            FileScanView(device: device)
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
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Spacer()

            // Selection count
            if viewModel.selectedDevice != nil {
                Text("1 device selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                navigationTarget = viewModel.selectedDevice
            } label: {
                HStack(spacing: 4) {
                    Text("Start Scanning")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.selectedDevice == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview {
    DeviceSelectionView()
}
