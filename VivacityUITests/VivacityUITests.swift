import XCTest

final class VivacityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFlowWithFakesShowsScanResults() {
        let app = XCUIApplication()
        app.launchEnvironment["VIVACITY_USE_FAKE_SERVICES"] = "1"
        app.launch()

        // Device list shows fake device
        let deviceCell = app.staticTexts["FakeDisk"]
        XCTAssertTrue(deviceCell.waitForExistence(timeout: 3), "Fake device should appear")
        deviceCell.tap()

        app.buttons["Start Scanning"].tap()

        let fileRow = app.staticTexts["file1.jpg"]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 3), "Fake scan should produce a result")
    }
}
