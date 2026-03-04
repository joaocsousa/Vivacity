import Foundation

/// Utility to extract creation dates from image files by scanning for EXIF date strings.
///
/// Rather than implementing a full TIFF/EXIF parser, this uses a fast heuristic
/// to find the "YYYY:MM:DD HH:MM:SS" string that standard EXIF uses for
/// `DateTimeOriginal` (0x9003) or `DateTimeDigitized` (0x9004).
struct EXIFDateExtractor: Sendable {
    struct CaptureMetadata: Sendable {
        let captureDate: Date?
        let timeZoneOffsetMinutes: Int?
        let deviceModel: String?

        /// Filename-safe token like "20241123_184501+0200" (offset included when known).
        var captureTimeToken: String? {
            guard let captureDate else { return nil }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"

            if let timeZoneOffsetMinutes {
                formatter.timeZone = TimeZone(secondsFromGMT: timeZoneOffsetMinutes * 60)
                let offset = formatOffset(minutes: timeZoneOffsetMinutes)
                return "\(formatter.string(from: captureDate))\(offset)"
            }

            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: captureDate)
        }

        /// Device token normalized for filenames (alphanumerics only).
        var deviceToken: String? {
            guard let deviceModel else { return nil }
            let filtered = deviceModel.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
            let token = String(String.UnicodeScalarView(filtered))
            return token.isEmpty ? nil : String(token.prefix(24))
        }

