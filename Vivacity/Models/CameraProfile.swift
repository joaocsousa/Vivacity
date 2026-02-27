import Foundation

/// A profile identifying the source camera or device based on directory structures or file metadata.
///
/// Many proprietary camera formats (like RAW images) use common container formats (like TIFF).
/// Identifying the `CameraProfile` allows the `DeepScanService` to accurately "promote" generic
/// signatures into their specific proprietary formats, and to generate camera-appropriate default filenames.
enum CameraProfile: String, Sendable, CaseIterable, Codable {
    /// GoPro action cameras (e.g., HERO series).
    case goPro
    /// Canon digital cameras (e.g., EOS series).
    case canon
    /// Sony digital cameras (e.g., Alpha series).
    case sony
    /// DJI drones and action cameras.
    case dji
    /// Generic or unrecognized camera profile.
    case generic

    // MARK: - Properties

    /// Typical directory names associated with this camera profile.
    ///
    /// The `CameraRecoveryService` scans the paths of files found by the `FastScanService`
    /// to look for these directories, which strongly suggest the volume was used in this camera.
    var directoryClues: [String] {
        switch self {
        case .goPro:
            ["100GOPRO"]
        case .canon:
            ["100CANON", "EOSMISC"]
        case .sony:
            ["100MSDCF", "MP_ROOT", "AVF_INFO"]
        case .dji:
            ["100MEDIA"]
        case .generic:
            []
        }
    }

    /// The default prefix to use when generating filenames if EXIF dates cannot be extracted.
    var defaultFilePrefix: String {
        switch self {
        case .goPro:
            "GOPR"
        case .canon:
            "IMG_"
        case .sony:
            "DSC0"
        case .dji:
            "DJI_"
        case .generic:
            "recovered_"
        }
    }
}
