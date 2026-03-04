import XCTest
@testable import Vivacity

final class HEVCNALParserTests: XCTestCase {
    private let parser = HEVCNALParser()

    func testValidateParameterSetsDetectsVPSAndSPSAndPPS() {
        let stream = Data(
            [
                0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xAA, // VPS (type 32)
                0x00, 0x00, 0x01, 0x42, 0x01, 0xBB, // SPS (type 33)
                0x00, 0x00, 0x01, 0x44, 0x01, 0xCC, // PPS (type 34)
            ]
        )

        let validation = parser.validateParameterSets(in: stream)

        XCTAssertTrue(validation.hasAnnexBData)
        XCTAssertEqual(validation.vpsCount, 1)
        XCTAssertEqual(validation.spsCount, 1)
        XCTAssertEqual(validation.ppsCount, 1)
        XCTAssertTrue(validation.hasRequiredParameterSets)
        XCTAssertFalse(validation.hasInvalidParameterSetSignal)
    }

    func testValidateParameterSetsFlagsMissingParameterSetsWhenAnnexBExists() {
        let stream = Data(
            [
                0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0xAA, // SPS only
                0x00, 0x00, 0x01, 0x44, 0x01, 0xBB, // PPS only
            ]
        )

        let validation = parser.validateParameterSets(in: stream)

        XCTAssertTrue(validation.hasAnnexBData)
        XCTAssertEqual(validation.vpsCount, 0)
        XCTAssertEqual(validation.spsCount, 1)
        XCTAssertEqual(validation.ppsCount, 1)
        XCTAssertFalse(validation.hasRequiredParameterSets)
        XCTAssertTrue(validation.hasInvalidParameterSetSignal)
    }

    func testValidateParameterSetsReturnsNoAnnexBSignalForLengthPrefixedPayload() {
        // Simulates non-Annex-B length-prefixed NAL units.
        let stream = Data([0x00, 0x00, 0x00, 0x05, 0x40, 0x01, 0xAA, 0xBB, 0xCC])

        let validation = parser.validateParameterSets(in: stream)

        XCTAssertFalse(validation.hasAnnexBData)
        XCTAssertEqual(validation.annexBStartCodeCount, 0)
        XCTAssertEqual(validation.parsedNALUnitCount, 0)
    }

    func testValidateParameterSetsHonorsNALUnitLimit() {
        var stream = Data()
        for _ in 0 ..< 10 {
            // VPS repeated so every unit is parseable.
            stream.append(contentsOf: [0x00, 0x00, 0x01, 0x40, 0x01, 0xAA])
        }

        let validation = parser.validateParameterSets(
            in: stream,
            limits: .init(maxScanBytes: 1024, maxNALUnits: 3)
        )

        XCTAssertEqual(validation.parsedNALUnitCount, 3)
        XCTAssertTrue(validation.reachedNALUnitLimit)
    }
}
