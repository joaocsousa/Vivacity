import SwiftUI

/// Screen that lists all available storage devices and lets the user select one to scan.
struct DeviceSelectionView: View {

    @State private var viewModel = DeviceSelectionViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deviceList
            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 520)
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

private extension DeviceSelectionView {

    var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            Text("Select a Device")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose a storage device to scan for recoverable files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
    }

    var deviceList: some View {
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
                    LazyVStack(spacing: 4) {
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
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack {
            Button {
                Task { await viewModel.loadDevices() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                // TODO: Navigate to scan screen (T-017)
            } label: {
                Label("Start Scanning", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.selectedDevice == nil)
        }
        .padding(16)
    }
}

// MARK: - Preview

#Preview {
    DeviceSelectionView()
}
