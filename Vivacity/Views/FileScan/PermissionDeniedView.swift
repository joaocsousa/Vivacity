import SwiftUI

/// Fallback view shown when the user cancels the macOS password dialog.
///
/// Explains why disk access is needed and offers two options:
/// - "Try Again" — re-prompts the AuthorizationServices password dialog
/// - "Continue with limited scan" — proceeds with Trash-only scanning
struct PermissionDeniedView: View {
    let onTryAgain: () -> Void
    let onContinueLimited: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Shield icon
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.7))
                .padding(.bottom, 4)

            // Title
            Text("Disk Access Needed")
                .font(.system(size: 22, weight: .bold))

            // Explanation
            VStack(spacing: 8) {
                Text("Vivacity needs disk access to read raw sectors for deep file recovery.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Without disk access, scanning will be limited to files found in the Trash.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 400)

            // Try Again button
            Button {
                onTryAgain()
            } label: {
                Text("Try Again")
                    .font(.system(size: 14, weight: .medium))
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            // Continue with limited scan
            Button {
                onContinueLimited()
            } label: {
                Text("Continue with limited scan")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
