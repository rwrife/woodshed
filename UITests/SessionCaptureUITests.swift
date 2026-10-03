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
        XCTAssertTrue(
            ledgerStaticText(containing: "Sessions: 1").waitForExistence(timeout: 5),
            "Ledger row 'Sessions: 1' never materialized.\n\(ledgerDiagnostics(containing: "Sessions: 1"))"
        )
    }

    /// Ledger summaries can sit below the fold on compact simulators. The
    /// app now scrolls a committed ledger into view itself (issue #18), so
    /// first wait briefly for that programmatic reveal; only then fall
    /// back to app-level swipe bursts and sustained coordinate drags.
    /// Each gesture is followed by a short existence poll — swiping faster
    /// than the scroll view re-renders (or exhausting a fixed gesture
    /// count while the row is still offscreen) is what made this assertion
    /// flake on hosted runners (runs 36645853539 / 36652555994 /
    /// 36837929767).
    private func ledgerStaticText(containing labelFragment: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", labelFragment)
        let match = app.staticTexts.matching(predicate).firstMatch
        if match.waitForExistence(timeout: 3) { return match }
        // Give the app-owned programmatic reveal (PracticeWallView
        // `.scrollPosition` on commit) a chance to land.
        if match.waitForExistence(timeout: 3) { return match }
        for _ in 0..<4 {
            app.swipeUp()
            if match.waitForExistence(timeout: 2) { return match }
        }
        // Coordinate-drag fallback: a slow, sustained press-drag has
        // surfaced rows that fast momentum swipes never revealed on some
        // hosted runners (the #18 failure snapshots never showed the row
        // in the query results despite repeated swipeUp()).
        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        for _ in 0..<4 {
            dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
            if match.waitForExistence(timeout: 2) { return match }
        }
        return match
    }

    /// Self-diagnosing evidence pack for the ledger asserts (issue #18):
    /// if the reveal ever fails again, the failure message itself must
    /// show WHICH app state we're actually in (wall vs stuck-on-review vs
    /// store-unavailable) plus keyboard state, the ledger count probe,
    /// and the rendered static texts — instead of an evidence-free retry
    /// loop over opaque flakes.
    private func ledgerDiagnostics(containing labelFragment: String) -> String {
        var lines: [String] = ["fragment=\"\(labelFragment)\""]
        lines.append("keyboardVisible=\(app.keyboards.count > 0)")
        // State discriminators: the wall nav title vs the review nav
        // title, the wall's ledger-unavailable fallback, and any save
        // error the model surfaced.
        lines.append("wallNavVisible=\(app.navigationBars["Practice Wall"].exists)")
        lines.append("practiceWallVisible=\(anyElement("practice.wall").exists)")
        lines.append("reviewStillVisible=\(app.staticTexts["capture.review.title"].exists)")
        lines.append("ledgerUnavailableVisible=\(anyElement("ledger.unavailable").exists)")
        let status = anyElement("capture.status")
        if status.exists {
            lines.append("capture.status.label=\"\(status.label)\"")
        }
        let countProbe = anyElement("ledger.sessions.count")
        let countExists = countProbe.exists
        lines.append("ledger.sessions.count.exists=\(countExists)")
        if countExists {
            lines.append("ledger.sessions.count.frame=\(countProbe.frame)")
        }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Sessions")
        let matches = app.staticTexts.matching(predicate).allElementsBoundByIndex
        lines.append("staticTextsMatchingSessions=\(matches.count)")
        for text in matches.prefix(5) {
            let hittable = (try? text.isHittable) ?? false
            lines.append("  label=\"\(text.label)\" frame=\(text.frame) hittable=\(hittable)")
        }
        // Full rendered-text truth (bounded): the wall is a non-lazy
        // VStack, so if the ledger row exists at all it must appear here.
        let texts = app.staticTexts.allElementsBoundByIndex
        lines.append("staticTextCount=\(texts.count)")
        let labels = texts.prefix(40).map { "\"\($0.label)\"" }
        lines.append("staticTexts=[\(labels.joined(separator: ", "))]")
        return lines.joined(separator: "\n")
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

        // Dismiss the keyboard defensively: the \n above normally submits,
        // but a lingering keyplane would absorb every later gesture, and
        // keyboard state was one of the unknowns in the #18 failure
        // snapshots (which had no diagnostics). Bounded poll, never fatal.
        let returnKey = app.keyboards.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "return")
        ).firstMatch
        if returnKey.waitForExistence(timeout: 2) {
            returnKey.tap()
        }

        // Content may be long; scroll inside the review scroll view so Save is hittable.
        let reviewScroll = app.scrollViews["capture.review.scroll"]
        if reviewScroll.waitForExistence(timeout: 3) {
            reviewScroll.swipeUp()
        }

        let save = app.buttons["capture.review.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        let sessionsCount = ledgerStaticText(containing: "Sessions: 1")
        XCTAssertTrue(sessionsCount.waitForExistence(timeout: 5), "Expected 1 session in ledger.\n\(ledgerDiagnostics(containing: "Sessions: 1"))")

        let splitsCount = ledgerStaticText(containing: "Session splits: 2")
        XCTAssertTrue(splitsCount.waitForExistence(timeout: 5), "Expected 2 splits in ledger.\n\(ledgerDiagnostics(containing: "Session splits: 2"))")

        let tempoCount = ledgerStaticText(containing: "Tempo logs: 1")
        XCTAssertTrue(tempoCount.waitForExistence(timeout: 5), "Expected 1 tempo log in ledger.\n\(ledgerDiagnostics(containing: "Tempo logs: 1"))")

        let notesCount = ledgerStaticText(containing: "Practice notes: 1")
        XCTAssertTrue(notesCount.waitForExistence(timeout: 5), "Expected 1 practice note in ledger.\n\(ledgerDiagnostics(containing: "Practice notes: 1"))")
    }
}
