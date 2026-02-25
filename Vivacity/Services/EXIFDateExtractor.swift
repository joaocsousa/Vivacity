import Foundation

/// Utility to extract creation dates from image files by scanning for EXIF date strings.
///
/// Rather than implementing a full TIFF/EXIF parser, this uses a fast heuristic
/// to find the "YYYY:MM:DD HH:MM:SS" string that standard EXIF uses for
/// `DateTimeOriginal` (0x9003) or `DateTimeDigitized` (0x9004).
struct EXIFDateExtractor: Sendable {
    
    /// Scans a byte buffer for an EXIF date string and returns a formatted filename prefix.
    ///
    /// - Parameter buffer: The file data (typically the first few KB where EXIF lives)
    /// - Returns: A string like "Photo_2023-10-25_143000", or nil if no date is found.
    static func extractFilenamePrefix(from buffer: [UInt8], maxBytes: Int = 65536) -> String? {
        // We only need to check the first chunk (EXIF is always near the start)
        let end = min(buffer.count, maxBytes)
        guard end >= 19 else { return nil }
        
        // Look for pattern "YYYY:MM:DD HH:MM:SS" (19 bytes)
        // Ascii digits are 0x30 to 0x39. ':' is 0x3A. ' ' is 0x20.
        
        let colon = UInt8(ascii: ":")
        let space = UInt8(ascii: " ")
        
        for i in 0..<(end - 19) {
            // Fast check: look for the colons and space in the right places
            if buffer[i + 4] == colon &&
               buffer[i + 7] == colon &&
               buffer[i + 10] == space &&
               buffer[i + 13] == colon &&
               buffer[i + 16] == colon {
                
                // Verify all other characters are digits
                var isValid = true
                for j in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
                    let b = buffer[i + j]
                    if b < 0x30 || b > 0x39 {
                        isValid = false
                        break
                    }
                }
                
                if isValid {
                    // Extract the string and format it
                    let chars = buffer[i..<i+19]
                    if let dateString = String(bytes: chars, encoding: .ascii) {
                        // "2023:10:25 14:30:00" -> "Photo_2023-10-25_143000"
                        let parts = dateString.split(separator: " ")
                        if parts.count == 2 {
                            let datePart = parts[0].replacingOccurrences(of: ":", with: "-")
                            let timePart = parts[1].replacingOccurrences(of: ":", with: "")
                            return "Photo_\(datePart)_\(timePart)"
                        }
                    }
                }
            }
        }
        
        return nil
    }
}
