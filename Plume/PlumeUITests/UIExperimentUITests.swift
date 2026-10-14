import XCTest

final class UIExperimentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(reader: Bool = false, theme: String = "Warm", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-experiment-fixture", "-appearance.matchDevice", "NO", "-appearance.selectedTheme", theme] + (reader ? ["--ui-experiment-reader"] : []) + extra
        app.launch()
        return app
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testReaderThemesAndPausedReturn() throws {
        for theme in ["Basic", "Warm", "Muted"] {
            let app = launch(reader: true, theme: theme, extra: ["--ui-experiment-position"])
            XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Minimize Player"].exists)
            XCTAssertTrue(app.buttons["Stop Playback and Close Player"].exists)
            XCTAssertTrue(app.otherElements["Playback Position"].exists)
            capture("reader-restored-\(theme)", app: app)
            app.buttons["Reading Appearance"].tap()
            XCTAssertTrue(app.buttons["\(theme) theme"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["\(theme) theme"].isSelected)
            app.buttons["Done"].tap()
            app.textViews.firstMatch.swipeUp()
            XCTAssertTrue(app.buttons["Return to Current Word"].waitForExistence(timeout: 3))
            let returnButton = app.buttons["Return to Current Word"]
            XCTAssertEqual(returnButton.value as? String, "The")
            XCTAssertGreaterThanOrEqual(returnButton.frame.height, 44)
            capture("reader-return-word-\(theme)", app: app)
            returnButton.tap()
            XCTAssertTrue(app.buttons["Return to Current Word"].waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor func testReducedTransparencyAndMotionReader() throws {
        for theme in ["Basic", "Warm", "Muted"] {
            let app = launch(reader: true, theme: theme, extra: ["--ui-experiment-position", "--ui-experiment-reduce-transparency", "--ui-experiment-reduce-motion"])
            XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
            // The text view extends beneath the header and dock. Keep this
            // gesture within the unobscured passage, away from toolbar controls.
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            XCTAssertFalse(app.buttons["Done"].exists, "Reader browsing must not open a settings sheet")
            let button = app.buttons["Return to Current Word"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            XCTAssertEqual(button.value as? String, "The")
            capture("reader-reduced-effects-\(theme)", app: app)
            button.tap()
            XCTAssertTrue(button.waitForNonExistence(timeout: 3))
            app.buttons["Stop Playback and Close Player"].tap()
            XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor func testExpandedSheetsAndLandscape() throws {
        let app = launch(reader: true)
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
        app.buttons["Reading Appearance"].tap()
        XCTAssertTrue(app.switches["Bold Font"].waitForExistence(timeout: 3))
        capture("appearance-sheet", app: app)
        app.buttons["Done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Reading Speed"].waitForExistence(timeout: 3))
        capture("reader-landscape", app: app)
        app.buttons["Reading Speed"].tap()
        XCTAssertTrue(app.buttons["Increase reading speed"].waitForExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.switches.firstMatch.exists)
        capture("speed-landscape", app: app)
    }

    @MainActor func testLargeTextSheetReachability() throws {
        let app = launch(reader: true, extra: ["--ui-experiment-large-text"])
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
        capture("reader-largest-text", app: app)
        app.buttons["Reading Appearance"].tap()
        for _ in 0..<4 where !app.switches["Bold Font"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.switches["Bold Font"].isHittable)
        capture("appearance-largest-text", app: app)
        app.buttons["Done"].tap()
        app.buttons["Reading Speed"].tap()
        for _ in 0..<4 where !app.switches.firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.switches.firstMatch.isHittable)
        capture("speed-largest-text", app: app)
    }

    @MainActor func testFolderManualImportAndCrossFolderSearch() throws {
        let app = launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Experiment Book")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Experiment Book")).firstMatch.tap()
        app.buttons["Add to Experiment Book"].tap()
        app.buttons["Type or Paste Text"].tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        app.textFields["Title"].tap(); app.textFields["Title"].typeText("Imported Into Folder")
        app.textViews.firstMatch.tap(); app.textViews.firstMatch.typeText("A chapter imported into the selected folder.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Imported Into Folder"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Search All Chapters"].tap()
        app.textFields["Search all chapters"].tap()
        app.textFields["Search all chapters"].typeText("Imported Into Folder")
        XCTAssertTrue(app.staticTexts["Imported Into Folder"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Experiment Book"].exists)
        capture("folder-search-result", app: app)
    }

    @MainActor func testInvalidURLRecoveryAndShortStatistics() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: 5))
        app.buttons["Add to Library"].tap()
        app.buttons["Paste Link"].tap()
        let field = app.textFields["https://example.com/chapter-1"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("file:///invalid")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.staticTexts["Enter a complete http or https link with a website address."].waitForExistence(timeout: 3))
        capture("invalid-link-recovery", app: app)
        app.buttons["Cancel"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Clear Unused Cached Audio"].waitForExistence(timeout: 3))
        app.buttons["Listening Statistics"].tap()
        XCTAssertTrue(app.staticTexts["Last 7 Days"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["<1 min"].firstMatch.exists)
        app.buttons["Last Year"].tap()
        XCTAssertTrue(app.staticTexts["Last Year"].exists)
        capture("statistics-year", app: app)
    }
    @MainActor func testPhysicalPlaybackSeekingAndBackgroundHandoff() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Metal synthesis and background handoff require a physical iPhone")
        #else
        let app = launch(reader: true, extra: ["-voicePreferences.schemaVersion", "1", "-voicePreferences.primary.kind", "kokoro", "-voicePreferences.primary.identifier", "af_heart"])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let position = app.otherElements["Playback Position"]
        let originalValue = position.value as? String ?? ""
        print("Playback initial value:", String(describing: position.value))
        app.buttons["Play"].tap()
        let progressed = NSPredicate { _, _ in
            let value = position.value as? String ?? ""
            return !value.isEmpty && value != originalValue
        }
        let started = XCTNSPredicateExpectation(predicate: progressed, object: nil)
        let result = XCTWaiter.wait(for: [started], timeout: 45)
        print("Playback final value:", String(describing: position.value))
        if result != .completed { print(app.debugDescription) }
        capture("device-playback-diagnostic", app: app)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(app.alerts["Generation Error"].exists)
        app.buttons["Skip Forward 15 Seconds"].tap()
        capture("device-playing-and-seeking", app: app)
        for _ in 0..<2 {
            let before = position.value as? String ?? ""
            XCUIDevice.shared.press(.home)
            // The handoff needs a real background interval, independent of UI idleness.
            let interval = expectation(description: "Background interval")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { interval.fulfill() }
            wait(for: [interval], timeout: 7)
            app.activate()
            XCTAssertFalse(app.alerts["Generation Error"].exists)
            let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (position.value as? String ?? "") != before
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        }
        let beforeScrubbing = position.value as? String
        let scrubStart = position.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25))
        let scrubEnd = position.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.25))
        scrubStart.press(forDuration: 0.1, thenDragTo: scrubEnd)
        let scrubbed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != beforeScrubbing
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrubbed], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["Generation Error"].exists)
        XCTAssertTrue(app.buttons["Pause Playback"].waitForExistence(timeout: 5))
        capture("device-edge-slider", app: app)
        app.textViews.firstMatch.swipeUp()
        let returnButton = app.buttons["Return to Current Word"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 1))
        let wordFrame = returnButton.frame
        let spokenWord = returnButton.value as? String ?? ""
        XCTAssertFalse(spokenWord.isEmpty)
        let changingWord = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = returnButton.value as? String ?? ""
            return !value.isEmpty && value != spokenWord
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changingWord], timeout: 1.5), .completed)
        XCTAssertEqual(returnButton.frame.width, wordFrame.width, accuracy: 1)
        XCTAssertEqual(returnButton.frame.minY, wordFrame.minY, accuracy: 1)
        returnButton.tap()
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 2))
        app.textViews.firstMatch.swipeUp()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 1))
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 6), "Playing automatically returns after inactivity")
        app.textViews.firstMatch.swipeUp()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 1))
        app.buttons["Pause Playback"].tap()
        let pausedWord = returnButton.value as? String
        let pauseInterval = expectation(description: "Paused browsing stays put")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { pauseInterval.fulfill() }
        wait(for: [pauseInterval], timeout: 5)
        XCTAssertTrue(returnButton.exists)
        XCTAssertEqual(returnButton.value as? String, pausedWord)
        capture("device-paused-return-word", app: app)
        returnButton.tap()
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 2))
        app.buttons["Reading Appearance"].tap()
        XCTAssertTrue(app.switches["Bold Font"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        capture("device-returned-and-paused", app: app)
        app.buttons["Minimize Player"].tap()
        let reopen = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open player for")).firstMatch
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
        capture("device-minimize-reopen", app: app)
        app.buttons["Stop Playback and Close Player"].tap()
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: 5))
        #endif
    }

}
