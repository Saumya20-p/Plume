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

    @MainActor private func browseReader(_ app: XCUIApplication) {
        // UITextView extends beneath the header and dock; drag only the passage.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    }

    @MainActor func testFinalParagraphBlurAndFollow() throws {
        for wrapped in [false, true] {
            let variant = wrapped ? "wrapped" : "short"
            let app = launch(reader: true, theme: "Muted", extra:
                ["--ui-experiment-final-paragraph"] + (wrapped ? ["--ui-experiment-wrapped-final"] : []))
            let markers = app.buttons["fixture.visualMarkers"]
            XCTAssertTrue(markers.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Play"].exists, "Visual markers must not claim audio playback")
            let window = app.windows.firstMatch
            // Bring the active highlight through the dock's transition while
            // playback is paused. This must remain ordinary manual browsing.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.77)), withVelocity: .slow, thenHoldForDuration: 0.2)
            let returnButton = app.buttons["Return to Current Word"]
            XCTAssertTrue(returnButton.waitForExistence(timeout: 3))
            capture("final-\(variant)-manual-transition-Muted", app: app)
            returnButton.tap()
            XCTAssertTrue(returnButton.waitForNonExistence(timeout: 3))
            markers.tap()
            let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Run visual markers"), object: markers)
            XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 25), .completed)
            XCTAssertTrue(app.buttons["Play"].exists)
            capture("final-\(variant)-completed-Muted", app: app)
            // After visual completion, browsing stays paused until Return.
            browseReader(app)
            XCTAssertTrue(returnButton.waitForExistence(timeout: 3))
            XCTAssertEqual(returnButton.value as? String, wrapped ? "end" : "clear")
            returnButton.tap()
            XCTAssertTrue(returnButton.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor func testSavedPositionAndCompactReturn() throws {
        for theme in ["Basic", "Warm", "Muted"] {
            let app = launch(reader: true, theme: theme, extra: ["--ui-experiment-restored-position", "--ui-experiment-position"])
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Saved position must resolve before pressing Play")
            capture("saved-before-play-\(theme)", app: app)
            browseReader(app)
            let button = app.buttons["Return to Current Word"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            XCTAssertEqual(button.value as? String, "Morning")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThan(button.frame.width, app.windows.firstMatch.frame.width * 0.8)
            XCTAssertEqual(button.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
            capture("saved-compact-return-\(theme)", app: app)
            button.tap()
            XCTAssertTrue(button.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Play"].exists)
            app.terminate()
        }
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
            browseReader(app)
            XCTAssertTrue(app.buttons["Return to Current Word"].waitForExistence(timeout: 3))
            let returnButton = app.buttons["Return to Current Word"]
            XCTAssertEqual(returnButton.value as? String, "The")
            XCTAssertGreaterThanOrEqual(returnButton.frame.height, 44)
            XCTAssertLessThan(returnButton.frame.width, app.windows.firstMatch.frame.width * 0.8)
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
            browseReader(app)
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
        browseReader(app)
        let returnButton = app.buttons["Return to Current Word"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 3))
        XCTAssertEqual(returnButton.value as? String, "The")
        XCTAssertGreaterThanOrEqual(returnButton.frame.height, 44)
        XCTAssertLessThanOrEqual(returnButton.frame.width, app.windows.firstMatch.frame.width - 32)
        capture("reader-largest-return", app: app)
        returnButton.tap()
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 3))
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
    @MainActor func testDockRemainsFixedAcrossReaderBrowsing() throws {
        let app = launch(reader: true, extra: ["--ui-experiment-position"])
        let position = app.otherElements["Playback Position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let initialDock = position.frame
        browseReader(app)
        let pill = app.buttons["Return to Current Word"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertEqual(position.frame.minY, initialDock.minY, accuracy: 1)
        XCTAssertEqual(position.frame.height, initialDock.height, accuracy: 1)
        browseReader(app)
        XCTAssertEqual(pill.value as? String, "The")
        XCTAssertEqual(position.frame.minY, initialDock.minY, accuracy: 1)
        pill.tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 3))
        XCTAssertEqual(position.frame.minY, initialDock.minY, accuracy: 1)
    }

    @MainActor func testPhysicalWordTapSeekContinuity() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Audible word-tap continuity requires a physical iPhone")
        #else
        let app = launch(reader: true, extra: ["--playback-seek-diagnostics"])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let position = app.otherElements["Playback Position"]
        app.buttons["Play"].tap()
        let reachedSecondParagraph = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let time = (position.value as? String ?? "").components(separatedBy: " of ")[0].split(separator: ":").compactMap { Int($0) }
            return time.count == 2 && time[0] * 60 + time[1] >= 18
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reachedSecondParagraph], timeout: 60), .completed)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        let firstParagraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Paragraph 1.")).firstMatch
        XCTAssertTrue(firstParagraph.isHittable)
        firstParagraph.tap()
        try assertWordTapPlaybackAdvances(app, position: position)
        capture("word-tap-backward", app: app)
        // Move beyond the initial generated runway, then select visible passage text.
        for _ in 0..<6 { browseReader(app) }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4)).tap()
        try assertWordTapPlaybackAdvances(app, position: position)
        for x in [0.25, 0.45, 0.7] {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.4)).tap()
        }
        try assertWordTapPlaybackAdvances(app, position: position)
        capture("word-tap-latest-destination", app: app)
        app.buttons["Stop Playback and Close Player"].tap()
        #endif
    }

    @MainActor private func assertWordTapPlaybackAdvances(_ app: XCUIApplication, position: XCUIElement) throws {
        XCTAssertTrue(app.buttons["Pause Playback"].waitForExistence(timeout: 15))
        let before = position.value as? String
        let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 15), .completed,
                       "Word-tap playback must continue without pressing Play again")
        XCTAssertFalse(app.alerts["Generation Error"].exists)
    }

    @MainActor func testFocusedPhysicalPlayerRefinement() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Playback and startup responsiveness require a physical iPhone")
        #else
        let app = launch(reader: true, extra: ["-voicePreferences.schemaVersion", "1", "-voicePreferences.primary.kind", "kokoro", "-voicePreferences.primary.identifier", "af_heart"])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let position = app.otherElements["Playback Position"]
        let initial = position.value as? String
        app.buttons["Play"].tap()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != initial
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 45), .completed)
        XCTAssertFalse(app.alerts["Generation Error"].exists)
        let dockFrame = position.frame
        browseReader(app)
        let pill = app.buttons["Return to Current Word"]
        XCTAssertTrue(pill.waitForExistence(timeout: 1))
        XCTAssertEqual(position.frame.minY, dockFrame.minY, accuracy: 1)
        let token = pill.value as? String
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pill.exists && (pill.value as? String) != token
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.5), .completed)
        pill.tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 2))
        browseReader(app)
        XCTAssertTrue(pill.waitForExistence(timeout: 1))
        XCTAssertTrue(pill.waitForNonExistence(timeout: 6))
        app.buttons["Pause Playback"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2))
        app.buttons["Play"].tap()
        let beforeBackground = position.value as? String
        XCUIDevice.shared.press(.home)
        let interval = expectation(description: "One background handoff")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { interval.fulfill() }
        wait(for: [interval], timeout: 7)
        app.activate()
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != beforeBackground
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        app.buttons["Pause Playback"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2))
        // Both drags start in the middle and finish inside the screen.
        let middle = position.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let right = position.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: position.frame.width - 24, dy: 2))
        let left = position.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 2))
        middle.press(forDuration: 0.1, thenDragTo: right)
        let atEnd = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = (position.value as? String ?? "").replacingOccurrences(of: "approximately ", with: "").components(separatedBy: " of ")
            return parts.count == 2 && parts[0] == parts[1]
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atEnd], timeout: 5), .completed)
        capture("focused-device-endpoint-end", app: app)
        middle.press(forDuration: 0.1, thenDragTo: left)
        let atStart = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String ?? "").hasPrefix("0:00 of ")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atStart], timeout: 5), .completed)
        capture("focused-device-endpoint-start", app: app)
        app.buttons["Up Next"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["Stop Playback and Close Player"].tap()
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: 5))
        #endif
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
        // The compact dock leaves the curved top rim above the queue/X targets.
        // Exercise that strip, rather than dragging across the queue button.
        let scrubStart = position.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.05))
        let scrubEnd = position.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.05))
        scrubStart.press(forDuration: 0.1, thenDragTo: scrubEnd)
        let scrubbed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String) != beforeScrubbing
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrubbed], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["Generation Error"].exists)
        XCTAssertTrue(app.buttons["Pause Playback"].waitForExistence(timeout: 5))
        capture("device-edge-slider", app: app)
        browseReader(app)
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
        browseReader(app)
        XCTAssertTrue(returnButton.waitForExistence(timeout: 1))
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 6), "Playing automatically returns after inactivity")
        browseReader(app)
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
