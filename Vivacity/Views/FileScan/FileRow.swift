import SwiftUI

/// A single row in the file list showing checkbox, icon, name, scan badge, and size.
///
/// Design matches the Stitch screens — blue checkboxes, file-type icons,
/// "FAST"/"DEEP" pill badges, and right-aligned size text.
struct FileRow: View {
    let file: RecoverableFile
    let isSelected: Bool
    let isPreviewSelected: Bool
    let onToggle: () -> Void
    let onSelectForPreview: () -> Void

    var body: some View {
        // Container layout
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Checkbox
                Button(action: onToggle) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.blue : Color.white.opacity(0.08))
                            .frame(width: 20, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        isSelected ? Color.blue : Color.white.opacity(0.2),
                                        lineWidth: 1
                                    )
                            )

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)

                // File type icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconBackgroundColor)
                        .frame(width: 32, height: 32)

                    Image(systemName: iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                }

                // File name
                Text(file.fullFileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Source badge
                Text(file.source.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(badgeColor.opacity(0.15))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())

                Spacer()

                // File size
                Text(file.sizeFormatted)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .background(isPreviewSelected ? Color.blue.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelectForPreview() }
    }

    // MARK: - Computed Styles

    private var iconName: String {
        switch file.fileType {
        case .image: "photo.fill"
        case .video: "video.fill"
        }
    }

    private var iconColor: Color {
        switch file.fileType {
        case .image: .blue
        case .video: .purple
        }
    }

    private var iconBackgroundColor: Color {
        iconColor.opacity(0.12)
    }

    private var badgeColor: Color {
        file.source == .fastScan ? .blue : .purple
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        FileRow(
            file: RecoverableFile(
                id: UUID(),
                fileName: "IMG_2847",
                fileExtension: "jpg",
                fileType: .image,
                sizeInBytes: 3_200_000,
                offsetOnDisk: 0,
                signatureMatch: .jpeg,
                source: .fastScan
            ),
            isSelected: true,
            isPreviewSelected: true,
            onToggle: {},
            onSelectForPreview: {}
        )
        Divider().opacity(0.3)
        FileRow(
            file: RecoverableFile(
                id: UUID(),
                fileName: "birthday_party",
                fileExtension: "mov",
                fileType: .video,
                sizeInBytes: 245_800_000,
                offsetOnDisk: 65536,
                signatureMatch: .mov,
                source: .deepScan
            ),
            isSelected: false,
            isPreviewSelected: false,
            onToggle: {},
            onSelectForPreview: {}
        )
    }
    .background(Color(.controlBackgroundColor))
    .frame(width: 500)
}
