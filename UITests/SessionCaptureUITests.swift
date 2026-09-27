import XCTest

/// UI tests on the pinned macOS simulator lane covering the session capture workflow (issue #4 acceptance):
/// start -> switch -> undo -> stop -> confirm -> ledger-assert end-to-end.
final class SessionCaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - Tests

    @MainActor
    func testQuickStartFreePracticeAndStop() throws {
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        let quickStart = app.buttons["capture.quickStart.free"]
        XCTAssertTrue(quickStart.waitForExistence(timeout: 5))
        quickStart.tap()

        XCTAssertTrue(app.staticTexts["capture.elapsed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Free Practice"].exists)

        let stop = app.buttons["capture.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        XCTAssertTrue(app.staticTexts["capture.review.title"].waitForExistence(timeout: 5))

        let save = app.buttons["capture.review.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sessions: 1")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testStartSwitchUndoStopAndLedgerAssert() throws {
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        let etudeStart = app.buttons["capture.piece.start.etude-op-10-no-3"]
        XCTAssertTrue(etudeStart.waitForExistence(timeout: 5), "Seeded Etude start button not found")
        etudeStart.tap()

        XCTAssertTrue(app.staticTexts["capture.elapsed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Etude Op.10 No.3"].exists)

        let switchBtn = app.buttons["capture.switchPiece"]
        XCTAssertTrue(switchBtn.waitForExistence(timeout: 5))
        switchBtn.tap()

        let scalesOption = app.buttons["capture.switch.scales"]
        XCTAssertTrue(scalesOption.waitForExistence(timeout: 5))
        scalesOption.tap()

        XCTAssertTrue(app.staticTexts["Scales"].waitForExistence(timeout: 5))

        let undo = app.buttons["capture.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()

        XCTAssertTrue(app.staticTexts["Etude Op.10 No.3"].waitForExistence(timeout: 5))

        switchBtn.tap()
        XCTAssertTrue(scalesOption.waitForExistence(timeout: 5))
        scalesOption.tap()
        XCTAssertTrue(app.staticTexts["Scales"].waitForExistence(timeout: 5))

        let pause = app.buttons["capture.pauseResume"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(app.staticTexts["Practicing"].waitForExistence(timeout: 5))

        let stop = app.buttons["capture.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        XCTAssertTrue(app.staticTexts["capture.review.title"].waitForExistence(timeout: 5))

        // Per-piece tempo stepper (issue #4: optional per-piece achieved BPM).
        let tempoStepper = app.steppers["capture.review.tempo.etude-op-10-no-3"]
        XCTAssertTrue(tempoStepper.waitForExistence(timeout: 5), "Etude tempo stepper not found")
        tempoStepper.buttons.element(boundBy: 1).tap()

        let noteField = app.textFields["capture.review.note"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 5), "Review note field not found")
        noteField.tap()
        noteField.typeText("Clean phrasing on B section\n")

        // Content may be long; scroll inside the review scroll view so Save is hittable.
        let reviewScroll = app.scrollViews["capture.review.scroll"]
        if reviewScroll.waitForExistence(timeout: 3) {
            reviewScroll.swipeUp()
        }

        let save = app.buttons["capture.review.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["capture.status"].waitForExistence(timeout: 5))

        let sessionsCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sessions: 1")).firstMatch
        XCTAssertTrue(sessionsCount.waitForExistence(timeout: 5), "Expected 1 session in ledger")

        let splitsCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Session splits: 2")).firstMatch
        XCTAssertTrue(splitsCount.waitForExistence(timeout: 5), "Expected 2 splits in ledger")

        let tempoCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Tempo logs: 1")).firstMatch
        XCTAssertTrue(tempoCount.waitForExistence(timeout: 5), "Expected 1 tempo log in ledger")

        let notesCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Practice notes: 1")).firstMatch
        XCTAssertTrue(notesCount.waitForExistence(timeout: 5), "Expected 1 practice note in ledger")
    }
}
