import XCTest

final class RestorePreviewUITests: XCTestCase {
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<5 where !element.exists {
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 5)
    }

    func testPreviewRequiresExplicitConfirm() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-restore-preview"]
        app.launch()
        openSettings(app)

        let summary = app.descendants(matching: .any)["restore.summary"].firstMatch
        XCTAssertTrue(reveal(summary, in: app))
        let instruments = app.descendants(matching: .any)["restore.count.instruments"].firstMatch
        XCTAssertTrue(reveal(instruments, in: app))
        let notes = app.descendants(matching: .any)["restore.count.practicenotes"].firstMatch
        XCTAssertTrue(reveal(notes, in: app))
        let cancel = app.buttons["restore.cancel"]
        XCTAssertTrue(reveal(cancel, in: app))
        cancel.tap()
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
    }

    func testConfirmedPreviewReplacesRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-restore-preview"]
        app.launch()
        openSettings(app)

        let confirm = app.buttons["restore.confirm"]
        XCTAssertTrue(reveal(confirm, in: app))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["restore.success"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["restore.confirm"].exists)
    }
}
