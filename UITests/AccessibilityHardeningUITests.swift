import XCTest

/// Issue #7 accessibility + state-matrix hardening on the pinned simulator.
///
/// Coverage split (honest boundaries):
/// - VoiceOver itself is not XCUITest-scriptable; the accessibility
///   CONTRACT is asserted via element label/value (read order of merged
///   wall cards, elapsed-time label/value pair, hints), which is exactly
///   what VoiceOver would speak. A live VoiceOver walkthrough is a
///   documented manual pre-RC audit (follow-up issue).
/// - Dynamic Type is applied via the documented launch-argument override
///   (`-UIPreferredContentSizeCategoryName` with the exact UIKit raw
///   value) plus an in-app probe that proves the resolved category —
///   a wrong constant silently tests the default size.
/// - Screenshots ride inside tests.xcresult via XCTAttachment so PR
///   evidence cites real rendered artifacts, not claims.
final class AccessibilityHardeningUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Reveal an interactive control: element-scoped swipe first (scrolls
    /// the element's own container), then bounded app-level swipes as a
    /// fallback. NOTE: `element.scroll(to: .visible)` does NOT exist in the
    /// pinned iOS 26 SDK (compile error: resolves to scroll(byDeltaX:));
    /// element gesture methods throw on missing elements, so they are only
    /// invoked when `exists` is already true.
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.exists, (try? element.isHittable) == true { return true }
        if element.exists { element.swipeUp() }
        for _ in 0..<6 {
            if element.exists, (try? element.isHittable) == true { return true }
            app.swipeUp()
        }
        return element.exists && (try? element.isHittable) == true
    }

    /// Existence-keyed reveal: same scroll loop as `reveal` but gated on
    /// existence only. Disabled controls (e.g. Undo before any switch)
    /// can report `isHittable == false` forever, so a hittability-keyed
    /// helper false-fails genuinely-present disabled targets.
    private func revealExists(_ element: XCUIElement) -> Bool {
        if element.exists { return true }
        for _ in 0..<6 {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func elapsedValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extraArguments
        app.launch()
        XCTAssertTrue(anyElement("bootstrap.home").waitForExistence(timeout: 10))
    }

    // MARK: - Wall state matrix

    @MainActor
    func testWallEmptyState() throws {
        launch(extraArguments: ["-ui-testing-empty-wall"])

        // Readiness proof is the always-present primary action, not the
        // empty-state placeholder (ContentUnavailableView identifiers do
        // not bridge into the AX tree).
        XCTAssertTrue(app.buttons["capture.quickStart.free"].waitForExistence(timeout: 5))

        // True empty state renders its copy (query visible text, not id).
        XCTAssertTrue(revealExists(app.staticTexts["No Active Pieces"]))
        XCTAssertTrue(revealExists(app.staticTexts["Add a piece or change an existing piece from Retired."]))
        // No piece cards exist in the empty state.
        XCTAssertFalse(anyElement("wall.card.etude-op-10-no-3").exists)
        // Quick Start remains usable from the empty state.
        XCTAssertTrue(app.buttons["capture.quickStart.free"].isHittable)
        attachScreenshot("wall-empty-default")
    }

    @MainActor
    func testWallUnknownStateIsSpokenInOrder() throws {
        launch()

        // A NavigationLink label merges into ONE accessibility element:
        // its label string IS the VoiceOver utterance and its internal
        // order is the read order. Assert the full contract of the
        // seeded, never-practiced card.
        let card = anyElement("wall.card.etude-op-10-no-3")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let spoken = card.label
        let expectedOrder = [
            "Etude Op.10 No.3",
            "Status:",
            "Last practiced: Unknown",
            "This week: Unknown",
            "Best tempo: Unknown",
            "Versus target: Unknown",
        ]
        var lastIndex = spoken.startIndex
        for fragment in expectedOrder {
            guard let found = spoken.range(of: fragment, range: lastIndex..<spoken.endIndex) else {
                XCTFail("Wall card spoken order violated. Expected \"\(fragment)\" after offset \(spoken.distance(from: spoken.startIndex, to: lastIndex)) in: \(spoken)")
                return
            }
            lastIndex = found.upperBound
        }
        // Unknown must survive as unknown — never silently zeroed.
        XCTAssertFalse(spoken.contains("0 min"))
        XCTAssertFalse(spoken.contains("0 BPM"))
    }

    // MARK: - Timer liveness / no focus trap

    @MainActor
    func testTimerRunningKeepsControlsReachableAndAnnounced() throws {
        launch()

        app.buttons["capture.quickStart.free"].tap()
        let elapsed = app.staticTexts["capture.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))

        // The elapsed readout carries an explicit spoken contract:
        // label identifies it, value states duration in words.
        XCTAssertEqual(elapsed.label, "Session elapsed time")
        XCTAssertTrue(elapsedValue(elapsed).contains("seconds"), "Elapsed value must be spoken duration, got \(elapsedValue(elapsed))")

        // Timer must actually be advancing while the run screen holds
        // focus — two samples >1s apart must differ (no focus trap where
        // the UI stops responding to the running clock).
        let firstValue = elapsedValue(elapsed)
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertNotEqual(elapsedValue(elapsed), firstValue, "Elapsed readout must tick while the session runs")

        // Capture controls remain hittable while the timer is running.
        let stop = app.buttons["capture.stop"]
        XCTAssertTrue(reveal(stop))
        XCTAssertTrue(stop.isHittable)
        XCTAssertTrue(app.buttons["capture.pauseResume"].exists)
    }

    // MARK: - Dynamic Type at AX sizes

    @MainActor
    func testAccessibilitySizeAppliesAndCaptureTargetsStayLarge() throws {
        // Exact UIKit raw value — the long-form spelling is silently
        // ignored and would fake-test the default size.
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-dynamic-type-probe",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(anyElement("bootstrap.home").waitForExistence(timeout: 10))

        // Prove the category genuinely applied INSIDE the app before
        // asserting any layout. The UIKit rawValue renders the
        // abbreviated spelling, so gate on the Accessibility prefix.
        let probe = anyElement("wall.sizeCategory")
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "Dynamic Type probe missing")
        XCTAssertTrue(
            probe.label.contains("UICTContentSizeCategoryAccessibility"),
            "AX content size did not apply; probe rendered \(probe.label)"
        )
        attachScreenshot("wall-ax5-default")

        // Wall reflows at AX5: the primary capture control remains a
        // >=44pt hittable target on screen.
        let quickStart = app.buttons["capture.quickStart.free"]
        XCTAssertTrue(reveal(quickStart), "Quick Start unreachable at AX5")
        XCTAssertGreaterThanOrEqual(quickStart.frame.height, 44)
        XCTAssertGreaterThanOrEqual(quickStart.frame.width, 44)

        // Capture flow at AX5: start a session and verify the running
        // controls keep >=44pt targets or remain scroll-reachable.
        XCTAssertTrue(quickStart.isHittable)
        quickStart.tap()
        XCTAssertTrue(app.staticTexts["capture.elapsed"].waitForExistence(timeout: 5))
        attachScreenshot("session-ax5-running")

        for identifier in ["capture.switchPiece", "capture.pauseResume", "capture.undo", "capture.stop"] {
            let control = app.buttons[identifier]
            // Undo starts disabled; existence-keyed reveal so a disabled
            // target can't false-fail the reveal loop.
            XCTAssertTrue(revealExists(control), "\(identifier) unreachable at AX5")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(identifier) target below 44pt at AX5")
        }

        // Stop at AX5 and return home — the full one-handed flow survives.
        let stop = app.buttons["capture.stop"]
        XCTAssertTrue(reveal(stop))
        stop.tap()
        XCTAssertTrue(anyElement("capture.review.title").waitForExistence(timeout: 5))
        attachScreenshot("review-ax5")
    }

    // MARK: - Restore preview state matrix (label/value contract)

    @MainActor
    func testRestorePreviewControlsAnnounceThemselves() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-restore-preview"]
        app.launch()

        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let confirm = app.buttons["restore.confirm"]
        XCTAssertTrue(reveal(confirm))
        // The destructive confirm must announce as destructive to AX.
        XCTAssertTrue(confirm.label.contains("Confirm Replace"))
        let cancel = app.buttons["restore.cancel"]
        XCTAssertTrue(reveal(cancel))
        XCTAssertTrue(cancel.label.contains("Cancel Restore"))
        attachScreenshot("restore-preview-default")
    }
}
