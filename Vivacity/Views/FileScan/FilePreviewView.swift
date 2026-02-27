import AVKit
import QuickLook
import SwiftUI

/// Preview panel that displays a selected file's content.
///
/// Shows thumbnails for images, video players for video files, and a
/// placeholder for files that cannot be previewed.
struct FilePreviewView: View {
    let file: RecoverableFile?
    let device: StorageDevice

    @State private var previewURL: URL?
    @State private var isExtracting = false
    @State private var previewService = LivePreviewService()

    var body: some View {
        Group {
            if let file {
                previewContent(for: file)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task(id: file?.id) {
            await loadPreviewURL()
        }
    }

    private func loadPreviewURL() async {
        guard let file else {
            previewURL = nil
            isExtracting = false
            return
        }

        isExtracting = true
        defer { isExtracting = false }

        // Fast Scan files that still exist at offset 0
        if file.source == .fastScan, file.offsetOnDisk == 0 {
            previewURL = resolveFileURL(for: file)
            return
        }

        // Deep Scan files
        if file.source == .deepScan {
            do {
                let volumeInfo = VolumeInfo.detect(for: device)
                let reader = PrivilegedDiskReader(devicePath: volumeInfo.devicePath)
                try reader.start()
                defer { reader.stop() }

                previewURL = try await previewService.generatePreviewURL(for: file, reader: reader)
            } catch {
                print("Failed to extract preview: \(error)")
                previewURL = nil
            }
        } else {
            previewURL = nil
        }
    }
}

// MARK: - Preview Content

extension FilePreviewView {
    private func previewContent(for file: RecoverableFile) -> some View {
        VStack(spacing: 16) {
            // Preview area
            previewMedia(for: file)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // File info bar
            fileInfoBar(for: file)
        }
        .padding(16)
    }

    @ViewBuilder
    private func previewMedia(for file: RecoverableFile) -> some View {
        if isExtracting {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Extracting file for preview...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = previewURL, FileManager.default.isReadableFile(atPath: url.path) {
            switch file.fileType {
            case .image:
                AsyncImagePreview(url: url)

            case .video:
                VideoPlayerPreview(url: url)
            }
        } else {
            // File not directly accessible or extraction failed
            unavailablePreview(for: file)
        }
    }

    private func unavailablePreview(for file: RecoverableFile) -> some View {
        VStack(spacing: 12) {
            Image(systemName: file.fileType == .image ? "photo" : "film")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(file.fullFileName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Preview unavailable — file might be severely fragmented")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if file.source == .deepScan {
                Label("Found by deep scan at offset \(formatOffset(file.offsetOnDisk))", systemImage: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("Select a file to preview")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
    }

    private func fileInfoBar(for file: RecoverableFile) -> some View {
        HStack(spacing: 16) {
            // File type icon
            Image(systemName: file.fileType == .image ? "photo.fill" : "film.fill")
                .font(.system(size: 14))
                .foregroundStyle(file.fileType == .image ? .blue : .purple)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fullFileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(file.sizeFormatted)
                    Text("•")
                    Text(file.signatureMatch.fileExtension.uppercased())
                    Text("•")
                    Text(file.source == .fastScan ? "Fast Scan" : "Deep Scan")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.unemphasizedSelectedContentBackgroundColor))
        )
    }

    // MARK: - Helpers

    /// Attempts to resolve a URL on the volume where this file might exist.
    private func resolveFileURL(for file: RecoverableFile) -> URL? {
        // For fast-scan files that were found via FileManager, the file is
        // still at its original location — try to find it by name on the volume.
        guard file.source == .fastScan, file.offsetOnDisk == 0 else { return nil }

        // Walk the volume looking for this specific file
        let fm = FileManager.default
        let volumeRoot = device.volumePath

        guard let enumerator = fm.enumerator(
            at: volumeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }

        let searchName = file.fullFileName.lowercased()
        for case let url as URL in enumerator {
            if url.lastPathComponent.lowercased() == searchName {
                return url
            }
        }

        return nil
    }

    private func formatOffset(_ offset: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(offset))
    }
}

// MARK: - Async Image Preview

/// Loads and displays an image file asynchronously.
private struct AsyncImagePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = await loadImage(from: url)
        }
    }

    private func loadImage(from url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: url)
                continuation.resume(returning: img)
            }
        }
    }
}

// MARK: - Video Player Preview

/// Displays a video file with playback controls.
private struct VideoPlayerPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Preview

#Preview {
    FilePreviewView(
        file: RecoverableFile(
            id: UUID(),
            fileName: "IMG_4032",
            fileExtension: "jpg",
            fileType: .image,
            sizeInBytes: 3_450_000,
            offsetOnDisk: 0,
            signatureMatch: .jpeg,
            source: .fastScan
        ),
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
    .frame(width: 400, height: 500)
}
