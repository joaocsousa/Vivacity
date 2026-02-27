import Foundation

// MARK: - Scan Source

/// Identifies which scan phase discovered a file.
enum ScanSource: String, Sendable, Codable {
    case fastScan = "Fast"
    case deepScan = "Deep"
}

// MARK: - Scan Event

/// Stream element emitted by scan services.
enum ScanEvent: Sendable {
    /// A recoverable file was found.
    case fileFound(RecoverableFile)
    /// Scan progress updated (0–1).
    case progress(Double)
    /// The scan phase completed.
    case completed
}

// MARK: - Recoverable File

/// A file on disk that can potentially be recovered.
struct RecoverableFile: Identifiable, Hashable, Sendable, Codable {
    /// Unique identifier for this file.
    let id: UUID

    /// Original or generated file name (without extension).
    let fileName: String

    /// File extension (e.g. "jpg", "mp4").
    let fileExtension: String

    /// Broad category: image or video.
    let fileType: FileCategory

    /// Size of the file in bytes (estimated or exact).
    let sizeInBytes: Int64

    /// Byte offset on the source device where the file data begins.
    let offsetOnDisk: UInt64

    /// The signature that matched this file.
    let signatureMatch: FileSignature

    /// Which scan phase found this file.
    let source: ScanSource

    /// The original file path on the volume, if discovered via filesystem scan.
    var filePath: String? = nil

    // MARK: - Computed

    /// Human-readable file size string (e.g. "3.2 MB").
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    /// Full file name with extension (e.g. "IMG_2847.jpg").
    var fullFileName: String {
        "\(fileName).\(fileExtension)"
    }
}
