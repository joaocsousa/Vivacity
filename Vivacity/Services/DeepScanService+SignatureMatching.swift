import Foundation

extension DeepScanService {
    private static let directSignatures: [(FileSignature, [UInt8])] = {
        let unambiguous: [FileSignature] = [
            .jpeg, .png, .bmp, .gif, .mkv, .wmv, .flv, .raf, .rw2,
        ]
        return unambiguous.map { ($0, $0.magicBytes) }
    }()

    // MARK: - Signature Matching

    /// Checks the buffer at the given position for any known file signature.
    func matchSignatureAt(buffer: [UInt8], position: Int, cameraProfile: CameraProfile) -> FileSignature? {
        let remaining = buffer.count - position
        guard remaining >= 4 else { return nil }

        if let direct = matchDirectSignatures(buffer: buffer, position: position, remaining: remaining) {
            return direct
        }

        if let tiff = matchTIFFSignatures(
            buffer: buffer,
            position: position,
            remaining: remaining,
            cameraProfile: cameraProfile
        ) {
            return tiff
        }

        if let riff = matchRIFFSignatures(buffer: buffer, position: position, remaining: remaining) {
            return riff
        }

        if let ftyp = matchFtypSignatures(buffer: buffer, position: position, remaining: remaining) {
            return ftyp
        }

        if let movAtom = matchMOVAtomSignatures(buffer: buffer, position: position, remaining: remaining) {
            return movAtom
        }

        return nil
    }

    func matchDirectSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        for (signature, magic) in Self.directSignatures {
            if remaining >= magic.count {
                var matched = true
                for index in 0 ..< magic.count {
                    if buffer[position + index] != magic[index] {
                        matched = false
                        break
                    }
                }
                if matched { return signature }
            }
        }
        return nil
    }

    func matchTIFFSignatures(
        buffer: [UInt8],
        position: Int,
        remaining: Int,
        cameraProfile: CameraProfile
    ) -> FileSignature? {
        if remaining >= 4,
           buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x55, buffer[position + 3] == 0x00
        {
            return .rw2
        }

        if buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x2A, buffer[position + 3] == 0x00
        {
            if remaining >= 10, buffer[position + 8] == 0x43, buffer[position + 9] == 0x52 {
                return .cr2
            }

            let ifdCheckLength = min(remaining, 65536)
            let headerSlice = Array(buffer[position ..< position + ifdCheckLength])
            let tiffParser = TIFFHeaderParser()
            if let rawSignature = tiffParser.identifyRAWSignature(from: headerSlice) {
                return rawSignature
            }

            switch cameraProfile {
            case .sony:
                return .arw
            case .dji:
                return .dng
            default:
                return .tiff
            }
        }

        if buffer[position] == 0x4D, buffer[position + 1] == 0x4D,
           buffer[position + 2] == 0x00, buffer[position + 3] == 0x2A
        {
            return .tiffBigEndian
        }
        return nil
    }

    func matchRIFFSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12,
           buffer[position] == 0x52, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x46, buffer[position + 3] == 0x46
        {
            let subType = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
            if subType == "AVI " { return .avi }
            if subType == "WEBP" { return .webp }
        }
        return nil
    }

    func matchFtypSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12 {
            let ftypMarker = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
            if ftypMarker == "ftyp" {
                let brand = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
                switch brand.trimmingCharacters(in: .whitespaces).lowercased() {
                case "isom", "iso2", "mp41", "mp42", "avc1":
                    return .mp4
                case "qt", "qt  ", "wide":
                    return .mov
                case "heic", "heix":
                    return .heic
                case "mif1":
                    return .heif
                case "avif", "avis":
                    return .avif
                case "cr3", "crx":
                    return .cr3
                case "m4v":
                    return .m4v
                case "3gp4", "3gp5", "3gp6", "3ge6":
                    return .threeGP
                default:
                    return .mp4
                }
            }
        }
        return nil
    }

    func matchMOVAtomSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        guard remaining >= 16 else { return nil }
        let firstType = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
        let firstSize = (Int(buffer[position]) << 24)
            | (Int(buffer[position + 1]) << 16)
            | (Int(buffer[position + 2]) << 8)
            | Int(buffer[position + 3])
        guard firstSize >= 8, firstSize <= remaining - 8 else { return nil }
        let secondHeader = position + firstSize
        guard secondHeader + 8 <= buffer.count else { return nil }
        let secondType = String(bytes: buffer[(secondHeader + 4) ..< (secondHeader + 8)], encoding: .ascii) ?? ""

        let knownAtoms: Set<String> = ["moov", "mdat", "free", "wide", "skip", "udta", "trak"]
        if knownAtoms.contains(firstType), knownAtoms.contains(secondType) {
            return .mov
        }
        return nil
    }

    /// Reads the first 16 bytes at the given cluster and checks for a known signature.
    func verifyMagicBytes(_ header: [UInt8], expectedExtension: String) -> FileSignature? {
        guard header.count >= 16 else { return nil }

        if let expectedSignature = FileSignature.from(extension: expectedExtension),
           matchesSignature(header, signature: expectedSignature)
        {
            return expectedSignature
        }

        for signature in FileSignature.allCases {
            if matchesSignature(header, signature: signature) {
                return signature
            }
        }

        return nil
    }

    /// Checks whether the header bytes match a file signature.
    func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        guard matchesMagicPrefix(header, signature: signature) else { return false }

        if let riffResult = matchesRIFFSubtypeIfNeeded(header, signature: signature) {
            return riffResult
        }

        if let ftypResult = matchesFTYPBrandIfNeeded(header, signature: signature) {
            return ftypResult
        }

        return true
    }

    func matchesMagicPrefix(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes
        guard header.count >= magic.count else { return false }
        for index in 0 ..< magic.count where header[index] != magic[index] {
            return false
        }
        return true
    }

    func matchesRIFFSubtypeIfNeeded(_ header: [UInt8], signature: FileSignature) -> Bool? {
        guard signature == .avi || signature == .webp else { return nil }
        guard header.count >= 12 else { return true }
        let subType = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
        if signature == .avi { return subType == "AVI " }
        return subType == "WEBP"
    }

    func matchesFTYPBrandIfNeeded(_ header: [UInt8], signature: FileSignature) -> Bool? {
        let ftypSignatures: Set<FileSignature> = [.mp4, .mov, .heic, .heif, .m4v, .threeGP, .avif, .cr3]
        guard ftypSignatures.contains(signature) else { return nil }
        guard header.count >= 8 else { return true }

        let ftyp = String(bytes: header[4 ..< 8], encoding: .ascii) ?? ""
        guard ftyp == "ftyp", header.count >= 12 else { return false }

        let brand = String(bytes: header[8 ..< 12], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""

        switch signature {
        case .mp4: return ["isom", "iso2", "mp41", "mp42", "avc1"].contains(brand)
        case .mov: return ["qt", "qt  ", "wide"].contains(brand)
        case .heic: return ["heic", "heix"].contains(brand)
        case .heif: return brand == "mif1"
        case .m4v: return brand == "m4v"
        case .threeGP: return ["3gp4", "3gp5", "3gp6", "3ge6"].contains(brand)
        case .avif: return ["avif", "avis"].contains(brand)
        case .cr3: return ["cr3", "crx"].contains(brand)
        default: return true
        }
    }
}
