import XCTest
@testable import Vivacity

private actor RecordingFooterDetector: FileFooterDetecting {
    private let jpegSize: Int64?
    private var recordedJPEGMaxScanBytes: [Int] = []

    init(jpegSize: Int64?) {
        self.jpegSize = jpegSize
    }

    func estimateSize(
        signature: FileSignature,
        startOffset _: UInt64,
        reader _: PrivilegedDiskReading,
        maxScanBytes: Int
    ) async throws -> Int64? {
        if signature == .jpeg {
            recordedJPEGMaxScanBytes.append(maxScanBytes)
            return jpegSize
        }
        return nil
    }

    func estimatePNGSize(
        startOffset _: UInt64,
        reader _: PrivilegedDiskReading,
        maxScanBytes _: Int,
        validateCriticalChunkCRCs _: Bool
    ) async throws -> PNGSizeEstimation? {
        nil
    }

    func lastJPEGMaxScanBytes() -> Int? {
        recordedJPEGMaxScanBytes.last
    }
}

private actor RecordingFreeSpaceTraceSink: DeepScanDecisionTracing {
    private var records: [DeepScanTraceRecord] = []

    func record(_ record: DeepScanTraceRecord) async {
        records.append(record)
    }

    func snapshot() -> [DeepScanTraceRecord] {
        records
    }
}

final class DeepScanServiceFreeSpaceTests: XCTestCase {
    // We can simulate a FAT volume with a mock FAT table to test that DeepScanService
    // successfully skips scanning the allocated clusters and only scans the free clusters.

    private func createMockFATVolumeWithFile(
        totalSectors: UInt64,
        bytesPerSector: UInt16 = 512,
        sectorsPerCluster: UInt8 = 8
    ) -> Data {
        var data = Data(repeating: 0, count: Int(totalSectors) * Int(bytesPerSector))

        // --- Boot Sector (BPB) ---
        data[11] = UInt8(bytesPerSector & 0xFF)
        data[12] = UInt8((bytesPerSector >> 8) & 0xFF)
        data[13] = sectorsPerCluster
        data[14] = 32 // reserved
        data[15] = 0
        data[16] = 2 // 2 FATs

        let sectorsPerFAT: UInt32 = 100
        writeUInt32(&data, at: 36, value: sectorsPerFAT) // sectorsPerFAT32

        data[44] = 2
        data[510] = 0x55
        data[511] = 0xAA
        writeUInt32(&data, at: 32, value: UInt32(totalSectors)) // totalSectors32

        // --- FAT Table ---
        let fatStart = 32 * Int(bytesPerSector)

        writeUInt32(&data, at: fatStart, value: 0x0FFF_FFF8)
        writeUInt32(&data, at: fatStart + 4, value: 0xFFFF_FFFF)

        // Cluster 2: Allocated (Start of data region)
        writeUInt32(&data, at: fatStart + 8, value: 0x0FFF_FFFF)
        // Cluster 3: Free
        writeUInt32(&data, at: fatStart + 12, value: 0x0000_0000)
        // Cluster 4: Free
        writeUInt32(&data, at: fatStart + 16, value: 0x0000_0000)
        // Cluster 5: Allocated
        writeUInt32(&data, at: fatStart + 20, value: 0x0FFF_FFFF)

        // --- Data Region ---
        let dataStart = (32 + 2 * Int(sectorsPerFAT)) * Int(bytesPerSector)
        let clusterSize = Int(bytesPerSector) * Int(sectorsPerCluster)

        // Cluster 2 (Allocated): Put a JPEG here. It should NOT be emitted!
        writeJPEG(into: &data, at: dataStart)

        // Cluster 3 (Free): Put a JPEG here. It SHOULD be emitted!
        writeJPEG(into: &data, at: dataStart + clusterSize)

        // Cluster 5 (Allocated): Put a JPEG here. It should NOT be emitted!
        writeJPEG(into: &data, at: dataStart + 3 * clusterSize)

        return data
    }

    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeJPEG(into data: inout Data, at offset: Int) {
        let magic: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        for i in 0 ..< magic.count {
            data[offset + i] = magic[i]
        }
        // Fill some entropy so confidence score is high
        for i in 4 ..< 2048 {
            data[offset + i] = UInt8.random(in: 1 ... 255)
        }
        data[offset + 2048] = 0xFF
        data[offset + 2049] = 0xD9
    }

    private func writeBoundaryCrossingJPEG(into data: inout Data, at offset: Int, length: Int) {
        let bytes = makeJPEGBytes(length: length)
        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }

