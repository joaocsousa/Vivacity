import SwiftUI

/// Screen for selecting a destination and starting file recovery.
struct RecoveryDestinationView: View {
    let scannedDevice: StorageDevice
    let selectedFiles: [RecoverableFile]

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RecoveryDestinationViewModel

    init(scannedDevice: StorageDevice, selectedFiles: [RecoverableFile]) {
        self.scannedDevice = scannedDevice
        self.selectedFiles = selectedFiles
        _viewModel = State(
            initialValue: RecoveryDestinationViewModel(
                scannedDevice: scannedDevice,
                selectedFiles: selectedFiles
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.didCompleteRecovery {
                completionPlaceholder
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    destinationSection
                    spaceSection
                    warningsSection
                    Spacer()
                    footer
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            viewModel.updateAvailableSpace()
        }
        .alert(
            "Recovery Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
        )
    }
}

extension RecoveryDestinationView {
    private var completionPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)

            Text("Recovery Complete")
                .font(.system(size: 22, weight: .semibold))

            Text("Recovered \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s").")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose Recovery Destination")
                .font(.system(size: 21, weight: .semibold))

            Text(
                "Recovering \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s") " +
                    "from \(scannedDevice.name)"
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.system(size: 13, weight: .semibold))

            Button {
                viewModel.selectDestination()
            } label: {
                Label("Choose Destination…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRecovering)

            if let destinationURL = viewModel.destinationURL {
                Text(destinationURL.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else {
                Text("No destination selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var spaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage Check")
                .font(.system(size: 13, weight: .semibold))

            infoRow(title: "Space needed", value: formatBytes(viewModel.requiredSpace))
            infoRow(title: "Space available", value: formatBytes(viewModel.availableSpace))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var warningsSection: some View {
        if viewModel.isDestinationOnScannedDevice {
            warningRow(
                icon: "exclamationmark.triangle.fill",
                message: "Destination is on the scanned device. " +
                    "Choose a different volume to avoid overwriting recoverable data."
            )
        } else if viewModel.destinationURL != nil, viewModel.availableSpace < viewModel.requiredSpace {
            warningRow(
                icon: "externaldrive.badge.exclamationmark",
                message: "Not enough free space in the selected destination."
            )
        } else if viewModel.destinationURL != nil {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Destination looks valid and has enough free space.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isRecovering {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Recovering files…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRecovering)

                Spacer()

                Button {
                    Task {
                        await viewModel.startRecovery()
                    }
                } label: {
                    Text("Start Recovery")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasEnoughSpace || viewModel.isRecovering)
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func warningRow(icon: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    RecoveryDestinationView(
        scannedDevice: StorageDevice(
            id: "preview-disk",
            name: "Samsung T7",
            volumePath: URL(fileURLWithPath: "/Volumes/Source"),
            volumeUUID: "SOURCE-UUID",
            filesystemType: .exfat,
            isExternal: true,
            partitionOffset: nil,
            partitionSize: nil,
            totalCapacity: 1_000_000_000_000,
            availableCapacity: 700_000_000_000
        ),
        selectedFiles: [
            RecoverableFile(
                id: UUID(),
                fileName: "IMG_1001",
                fileExtension: "jpg",
                fileType: .image,
                sizeInBytes: 2_500_000,
                offsetOnDisk: 0,
                signatureMatch: .jpeg,
                source: .fastScan
            ),
        ]
    )
}
