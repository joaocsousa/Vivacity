import Foundation

// MARK: - File Category

/// Broad category of a recoverable file.
enum FileCategory: String, Sendable, CaseIterable, Codable {
    case image
    case video
}

// MARK: - File Signature

/// A known file signature (magic bytes + extension) used to identify recoverable files.
///
/// Each case carries a file extension, the starting magic-byte sequence, and the broad
/// category (image or video). Used by both `FastScanService` and `DeepScanService`.
enum FileSignature: String, Sendable, CaseIterable, Codable {
    // Images
    case jpeg
    case png
    case heic
    case heif
    case tiff
    case tiffBigEndian
    case bmp
    case gif
    case webp
    case cr2
    case nef
    case arw
    case dng

    // Videos
    case mp4
    case mov
    case avi
    case mkv
    case m4v
    case wmv
    case flv
    case threeGP

    // MARK: - Properties

    /// The file extension (without leading dot).
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .heif: "heif"
        case .tiff: "tiff"
        case .tiffBigEndian: "tiff"
        case .bmp: "bmp"
        case .gif: "gif"
        case .webp: "webp"
        case .cr2: "cr2"
        case .nef: "nef"
        case .arw: "arw"
        case .dng: "dng"
        case .mp4: "mp4"
        case .mov: "mov"
        case .avi: "avi"
        case .mkv: "mkv"
        case .m4v: "m4v"
        case .wmv: "wmv"
        case .flv: "flv"
        case .threeGP: "3gp"
        }
    }

    /// The magic-byte signature found at the start of the file.
    ///
    /// Some formats (HEIC, MOV, MP4, M4V, 3GP) share the `ftyp` box at offset 4;
    /// we match the common prefix here and refine by the brand string when needed.
    var magicBytes: [UInt8] {
        switch self {
        case .jpeg: [0xFF, 0xD8, 0xFF]
        case .png: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        case .heic: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "heic"
        case .heif: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "mif1"
        case .tiff: [0x49, 0x49, 0x2A, 0x00] // Little-endian
        case .tiffBigEndian: [0x4D, 0x4D, 0x00, 0x2A] // Big-endian
        case .bmp: [0x42, 0x4D]
        case .gif: [0x47, 0x49, 0x46, 0x38]
        case .webp: [0x52, 0x49, 0x46, 0x46] // "RIFF", followed by "WEBP" at offset 8
        case .cr2: [0x49, 0x49, 0x2A, 0x00] // Same TIFF header; CR2 has "CR" at offset 8
        case .nef: [0x4D, 0x4D, 0x00, 0x2A] // Big-endian TIFF; Nikon-specific IFD
        case .arw: [0x49, 0x49, 0x2A, 0x00] // TIFF-based; Sony-specific
        case .dng: [0x49, 0x49, 0x2A, 0x00] // TIFF-based; Adobe DNG
        case .mp4: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "isom"/"mp4"
        case .mov: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "qt  "
        case .avi: [0x52, 0x49, 0x46, 0x46] // "RIFF", followed by "AVI " at offset 8
        case .mkv: [0x1A, 0x45, 0xDF, 0xA3]
        case .m4v: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "M4V "
        case .wmv: [0x30, 0x26, 0xB2, 0x75]
        case .flv: [0x46, 0x4C, 0x56, 0x01]
        case .threeGP: [0x00, 0x00, 0x00] // ftyp at offset 4; brand "3gp"
        }
    }

    /// Whether this is an image or a video format.
    var category: FileCategory {
        switch self {
        case .jpeg, .png, .heic, .heif, .tiff, .tiffBigEndian,
             .bmp, .gif, .webp, .cr2, .nef, .arw, .dng:
            .image
        case .mp4, .mov, .avi, .mkv, .m4v, .wmv, .flv, .threeGP:
            .video
        }
    }

    // MARK: - Lookup

    /// All known file extensions mapped to their signatures.
    static let extensionMap: [String: FileSignature] = {
        var map: [String: FileSignature] = [:]
        for sig in FileSignature.allCases {
            map[sig.fileExtension] = sig
        }
        return map
    }()

    /// Returns the matching signature for a given file extension (case-insensitive).
    static func from(extension ext: String) -> FileSignature? {
        extensionMap[ext.lowercased()]
    }
}