        private func formatOffset(minutes: Int) -> String {
            let sign = minutes >= 0 ? "+" : "-"
            let absoluteMinutes = abs(minutes)
            let hours = absoluteMinutes / 60
            let remainingMinutes = absoluteMinutes % 60
            return String(format: "%@%02d%02d", sign, hours, remainingMinutes)
        }
    }

    /// Scans a byte buffer for an EXIF date string and returns a formatted filename prefix.
    ///
    /// - Parameter buffer: The file data (typically the first few KB where EXIF lives)
    /// - Returns: A string like "Photo_2023-10-25_143000", or nil if no date is found.
    static func extractFilenamePrefix(from buffer: [UInt8], maxBytes: Int = 65536) -> String? {
        guard
            let metadata = extractMetadata(from: buffer, maxBytes: maxBytes),
            let captureDate = metadata.captureDate
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        if let offset = metadata.timeZoneOffsetMinutes {
            formatter.timeZone = TimeZone(secondsFromGMT: offset * 60)
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        }
        return "Photo_\(formatter.string(from: captureDate))"
    }

    /// Extracts capture timestamp and device hints from partial media bytes.
    ///
    /// For image data this prefers EXIF-style date strings and camera markers.
    /// For MOV/MP4 data it also attempts QuickTime metadata extraction, including
    /// `mvhd` creation times from partial atom streams.
    static func extractMetadata(from buffer: [UInt8], maxBytes: Int = 131_072) -> CaptureMetadata? {
        let sampleEnd = min(buffer.count, maxBytes)
        guard sampleEnd > 0 else { return nil }
        let sample = Array(buffer.prefix(sampleEnd))

        let exifDate = extractEXIFDate(from: sample)
        let quickTimeDate = extractQuickTimeDate(from: sample)
        let device = extractDeviceModel(from: sample)

        let captureDate = exifDate?.date ?? quickTimeDate?.date
        let timeZoneOffsetMinutes = exifDate?.offsetMinutes ?? quickTimeDate?.offsetMinutes

        if captureDate == nil, device == nil {
            return nil
        }

        return CaptureMetadata(
            captureDate: captureDate,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes,
            deviceModel: device
        )
    }

    private static func extractEXIFDate(from buffer: [UInt8]) -> (date: Date, offsetMinutes: Int?)? {
        guard buffer.count >= 19 else { return nil }

        for i in 0 ..< (buffer.count - 18) {
            guard matchesEXIFDatePrefix(buffer, start: i) else { continue }
            guard
                let year = parseInt(buffer, start: i, count: 4),
                let month = parseInt(buffer, start: i + 5, count: 2),
                let day = parseInt(buffer, start: i + 8, count: 2),
                let hour = parseInt(buffer, start: i + 11, count: 2),
                let minute = parseInt(buffer, start: i + 14, count: 2),
                let second = parseInt(buffer, start: i + 17, count: 2)
            else {
                continue
            }

            let optionalOffset = parseTimeZoneOffset(buffer, start: i + 19)
            let timeZone = TimeZone(secondsFromGMT: (optionalOffset ?? 0) * 60)
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            components.timeZone = timeZone
            components.calendar = Calendar(identifier: .gregorian)

            if let date = components.date {
                return (date, optionalOffset)
            }
        }

        return nil
    }

    private static func matchesEXIFDatePrefix(_ buffer: [UInt8], start: Int) -> Bool {
        let colon = UInt8(ascii: ":")
        let space = UInt8(ascii: " ")

        guard
            buffer[start + 4] == colon,
            buffer[start + 7] == colon,
            buffer[start + 10] == space,
            buffer[start + 13] == colon,
            buffer[start + 16] == colon
        else {
            return false
        }

        for j in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
            let b = buffer[start + j]
            if b < 0x30 || b > 0x39 {
                return false
            }
        }

        return true
    }

    private static func parseTimeZoneOffset(_ buffer: [UInt8], start: Int) -> Int? {
        guard start + 5 < buffer.count else { return nil }
        let signByte = buffer[start]
        guard signByte == UInt8(ascii: "+") || signByte == UInt8(ascii: "-") else { return nil }
        guard
            let hours = parseInt(buffer, start: start + 1, count: 2),
            buffer[start + 3] == UInt8(ascii: ":"),
            let minutes = parseInt(buffer, start: start + 4, count: 2)
        else {
            return nil
        }

        let total = hours * 60 + minutes
        return signByte == UInt8(ascii: "-") ? -total : total
    }

    private static func parseInt(_ bytes: [UInt8], start: Int, count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var value = 0
        for idx in start ..< start + count {
            let byte = bytes[idx]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = (value * 10) + Int(byte - 0x30)
        }
        return value
    }

    private static func extractQuickTimeDate(from buffer: [UInt8]) -> (date: Date, offsetMinutes: Int?)? {
        if let fromMVHD = extractMVHDCreationDate(from: buffer) {
            return (fromMVHD, 0)
        }
        return extractISO8601Date(from: buffer)
    }

    private static func extractMVHDCreationDate(from buffer: [UInt8]) -> Date? {
        let marker: [UInt8] = [0x6D, 0x76, 0x68, 0x64] // "mvhd"
        let epochDelta: TimeInterval = 2_082_844_800 // 1904 -> 1970

        guard buffer.count >= 16 else { return nil }
        for i in 0 ..< (buffer.count - marker.count) {
            guard Array(buffer[i ..< i + marker.count]) == marker else { continue }
            let versionIndex = i + 4
            guard versionIndex < buffer.count else { continue }
            let version = buffer[versionIndex]

            if version == 0, i + 12 <= buffer.count {
                let raw = readBigEndianUInt32(buffer, offset: i + 8)
                return Date(timeIntervalSince1970: TimeInterval(raw) - epochDelta)
            }

            if version == 1, i + 16 <= buffer.count {
                let raw = readBigEndianUInt64(buffer, offset: i + 8)
                return Date(timeIntervalSince1970: TimeInterval(raw) - epochDelta)
            }
        }

        return nil
    }

    private static func extractISO8601Date(from buffer: [UInt8]) -> (date: Date, offsetMinutes: Int?)? {
        guard let text = String(bytes: buffer, encoding: .isoLatin1) else { return nil }
        let chars = Array(text)
        guard chars.count >= 20 else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for i in 0 ..< (chars.count - 19) {
            guard matchesISO8601Prefix(chars, start: i) else { continue }

            let maxLen = min(chars.count - i, 25)
            for length in [25, 24, 20] where length <= maxLen {
                let candidate = String(chars[i ..< i + length])
                if let date = formatter.date(from: candidate) {
                    let offset = parseISO8601Offset(candidate)
                    return (date, offset)
                }
            }
        }

        return nil
    }

    private static func matchesISO8601Prefix(_ chars: [Character], start: Int) -> Bool {
        guard start + 19 < chars.count else { return false }
        let expectedSeparators: [Int: Character] = [4: "-", 7: "-", 10: "T", 13: ":", 16: ":"]

        for (offset, separator) in expectedSeparators where chars[start + offset] != separator {
            return false
        }

        let digitOffsets = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        for offset in digitOffsets where chars[start + offset].wholeNumberValue == nil {
            return false
        }
        return true
    }

    private static func parseISO8601Offset(_ iso: String) -> Int? {
        if iso.hasSuffix("Z") {
            return 0
        }
        guard iso.count >= 6 else { return nil }
        let tail = iso.suffix(6)
        let sign = tail.first
        guard sign == "+" || sign == "-" else { return nil }
        let chars = Array(tail)
        guard
            let hours = Int(String(chars[1 ... 2])),
            chars[3] == ":",
            let minutes = Int(String(chars[4 ... 5]))
        else {
            return nil
        }

        let total = hours * 60 + minutes
        return sign == "-" ? -total : total
    }

    private static func readBigEndianUInt32(_ buffer: [UInt8], offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0 ..< 4 {
            value = (value << 8) | UInt32(buffer[offset + index])
        }
        return value
    }

    private static func readBigEndianUInt64(_ buffer: [UInt8], offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(buffer[offset + index])
        }
        return value
    }

    private static func extractDeviceModel(from buffer: [UInt8]) -> String? {
        guard let text = String(bytes: buffer, encoding: .isoLatin1)?.lowercased() else { return nil }

        let markers = [
            "canon", "nikon", "sony", "fujifilm", "panasonic", "olympus",
            "gopro", "dji", "apple", "samsung", "blackmagic",
        ]

        guard let match = markers.first(where: { text.contains($0) }) else { return nil }
        switch match {
        case "gopro":
            return "GoPro"
        case "dji":
            return "DJI"
        default:
            return match.capitalized
        }
    }
}
