import XCTest

final class RestorePreviewUITests: XCTestCase {
    func testPreviewRequiresExplicitConfirm() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-restore-preview"]
        app.launch()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.staticTexts["restore.summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["restore.confirm"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["restore.count.instruments"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["restore.count.practicenotes"].exists)
        app.buttons["restore.cancel"].tap()
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
    }

    func testConfirmedPreviewReplacesRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-restore-preview"]
        app.launch()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["restore.confirm"].waitForExistence(timeout: 5))
        app.buttons["restore.confirm"].tap()
        XCTAssertTrue(app.staticTexts["restore.success"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
    }
}
