import Foundation

extension FastScanService {
    func makeRawCatalogPhaseStream(
        volumeInfo: VolumeInfo,
        reader: any PrivilegedDiskReading,
        totalBytes: UInt64
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { phaseBContinuation in
            Task.detached {
                do {
                    try await runFilesystemSpecificCatalogScan(
                        volumeInfo: volumeInfo,
                        reader: reader,
                        totalBytes: totalBytes,
                        continuation: phaseBContinuation
                    )
                    phaseBContinuation.finish()
                } catch {
                    phaseBContinuation.finish(throwing: error)
                }
            }
        }
    }

    func runFilesystemSpecificCatalogScan(
        volumeInfo: VolumeInfo,
        reader: any PrivilegedDiskReading,
        totalBytes: UInt64,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws {
        switch volumeInfo.filesystemType {
        case .fat32:
            let scanner = FATDirectoryScanner()
            try await scanner.scan(volumeInfo: volumeInfo, reader: reader, continuation: continuation)
        case .exfat:
            let scanner = ExFATScanner()
            try await scanner.scan(volumeInfo: volumeInfo, reader: reader, continuation: continuation)
        case .ntfs:
            let scanner = NTFSScanner()
            try await scanner.scan(volumeInfo: volumeInfo, reader: reader, continuation: continuation)
        case .apfs:
            let scanner = APFSMetadataScanner()
            try await scanner.scan(
                volumeInfo: volumeInfo,
                reader: reader,
                totalBytes: totalBytes,
                continuation: continuation
            )
        default:
            break
        }
    }
}