    private func makeJPEGBytes(length: Int) -> [UInt8] {
        precondition(length >= 4)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 0xFF
        bytes[1] = 0xD8
        bytes[2] = 0xFF
        bytes[3] = 0xE0
        if length > 6 {
            for index in 4 ..< (length - 2) {
                let value = UInt8(((index * 73) % 251) + 1)
                bytes[index] = value == 0xFF ? 0x7D : value
            }
        }
        bytes[length - 2] = 0xFF
        bytes[length - 1] = 0xD9
        return bytes
    }

    func testDeepScanServiceSkipsAllocatedSpaceUsingMap() async throws {
        // Build mock volume
        let volumeData = createMockFATVolumeWithFile(totalSectors: 600_000)
        let fakeReader = FakePrivilegedDiskReader(buffer: volumeData)

        // Let's print the free space ranges natively parsed
        let mapper = FATAllocationTable(reader: fakeReader)
        var parsedRanges = [FreeSpaceRange]()
        for try await r in mapper.freeSpaceRanges() {
            print("FAT MAPPER RANGE: \(r)")
            parsedRanges.append(r)
        }

        let traceSink = RecordingFreeSpaceTraceSink()
        let deepScanService = DeepScanService(
            diskReaderFactory: { _ in fakeReader },
            decisionTracer: traceSink
        )

        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .fat32, isExternal: true, isDiskImage: true,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(volumeData.count), availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)

        // Let's print the actual ranges resolved by the scanner if we could, or just the events.

        var foundFiles: [RecoverableFile] = []
        for try await event in stream {
            if case let .fileFound(file) = event {
                print("DEBUG: found file: \(file)")
                if file.signatureMatch == .jpeg, file.recoveryConfidence != .low {
                    foundFiles.append(file)
                    break
                }
            }
        }

        // We injected 3 JPEGs:
        // C2 (Allocated) -> Should be skipped
        // C3 (Free) -> Should be scanned/recovered
        // C5 (Allocated) -> Should be skipped
        XCTAssertEqual(foundFiles.count, 1, "Should only recover the 1 JPEG that resided in free space")

        let clusterSize = 512 * 8
        let dataStart = (32 + 2 * 100) * 512
        let expectedOffset = UInt64(dataStart + clusterSize) // Offset of Cluster 3

        XCTAssertEqual(
            foundFiles[0].offsetOnDisk,
            expectedOffset,
            "Recovered JPEG should originate from the free cluster"
        )

