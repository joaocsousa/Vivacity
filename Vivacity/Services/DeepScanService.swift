import Foundation
import os

protocol DeepScanServicing: Sendable {
    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile
    ) -> AsyncThrowingStream<ScanEvent, Error>
}

// swiftlint:disable:next type_body_length
struct DeepScanService: DeepScanServicing {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "DeepScan")
    private let diskReaderFactory: @Sendable (String) -> any PrivilegedDiskReading
    private let fileFooterDetector: FileFooterDetecting

    init(
        diskReaderFactory: @escaping @Sendable (String)
            -> any PrivilegedDiskReading = { PrivilegedDiskReader(devicePath: $0) as any PrivilegedDiskReading },
        fileFooterDetector: FileFooterDetecting = FileFooterDetector()
    ) {
        self.diskReaderFactory = diskReaderFactory
        self.fileFooterDetector = fileFooterDetector
    }

    private static let sectorSize = 512
    private static let readChunkSectors = 256
    private static let maxSignatureLength = 16
    private static let entropySampleBytes = 4096
    private static let entropyRejectThreshold = 2.2
    private static let confidenceRejectThreshold = 0.4

    private static let directSignatures: [(FileSignature, [UInt8])] = {
        let unambiguous: [FileSignature] = [
            .jpeg, .png, .bmp, .gif, .mkv, .wmv, .flv, .raf, .rw2,
        ]
        return unambiguous.map { ($0, $0.magicBytes) }
    }()

    // MARK: - Public API

    func scan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64 = 0,
        cameraProfile: CameraProfile = .generic
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await performScan(
                        device: device,
                        existingOffsets: existingOffsets,
                        startOffset: startOffset,
                        cameraProfile: cameraProfile,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Scan Logic

    private struct ScanContext {
        let buffer: [UInt8]
        let scanLength: Int
        let readOffset: Int
        let bytesScanned: UInt64
        let existingOffsets: Set<UInt64>
        let cameraProfile: CameraProfile
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func performScan(
        device: StorageDevice,
        existingOffsets: Set<UInt64>,
        startOffset: UInt64,
        cameraProfile: CameraProfile,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        let volumeInfo = VolumeInfo.detect(for: device)
        let devicePath = volumeInfo.devicePath

        logger.info("Starting deep scan on \(device.name) using device \(devicePath)")

        // Use injected reader which handles authorization and privilege
        // escalation transparently — tries direct open() first, then falls
        // back to AuthorizationExecuteWithPrivileges for root-level dd.
        let reader = diskReaderFactory(devicePath)
        do {
            try reader.start()
        } catch {
            logger.error("Failed to start privileged reader: \(error.localizedDescription)")
            throw DeepScanError.cannotOpenDevice(path: devicePath, reason: error.localizedDescription)
        }
        defer { reader.stop() }

        var fatCarver: FATCarver?
        var apfsCarver: APFSCarver?
        var hfsCarver: HFSPlusCarver?

        if volumeInfo.filesystemType == .fat32 {
            var bootSector = [UInt8](repeating: 0, count: 512)
            let read = bootSector.withUnsafeMutableBytes { buf in
                reader.read(into: buf.baseAddress!, offset: 0, length: 512)
            }
            if read == 512, let bpb = BPB(bootSector: bootSector) {
                fatCarver = FATCarver(bpb: bpb)
                logger.info("Initialized FATCarver with valid BPB")
            }
        } else if volumeInfo.filesystemType == .apfs {
            apfsCarver = APFSCarver()
            logger.info("Initialized APFSCarver for APFS volume")
        } else if volumeInfo.filesystemType == .hfsPlus {
            hfsCarver = HFSPlusCarver()
            logger.info("Initialized HFSPlusCarver for HFS+ volume")
        }

        // Get total size for progress
        let totalBytes = UInt64(device.totalCapacity)
        guard totalBytes > 0 else {
            logger.warning("Device reports 0 capacity, cannot deep scan")
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        let chunkSize = Self.sectorSize * Self.readChunkSectors
        var buffer = [UInt8](repeating: 0, count: chunkSize + Self.maxSignatureLength)
        var bytesScanned: UInt64 = startOffset - (startOffset % UInt64(Self.sectorSize))
        var filesFound = 0
        var lastProgressReport: Double = -1
        var carryOver = 0 // Bytes carried over from previous read for cross-boundary matching
        var allOffsets = existingOffsets

        logger.info("Deep scanning \(totalBytes) bytes (\(totalBytes / (1024 * 1024)) MB)")

        while bytesScanned < totalBytes {
            try Task.checkCancellation()

            // Read a chunk
            let toRead = min(chunkSize, Int(totalBytes - bytesScanned))
            let readOffset = carryOver // We keep leftover bytes at the start of buffer

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                reader.read(
                    into: rawBuffer.baseAddress! + readOffset,
                    offset: bytesScanned,
                    length: toRead
                )
            }
            guard bytesRead > 0 else { break }

            let scanLength = readOffset + bytesRead

            // 1. Run Filesystem-Aware Carver (if active)
            buffer.withUnsafeBytes { rawBuffer in
                let chunkStart = bytesScanned > UInt64(readOffset) ? bytesScanned - UInt64(readOffset) : 0
                let slice = UnsafeRawBufferPointer(rebasing: rawBuffer[0 ..< scanLength])

                var carvedFiles: [FATCarver.CarvedFile] = []
                var carvedAPFS: [APFSCarver.CarvedFile] = []
                var carvedHFS: [HFSPlusCarver.CarvedFile] = []

                if fatCarver != nil {
                    carvedFiles = fatCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                } else if apfsCarver != nil {
                    carvedAPFS = apfsCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                } else if hfsCarver != nil {
                    carvedHFS = hfsCarver!.carveChunk(buffer: slice, baseOffset: chunkStart)
                }

                // Process FAT carved files
                for carvedFile in carvedFiles {
                    if allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        fileName: carvedFile.fileName,
                        fileExtension: carvedFile.fileExtension,
                        sizeInBytes: carvedFile.sizeInBytes,
                        offsetOnDisk: carvedFile.offsetOnDisk,
                        reader: reader,
                        allOffsets: &allOffsets,
                        filesFound: &filesFound,
                        continuation: continuation
                    )
                }

                // Process APFS carved files
                for carvedFile in carvedAPFS {
                    if allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        fileName: carvedFile.fileName,
                        fileExtension: carvedFile.fileExtension,
                        sizeInBytes: carvedFile.sizeInBytes,
                        offsetOnDisk: carvedFile.offsetOnDisk,
                        reader: reader,
                        allOffsets: &allOffsets,
                        filesFound: &filesFound,
                        continuation: continuation
                    )
                }

                // Process HFS+ carved files
                for carvedFile in carvedHFS {
                    if allOffsets.contains(carvedFile.offsetOnDisk) { continue }
                    processCarvedFile(
                        fileName: carvedFile.fileName,
                        fileExtension: carvedFile.fileExtension,
                        sizeInBytes: carvedFile.sizeInBytes,
                        offsetOnDisk: carvedFile.offsetOnDisk,
                        reader: reader,
                        allOffsets: &allOffsets,
                        filesFound: &filesFound,
                        continuation: continuation
                    )
                }
            }

            // 2. Linear Magic Byte Scan
            let context = ScanContext(
                buffer: buffer,
                scanLength: scanLength,
                readOffset: readOffset,
                bytesScanned: bytesScanned,
                existingOffsets: allOffsets,
                cameraProfile: cameraProfile
            )
            let newlyFoundOffsets = await scanChunk(
                context: context,
                reader: reader,
                filesFound: &filesFound,
                continuation: continuation
            )

            for offset in newlyFoundOffsets {
                allOffsets.insert(offset)
            }

            bytesScanned += UInt64(bytesRead)

            // Keep the last few bytes for cross-boundary matching
            if scanLength > Self.maxSignatureLength {
                let keepFrom = scanLength - Self.maxSignatureLength
                for j in 0 ..< Self.maxSignatureLength {
                    buffer[j] = buffer[keepFrom + j]
                }
                carryOver = Self.maxSignatureLength
            }

            // Report progress (throttled to avoid spamming — every ~1%)
            let progress = Double(bytesScanned) / Double(totalBytes)
            if progress - lastProgressReport >= 0.01 {
                continuation.yield(.progress(min(progress, 1.0)))
                lastProgressReport = progress

                // Yield to avoid starving the main thread
                await Task.yield()
            }
        }

        logger.info("Deep scan complete: \(filesFound) file(s) found after scanning \(bytesScanned) bytes")
        continuation.yield(.completed)
        continuation.finish()
    }

    // swiftlint:disable:next function_parameter_count
    private func processCarvedFile(
        fileName: String,
        fileExtension: String,
        sizeInBytes: Int64,
        offsetOnDisk: UInt64,
        reader: PrivilegedDiskReading,
        allOffsets: inout Set<UInt64>,
        filesFound: inout Int,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) {
        // Verify signature by reading the cluster from disk
        var header = [UInt8](repeating: 0, count: 16)
        let headRead = header.withUnsafeMutableBytes { hBuf in
            reader.read(into: hBuf.baseAddress!, offset: offsetOnDisk, length: 16)
        }

        if headRead == 16 {
            if let sig = verifyMagicBytes(header, expectedExtension: fileExtension) {
                allOffsets.insert(offsetOnDisk)

                let file = RecoverableFile(
                    id: UUID(),
                    fileName: fileName,
                    fileExtension: fileExtension,
                    fileType: sig.category,
                    sizeInBytes: sizeInBytes,
                    offsetOnDisk: offsetOnDisk,
                    signatureMatch: sig,
                    source: .deepScan,
                    isLikelyContiguous: sizeInBytes > 0,
                    confidenceScore: confidenceScore(
                        signature: sig,
                        sizeInBytes: sizeInBytes,
                        entropy: shannonEntropy(of: header),
                        hasStructureSignal: sizeInBytes > 0
                    )
                )

                if shouldEmit(file) {
                    filesFound += 1
                    continuation.yield(.fileFound(file))
                }
            }
        }
    }

    private func scanChunk(
        context: ScanContext,
        reader: PrivilegedDiskReading,
        filesFound: inout Int,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async -> [UInt64] {
        var newOffsets: [UInt64] = []

        // Scan the chunk for magic bytes
        var i = 0
        while i < context.scanLength - Self.maxSignatureLength {
            let offset = context.bytesScanned + UInt64(i) - UInt64(context.readOffset)

            // Skip if already found by fast scan
            if context.existingOffsets.contains(offset) {
                i += Self.sectorSize
                continue
            }

            if let match = matchSignatureAt(buffer: context.buffer, position: i, cameraProfile: context.cameraProfile) {
                filesFound += 1

                var fileName = "\(context.cameraProfile.defaultFilePrefix)\(String(format: "%04d", filesFound))"

                if match.category == .image {
                    let availableBytes = context.buffer.count - i
                    let checkLength = min(availableBytes, 65536)
                    let headerSlice = Array(context.buffer[i ..< i + checkLength])

                    if let exifName = EXIFDateExtractor.extractFilenamePrefix(from: headerSlice) {
                        fileName = "\(exifName)_\(String(format: "%04d", filesFound))"
                    }
                }

                var sizeInBytes: Int64 = 0

                if match == .jpeg || match == .png,
                   let estimatedSize = try? await fileFooterDetector.estimateSize(
                       signature: match,
                       startOffset: offset,
                       reader: reader,
                       maxScanBytes: 32 * 1024 * 1024
                   )
                {
                    sizeInBytes = estimatedSize
                }

                if match == .mp4 || match == .mov || match == .m4v || match == .threeGP ||
                    match == .heic || match == .heif || match == .avif || match == .cr3
                {
                    let mp4Reconstructor = MP4Reconstructor()
                    if let contiguousSize = mp4Reconstructor.calculateContiguousSize(
                        startingAt: offset,
                        reader: reader
                    ) {
                        sizeInBytes = Int64(contiguousSize)
                    }
                } else if match == .jpeg, sizeInBytes == 0 {
                    let imageReconstructor = ImageReconstructor()

                    let availableBytes = context.buffer.count - i
                    let checkLength = min(availableBytes, 65536)
                    let headerSlice = Data(context.buffer[i ..< i + checkLength])

                    if let result = await imageReconstructor.reconstruct(
                        headerOffset: offset,
                        initialChunk: headerSlice,
                        reader: reader
                    ) {
                        sizeInBytes = Int64(result.count)
                    }
                }

                let availableBytes = context.scanLength - i
                let entropySampleLength = min(max(availableBytes, 0), Self.entropySampleBytes)
                let entropyBytes: [UInt8] = if entropySampleLength > 0 {
                    Array(context.buffer[i ..< i + entropySampleLength])
                } else {
                    []
                }
                let entropy = shannonEntropy(of: entropyBytes)
                let structureSignal = true
                let score = confidenceScore(
                    signature: match,
                    sizeInBytes: sizeInBytes,
                    entropy: entropy,
                    hasStructureSignal: structureSignal
                )

                let file = RecoverableFile(
                    id: UUID(),
                    fileName: fileName,
                    fileExtension: match.fileExtension,
                    fileType: match.category,
                    sizeInBytes: sizeInBytes,
                    offsetOnDisk: offset,
                    signatureMatch: match,
                    source: .deepScan,
                    isLikelyContiguous: sizeInBytes > 0,
                    confidenceScore: score
                )

                if shouldEmit(file, entropy: entropy) {
                    continuation.yield(.fileFound(file))
                } else {
                    filesFound -= 1
                }

                // Skip ahead past this header to avoid re-matching
                newOffsets.append(offset)
                i += Self.sectorSize
                continue
            }

            // Move forward by sector alignment for efficiency
            i += Self.sectorSize
        }

        return newOffsets
    }

    private func shouldEmit(_ file: RecoverableFile, entropy: Double? = nil) -> Bool {
        let score = file.confidenceScore ?? 0

        if let entropy {
            // Drop obvious low-information false positives from deep scans.
            if entropy < Self.entropyRejectThreshold,
               file.signatureMatch == .jpeg,
               file.sizeInBytes > 0,
               file.sizeInBytes < 256 * 1024
            {
                return false
            }
        }

        return score >= Self.confidenceRejectThreshold
    }

    private func confidenceScore(
        signature: FileSignature,
        sizeInBytes: Int64,
        entropy: Double,
        hasStructureSignal: Bool
    ) -> Double {
        let signatureStrength = signatureStrength(for: signature)
        let structureScore = hasStructureSignal ? 1.0 : 0.35
        let sizeScore = sizePlausibilityScore(signature: signature, sizeInBytes: sizeInBytes)
        let entropyScore = normalizedEntropyScore(entropy)

        let weighted =
            (signatureStrength * 0.30) +
            (structureScore * 0.30) +
            (sizeScore * 0.20) +
            (entropyScore * 0.20)
        return min(max(weighted, 0), 1)
    }

    private func signatureStrength(for signature: FileSignature) -> Double {
        switch signature {
        case .jpeg, .png, .gif, .bmp, .tiff, .tiffBigEndian, .heic, .heif, .avif:
            0.95
        case .mp4, .mov, .m4v, .threeGP, .mkv, .avi:
            0.85
        case .webp, .wmv, .flv:
            0.75
        case .cr2, .cr3, .nef, .arw, .dng, .raf, .rw2:
            0.8
        }
    }

    private func sizePlausibilityScore(signature: FileSignature, sizeInBytes: Int64) -> Double {
        guard sizeInBytes > 0 else { return 0.2 }
        let minimum = minimumPlausibleSize(for: signature)
        if sizeInBytes < minimum {
            return 0.35
        }
        if sizeInBytes < minimum * 2 {
            return 0.7
        }
        return 1.0
    }

    private func minimumPlausibleSize(for signature: FileSignature) -> Int64 {
        switch signature.category {
        case .image: 4 * 1024
        case .video: 64 * 1024
        }
    }

    private func normalizedEntropyScore(_ entropy: Double) -> Double {
        // Typical compressed media data tends to be >5 bits/byte in local windows.
        switch entropy {
        case ..<2.2:
            0
        case 2.2 ..< 4.0:
            0.35
        case 4.0 ..< 5.0:
            0.65
        case 5.0 ..< 8.5:
            1.0
        default:
            0.8
        }
    }

    private func shannonEntropy(of bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in bytes {
            counts[Int(byte)] += 1
        }

        let total = Double(bytes.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    // MARK: - Signature Matching

    /// Checks the buffer at the given position for any known file signature.
    private func matchSignatureAt(buffer: [UInt8], position: Int, cameraProfile: CameraProfile) -> FileSignature? {
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

    private func matchDirectSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        for (signature, magic) in Self.directSignatures {
            if remaining >= magic.count {
                var matched = true
                for j in 0 ..< magic.count {
                    if buffer[position + j] != magic[j] {
                        matched = false
                        break
                    }
                }
                if matched { return signature }
            }
        }
        return nil
    }

    private func matchTIFFSignatures(
        buffer: [UInt8],
        position: Int,
        remaining: Int,
        cameraProfile: CameraProfile
    ) -> FileSignature? {
        // Panasonic RW2: 49 49 55 00
        if remaining >= 4,
           buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x55, buffer[position + 3] == 0x00
        {
            return .rw2
        }

        // Little-endian TIFF: 49 49 2A 00
        if buffer[position] == 0x49, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x2A, buffer[position + 3] == 0x00
        {
            // Could be TIFF, CR2, ARW, or DNG
            if remaining >= 10, buffer[position + 8] == 0x43, buffer[position + 9] == 0x52 {
                return .cr2 // "CR" at offset 8
            }

            // Signature promotion based on camera profile
            switch cameraProfile {
            case .sony:
                return .arw
            case .dji:
                return .dng
            default:
                return .tiff
            }
        }
        // Big-endian TIFF: 4D 4D 00 2A
        if buffer[position] == 0x4D, buffer[position + 1] == 0x4D,
           buffer[position + 2] == 0x00, buffer[position + 3] == 0x2A
        {
            return .tiffBigEndian
        }
        return nil
    }

    private func matchRIFFSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12,
           buffer[position] == 0x52, buffer[position + 1] == 0x49,
           buffer[position + 2] == 0x46, buffer[position + 3] == 0x46
        {
            let sub = String(bytes: buffer[(position + 8) ..< (position + 12)], encoding: .ascii) ?? ""
            if sub == "AVI " { return .avi }
            if sub == "WEBP" { return .webp }
        }
        return nil
    }

    private func matchFtypSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
        if remaining >= 12 {
            let ftypStr = String(bytes: buffer[(position + 4) ..< (position + 8)], encoding: .ascii) ?? ""
            if ftypStr == "ftyp" {
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
                    return .mp4 // Default ftyp to mp4
                }
            }
        }
        return nil
    }

    private func matchMOVAtomSignatures(buffer: [UInt8], position: Int, remaining: Int) -> FileSignature? {
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
    private func verifyMagicBytes(
        _ header: [UInt8],
        expectedExtension: String
    ) -> FileSignature? {
        guard header.count >= 16 else { return nil }

        // First try to match against the expected extension
        if let expectedSig = FileSignature.from(extension: expectedExtension) {
            if matchesSignature(header, signature: expectedSig) {
                return expectedSig
            }
        }

        // If extension didn't match, or couldn't map, test all known signatures
        for signature in FileSignature.allCases {
            if matchesSignature(header, signature: signature) {
                return signature
            }
        }

        return nil
    }

    /// Checks whether the header bytes match a file signature.
    private func matchesSignature(_ header: [UInt8], signature: FileSignature) -> Bool {
        let magic = signature.magicBytes
        guard header.count >= magic.count else { return false }

        for i in 0 ..< magic.count {
            if header[i] != magic[i] { return false }
        }

        // Disambiguate RIFF-based formats
        if signature == .avi || signature == .webp {
            guard header.count >= 12 else { return true }
            let sub = String(bytes: header[8 ..< 12], encoding: .ascii) ?? ""
            switch signature {
            case .avi: return sub == "AVI "
            case .webp: return sub == "WEBP"
            default: break
            }
        }

        // Disambiguate ftyp-based formats
        switch signature {
        case .mp4, .mov, .heic, .heif, .m4v, .threeGP, .avif, .cr3:
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
        default:
            return true
        }
    }
}

// MARK: - Errors

/// Errors specific to the deep scan process.
enum DeepScanError: LocalizedError {
    case cannotOpenDevice(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpenDevice(path, reason):
            "Cannot open \(path) for scanning: \(reason). " +
                "Try running with elevated privileges or granting Full Disk Access in System Settings."
        }
    }
}
