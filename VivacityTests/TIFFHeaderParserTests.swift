import XCTest
@testable import Vivacity

final class TIFFHeaderParserTests: XCTestCase {
    private let parser = TIFFHeaderParser()

    // MARK: - Helper

    /// Creates a minimal little-endian TIFF header with IFD0 containing Make and/or Model entries.
    private func createTIFFWithMakeModel(
        make: String? = nil,
        model: String? = nil
    ) -> [UInt8] {
        var buffer = [UInt8]()

        // TIFF header: "II" (little-endian) + magic 42 + IFD0 offset
        buffer.append(contentsOf: [0x49, 0x49]) // "II"
        buffer.append(contentsOf: [0x2A, 0x00]) // Magic 42 (LE)

        // IFD0 starts at offset 8
        buffer.append(contentsOf: [0x08, 0x00, 0x00, 0x00])

        var ifdEntries: [[UInt8]] = []
        var stringData: [(offset: Int, bytes: [UInt8])] = []

        // We'll place string data after the IFD (offset = 8 + 2 + entries*12 + 4)
        // 2 = entryCount, 4 = next IFD offset
        var entryCount = 0
        if make != nil { entryCount += 1 }
        if model != nil { entryCount += 1 }

        let stringDataStart = 8 + 2 + entryCount * 12 + 4

        if let make {
            let makeBytes = Array(make.utf8) + [0x00] // null-terminated
            let entry = createIFDEntry(
                tag: 0x010F, type: 2, count: UInt32(makeBytes.count),
                valueOrOffset: UInt32(stringDataStart + stringData.reduce(0) { $0 + $1.bytes.count })
            )
            ifdEntries.append(entry)
            stringData.append((offset: 0, bytes: makeBytes))
        }

        if let model {
            let modelBytes = Array(model.utf8) + [0x00]
            let entry = createIFDEntry(
                tag: 0x0110, type: 2, count: UInt32(modelBytes.count),
                valueOrOffset: UInt32(stringDataStart + stringData.reduce(0) { $0 + $1.bytes.count })
            )
            ifdEntries.append(entry)
            stringData.append((offset: 0, bytes: modelBytes))
        }

        // Write IFD0: entry count
        buffer.append(contentsOf: leUInt16(UInt16(entryCount)))

        // Write entries
        for entry in ifdEntries {
            buffer.append(contentsOf: entry)
        }

        // Next IFD offset (0 = no more IFDs)
        buffer.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Write string data
        for item in stringData {
            buffer.append(contentsOf: item.bytes)
        }

        return buffer
    }

    private func createIFDEntry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) -> [UInt8] {
        var entry = [UInt8]()
        entry.append(contentsOf: leUInt16(tag))
        entry.append(contentsOf: leUInt16(type))
        entry.append(contentsOf: leUInt32(count))
        entry.append(contentsOf: leUInt32(valueOrOffset))
        return entry
    }

    private func leUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func leUInt32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    // MARK: - Camera Identification Tests

    func testIdentifiesCanonMake() {
        let buffer = createTIFFWithMakeModel(make: "Canon", model: "Canon EOS R5")
        let result = parser.identifyCamera(from: buffer)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.make, "Canon")
        XCTAssertEqual(result?.model, "Canon EOS R5")
    }

    func testIdentifiesSonyMake() {
        let buffer = createTIFFWithMakeModel(make: "SONY", model: "ILCE-7M4")
        let result = parser.identifyCamera(from: buffer)
        XCTAssertEqual(result?.make, "SONY")
    }

    func testIdentifiesNikonMake() {
        let buffer = createTIFFWithMakeModel(make: "NIKON CORPORATION", model: "NIKON Z 9")
        let result = parser.identifyCamera(from: buffer)
        XCTAssertEqual(result?.make, "NIKON CORPORATION")
    }

    func testReturnsNilForNonTIFFData() {
        let buffer: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0x00, 0x00]
        XCTAssertNil(parser.identifyCamera(from: buffer))
    }

    func testReturnsNilForEmptyBuffer() {
        XCTAssertNil(parser.identifyCamera(from: []))
    }

    func testReturnsNilForTooShortBuffer() {
        let buffer: [UInt8] = [0x49, 0x49, 0x2A]
        XCTAssertNil(parser.identifyCamera(from: buffer))
    }

    // MARK: - RAW Signature Promotion Tests

    func testPromotesCanonToSignature() {
        let buffer = createTIFFWithMakeModel(make: "Canon")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertEqual(signature, .cr2)
    }

    func testPromotesSonyToSignature() {
        let buffer = createTIFFWithMakeModel(make: "SONY")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertEqual(signature, .arw)
    }

    func testPromotesNikonToSignature() {
        let buffer = createTIFFWithMakeModel(make: "NIKON CORPORATION")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertEqual(signature, .nef)
    }

    func testPromotesFujifilmToSignature() {
        let buffer = createTIFFWithMakeModel(make: "FUJIFILM")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertEqual(signature, .raf)
    }

    func testPromotesPanasonicToSignature() {
        let buffer = createTIFFWithMakeModel(make: "Panasonic")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertEqual(signature, .rw2)
    }

    func testReturnsNilForUnknownMake() {
        let buffer = createTIFFWithMakeModel(make: "Leica")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertNil(signature)
    }

    func testReturnsNilForTIFFWithoutMake() {
        let buffer = createTIFFWithMakeModel(model: "Some Camera")
        let signature = parser.identifyRAWSignature(from: buffer)
        XCTAssertNil(signature)
    }
}
