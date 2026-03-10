import XCTest
@testable import Vivacity

final class FileSignatureTests: XCTestCase {
    func testNewExtensionsResolveToExpectedSignatures() {
        XCTAssertEqual(FileSignature.from(extension: "cr3"), .cr3)
        XCTAssertEqual(FileSignature.from(extension: "raf"), .raf)
        XCTAssertEqual(FileSignature.from(extension: "rw2"), .rw2)
        XCTAssertEqual(FileSignature.from(extension: "avif"), .avif)
    }

    func testNewFormatsAreClassifiedAsImages() {
        XCTAssertEqual(FileSignature.cr3.category, .image)
        XCTAssertEqual(FileSignature.raf.category, .image)
        XCTAssertEqual(FileSignature.rw2.category, .image)
        XCTAssertEqual(FileSignature.avif.category, .image)
    }

    func testInlineVideoPreviewSupportIsLimitedToStableContainers() {
        XCTAssertTrue(FileSignature.mp4.supportsInlineVideoPreview)
        XCTAssertTrue(FileSignature.mov.supportsInlineVideoPreview)
        XCTAssertTrue(FileSignature.m4v.supportsInlineVideoPreview)

        XCTAssertFalse(FileSignature.avi.supportsInlineVideoPreview)
        XCTAssertFalse(FileSignature.mkv.supportsInlineVideoPreview)
        XCTAssertFalse(FileSignature.wmv.supportsInlineVideoPreview)
        XCTAssertFalse(FileSignature.flv.supportsInlineVideoPreview)
        XCTAssertFalse(FileSignature.threeGP.supportsInlineVideoPreview)
    }
}