        let records = await traceSink.snapshot()
        let skipRecord = records.first { $0.event == "free_space_skip" }
        XCTAssertNotNil(skipRecord)
        XCTAssertEqual(skipRecord?.allocationState, "allocated")
        XCTAssertEqual(skipRecord?.reason, "advanced_to_next_free_space_range")
        XCTAssertEqual(skipRecord?.nextOffset, expectedOffset)
    }

    func testDeepScanServiceEmitsBoundaryCrossingJPEGAsLowConfidence() async throws {
        let bytesPerSector: UInt16 = 512
        let sectorsPerCluster: UInt8 = 8
        let sectorsPerFAT: UInt32 = 100
        let clusterSize = Int(bytesPerSector) * Int(sectorsPerCluster)

        var data = Data(repeating: 0, count: 600_000 * Int(bytesPerSector))
        data[11] = UInt8(bytesPerSector & 0xFF)
        data[12] = UInt8((bytesPerSector >> 8) & 0xFF)
        data[13] = sectorsPerCluster
        data[14] = 32
        data[16] = 2
        writeUInt32(&data, at: 36, value: sectorsPerFAT)
        data[44] = 2
        data[510] = 0x55
        data[511] = 0xAA
        writeUInt32(&data, at: 32, value: 600_000)

        let fatStart = 32 * Int(bytesPerSector)
        writeUInt32(&data, at: fatStart, value: 0x0FFF_FFF8)
        writeUInt32(&data, at: fatStart + 4, value: 0xFFFF_FFFF)
        writeUInt32(&data, at: fatStart + 8, value: 0x0000_0000) // cluster 2 free
        writeUInt32(&data, at: fatStart + 12, value: 0x0FFF_FFFF) // cluster 3 allocated
        writeUInt32(&data, at: fatStart + 16, value: 0x0FFF_FFFF) // cluster 4 allocated

        let dataStart = (32 + 2 * Int(sectorsPerFAT)) * Int(bytesPerSector)
        writeBoundaryCrossingJPEG(into: &data, at: dataStart, length: clusterSize + 1024)

        let fakeReader = FakePrivilegedDiskReader(buffer: data)
        let traceSink = RecordingFreeSpaceTraceSink()
        let deepScanService = DeepScanService(
            diskReaderFactory: { _ in fakeReader },
            decisionTracer: traceSink
        )
        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .fat32, isExternal: true, isDiskImage: true,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(data.count), availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)

        var foundFiles: [RecoverableFile] = []
        for try await event in stream {
            if case let .fileFound(file) = event, file.signatureMatch == .jpeg {
                foundFiles.append(file)
                break
            }
        }

        let recovered = try XCTUnwrap(foundFiles.first)
        XCTAssertEqual(recovered.offsetOnDisk, UInt64(dataStart))
        XCTAssertGreaterThan(recovered.sizeInBytes, Int64(clusterSize))
        XCTAssertEqual(recovered.recoveryConfidence, .low)
        XCTAssertEqual(recovered.isLikelyContiguous, false)

        let records = await traceSink.snapshot()
        let acceptedTrace = records.first { record in
            record.event == "candidate_decision" &&
                record.finalDecision == "accepted" &&
                record.offsetOnDisk == UInt64(dataStart)
        }
        XCTAssertNotNil(acceptedTrace)
        XCTAssertEqual(acceptedTrace?.allocationState, "free")
        XCTAssertEqual(acceptedTrace?.crossesPreferredBoundary, true)
        XCTAssertEqual(acceptedTrace?.candidateSource, "magic_scan")
    }

    func testDeepScanServiceEstimatesBoundaryCrossingJPEGUsingDeviceBounds() async throws {
        let bytesPerSector: UInt16 = 512
        let sectorsPerCluster: UInt8 = 8
        let sectorsPerFAT: UInt32 = 100
        let clusterSize = Int(bytesPerSector) * Int(sectorsPerCluster)

        var data = Data(repeating: 0, count: 600_000 * Int(bytesPerSector))
        data[11] = UInt8(bytesPerSector & 0xFF)
        data[12] = UInt8((bytesPerSector >> 8) & 0xFF)
        data[13] = sectorsPerCluster
        data[14] = 32
        data[16] = 2
        writeUInt32(&data, at: 36, value: sectorsPerFAT)
        data[44] = 2
        data[510] = 0x55
        data[511] = 0xAA
        writeUInt32(&data, at: 32, value: 600_000)

        let fatStart = 32 * Int(bytesPerSector)
        writeUInt32(&data, at: fatStart, value: 0x0FFF_FFF8)
        writeUInt32(&data, at: fatStart + 4, value: 0xFFFF_FFFF)
        writeUInt32(&data, at: fatStart + 8, value: 0x0000_0000) // cluster 2 free
        writeUInt32(&data, at: fatStart + 12, value: 0x0FFF_FFFF) // cluster 3 allocated
        writeUInt32(&data, at: fatStart + 16, value: 0x0FFF_FFFF) // cluster 4 allocated

        let dataStart = (32 + 2 * Int(sectorsPerFAT)) * Int(bytesPerSector)
        writeBoundaryCrossingJPEG(into: &data, at: dataStart, length: clusterSize + 1024)

        let fakeReader = FakePrivilegedDiskReader(buffer: data)
        let footerDetector = RecordingFooterDetector(jpegSize: Int64(clusterSize + 1024))
        let deepScanService = DeepScanService(
            diskReaderFactory: { _ in fakeReader },
            fileFooterDetector: footerDetector
        )
        let device = StorageDevice(
            id: "test", name: "test", volumePath: URL(fileURLWithPath: "/dev/null"),
            volumeUUID: "test", filesystemType: .fat32, isExternal: true, isDiskImage: true,
            partitionOffset: nil, partitionSize: nil, totalCapacity: Int64(data.count), availableCapacity: 0
        )

        let stream = deepScanService.scan(device: device, existingOffsets: [], startOffset: 0, cameraProfile: .generic)

        for try await event in stream {
            if case let .fileFound(file) = event, file.signatureMatch == .jpeg {
                XCTAssertEqual(file.offsetOnDisk, UInt64(dataStart))
                break
            }
        }

        let lastRecordedMaxScanBytes = await footerDetector.lastJPEGMaxScanBytes()
        let recordedMaxScanBytes = try XCTUnwrap(lastRecordedMaxScanBytes)
        XCTAssertEqual(recordedMaxScanBytes, 32 * 1024 * 1024)
    }
}
