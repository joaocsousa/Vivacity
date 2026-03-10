import SwiftUI

struct ScanAccessInterruptionView: View {
    let state: ScanAccessState
    let message: String?
    let onCreateImage: (() -> Void)?
    let onLoadImage: (() -> Void)?
    let onContinueLimited: (() -> Void)?
    let onTryAgain: (() -> Void)?

    private var title: String {
        switch state {
        case .fullScan:
            "Ready to Scan"
        case .helperInstallRequired:
            "Install the Recovery Helper First"
        case .imageRecommended:
            "Image-First Recovery Recommended"
        case .imageRequired:
            "Startup Disk Needs an Offline Image"
        case .limitedOnly:
            "Limited Scan Ready"
        }
    }

    private var symbolName: String {
        switch state {
        case .fullScan:
            "checkmark.circle.fill"
        case .helperInstallRequired:
            "lock.shield.fill"
        case .imageRecommended:
            "opticaldiscdrive.fill"
        case .imageRequired:
            "internaldrive.fill"
        case .limitedOnly:
            "doc.text.magnifyingglass"
        }
    }

    private var tint: Color {
        switch state {
        case .fullScan:
            .green
        case .helperInstallRequired:
            .orange
        case .imageRecommended:
            .blue
        case .imageRequired:
            .red
        case .limitedOnly:
            .secondary
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: symbolName)
                .font(.system(size: 56))
                .foregroundStyle(tint.opacity(0.8))

            Text(title)
                .font(.system(size: 24, weight: .bold))

            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 12) {
                if let onCreateImage {
                    Button("Create Image…", action: onCreateImage)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                if let onLoadImage {
                    Button("Load Existing Image…", action: onLoadImage)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                if let onTryAgain {
                    Button("Try Again", action: onTryAgain)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                if let onContinueLimited {
                    Button("Continue Limited Scan", action: onContinueLimited)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
