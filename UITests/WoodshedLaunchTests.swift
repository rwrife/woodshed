import XCTest

/// Smoke launch tests and unknown-safe wall rendering on an empty ledger (issue #5 acceptance).
final class WoodshedLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPracticeWallLaunchesWithUnknownSafeEmptyLedger() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["practice.wall"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Practice Wall"].waitForExistence(timeout: 5))

        // Quick start is present on the wall
        XCTAssertTrue(app.buttons["capture.quickStart.free"].waitForExistence(timeout: 5))

        // Seeded piece cards exist
        let etudeCard = app.descendants(matching: .any)["wall.card.etude-op-10-no-3"].firstMatch
        XCTAssertTrue(etudeCard.waitForExistence(timeout: 5))

        // SwiftUI merges a NavigationLink's label into one accessibility
        // element. Assert the same explicit summary VoiceOver receives.
        let summary = etudeCard.label
        XCTAssertTrue(summary.contains("Last practiced: Unknown"))
        XCTAssertTrue(summary.contains("This week: Unknown"))
        XCTAssertTrue(summary.contains("Best tempo: Unknown"))
        XCTAssertTrue(summary.contains("Versus target: Unknown"))
        XCTAssertFalse(summary.contains("0 min"), "Empty ledger must never render zero minutes")
        XCTAssertFalse(summary.contains("0 BPM"), "Empty ledger must never render zero BPM")

        // VoiceOver rotor: practice wall exposes a rotor for pieces
        XCTAssertTrue(app.descendants(matching: .any)["practice.wall"].firstMatch.exists)
    }

    @MainActor
    func testPieceDetailHistoryAndStatusControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        // Tap the Etude card to navigate to detail
        let etudeCard = app.descendants(matching: .any)["wall.card.etude-op-10-no-3"].firstMatch
        XCTAssertTrue(etudeCard.waitForExistence(timeout: 5))
        etudeCard.tap()

        XCTAssertTrue(app.collectionViews["piece.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Etude Op.10 No.3"].waitForExistence(timeout: 5))

        // Status control (segmented picker: Active, Maintenance, Retired)
        let statusPicker = app.segmentedControls["piece.status"]
        XCTAssertTrue(statusPicker.waitForExistence(timeout: 5))

        // Empty history rendered safely as unknown
        XCTAssertTrue(app.staticTexts["piece.history.unknown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["piece.tempo.unknown"].waitForExistence(timeout: 5))

        // Switch status to Retired -> navigate back -> card is hidden from wall
        statusPicker.buttons["Retired"].tap()

        // Go back to Practice Wall
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["practice.wall"].firstMatch.waitForExistence(timeout: 5))
        let retiredCard = app.descendants(matching: .any)["wall.card.etude-op-10-no-3"].firstMatch
        _ = retiredCard.waitForExistence(timeout: 10)
        XCTAssertFalse(retiredCard.exists, "Retired piece must be hidden from the practice wall")
    }
}
