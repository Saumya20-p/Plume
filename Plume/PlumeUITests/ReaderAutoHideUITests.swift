import XCTest

final class ReaderAutoHideUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(extra: [String] = [], enabled: Bool = true, suite: String? = nil, reset: Bool = true,
                                   simulated: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-experiment-fixture", "--ui-experiment-reader",
                               "-appearance.selectedTheme", "Muted"]
        app.launchArguments += simulated ? ["--ui-experiment-auto-hide"] : ["--ui-experiment-apple-speech"]
        if enabled { app.launchArguments += ["--ui-experiment-auto-hide-on"] }
        if let suite {
            app.launchArguments += ["--ui-experiment-appearance-suite", suite]
            if reset { app.launchArguments += ["--ui-experiment-reset-appearance"] }
        }
        app.launchArguments += extra
        app.launch()
        return app
    }

    @MainActor private func waitState(_ app: XCUIApplication, _ state: String, timeout: TimeInterval = 7) {
        let value = app.staticTexts["fixture.controlsVisibility"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", state), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    @MainActor private func assertDoesNotHide(_ app: XCUIApplication, seconds: TimeInterval = 4.4) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'hidden'"),
                                                    object: app.staticTexts["fixture.controlsVisibility"])
        expectation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: seconds), .completed)
    }

    @MainActor private func tapPage(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
    }

    @MainActor private func browse(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    }

    @MainActor private func geometry(_ app: XCUIApplication) throws -> [String: Double] {
        let value = try XCTUnwrap(app.staticTexts["fixture.readerGeometry"].value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Double])
    }

    @MainActor func testStationaryReaderKeepsWindowPosition() throws {
        let app = launch(extra: ["--ui-experiment-stationary-markers", "--ui-experiment-reduce-motion"])
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 3))
        let before = try geometry(app)
        waitState(app, "hidden")
        let after = try geometry(app)
        for key in ["readerTop", "readerBottom", "dockWindowBottom", "offset", "top", "bottom"] {
            XCTAssertEqual(try XCTUnwrap(after[key]), try XCTUnwrap(before[key]), accuracy: 1, "Window geometry changed: \(key)")
        }
    }

    @MainActor func testHideRevealBrowseSyncAndAutomaticReturn() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].exists, "Visual markers must not start actual speech")
        let initial = try geometry(app)
        waitState(app, "hidden")
        XCTAssertFalse(app.buttons["Reading Appearance"].exists)
        XCTAssertFalse(app.buttons["Stop Playback and Close Player"].exists)
        let hidden = try geometry(app)
        XCTAssertEqual(hidden["sharp"], 1)
        XCTAssertEqual(hidden["mirrorAlpha"], 0)
        XCTAssertEqual(try XCTUnwrap(hidden["top"]), try XCTUnwrap(initial["top"]), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(hidden["bottom"]), try XCTUnwrap(initial["bottom"]), accuracy: 1)
        tapPage(app)
        waitState(app, "visible")
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 2))
        XCTAssertEqual(try XCTUnwrap(geometry(app)["dockBottom"]), try XCTUnwrap(initial["dockBottom"]), accuracy: 1)
        browse(app)
        let sync = app.buttons["Return to Current Word"]
        XCTAssertTrue(sync.waitForExistence(timeout: 2))
        XCTAssertEqual(try XCTUnwrap(geometry(app)["dockTop"]), try XCTUnwrap(initial["dockTop"]), accuracy: 1)
        sync.tap()
        XCTAssertTrue(sync.waitForNonExistence(timeout: 2))
        waitState(app, "hidden")
        browse(app)
        XCTAssertTrue(sync.waitForExistence(timeout: 2))
        XCTAssertTrue(sync.waitForNonExistence(timeout: 5), "Existing automatic browsing return must remain active")
        waitState(app, "hidden")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "auto-hide-sharp-reader"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testPreferencePersistsAndSheetsHoldControlsAcrossThemes() throws {
        let suite = "ReaderAutoHideUITests.\(UUID())"
        var app = launch(suite: suite)
        app.buttons["Reading Appearance"].press(forDuration: 4.5)
        let toggle = app.switches["appearance.autoHideReaderControls"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        for theme in ["Basic", "Warm", "Muted"] {
            app.buttons["\(theme) theme"].tap()
            XCTAssertTrue(app.buttons["\(theme) theme"].isSelected)
        }
        // A presented sheet holds the policy even as visual markers continue.
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0", "The switch must actually turn off before testing visibility")
        app.buttons["Done"].tap()
        waitState(app, "visible")
        assertDoesNotHide(app)
        app.terminate()
        app = launch(enabled: false, suite: suite, reset: false)
        assertDoesNotHide(app)
        app.buttons["Reading Appearance"].tap()
        XCTAssertEqual(app.switches["appearance.autoHideReaderControls"].value as? String, "0")
        app.switches["appearance.autoHideReaderControls"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        waitState(app, "hidden")
        for label in ["Reading Speed", "Choose Voice", "Up Next"] {
            tapPage(app)
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 2))
            app.buttons[label].tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 4))
            app.buttons["Done"].tap()
            waitState(app, "visible")
        }
    }

    @MainActor func testPausedMarkersBackgroundAndAccessibilityGates() throws {
        var app = launch(extra: ["--ui-experiment-reduce-motion", "--ui-experiment-reduce-transparency"])
        waitState(app, "hidden")
        app.buttons["fixture.markerPlayback"].tap()
        waitState(app, "visible")
        assertDoesNotHide(app)
        app.buttons["fixture.markerPlayback"].tap()
        waitState(app, "hidden")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitState(app, "visible", timeout: 2)
        waitState(app, "hidden")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitState(app, "visible", timeout: 2)
        waitState(app, "hidden")
        app.terminate()
        // This tests the production VoiceOver eligibility gate, not spoken navigation.
        app = launch(extra: ["--ui-experiment-voiceover", "--ui-experiment-large-text"])
        assertDoesNotHide(app)
        XCTAssertTrue(app.buttons["Reading Appearance"].exists)
        XCTAssertTrue(app.buttons["Stop Playback and Close Player"].exists)
    }

    @MainActor func testChapterChangeAndMarkerCompletionRestoreControls() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Minimize Player"].waitForExistence(timeout: 4))
        app.buttons["Minimize Player"].tap()
        let next = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A Standalone Chapter'")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        next.tap()
        XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 3))
        waitState(app, "hidden")
        waitState(app, "visible", timeout: 6)
        XCTAssertEqual(app.buttons["fixture.markerPlayback"].label, "Resume markers")
        XCTAssertTrue(app.buttons["Reading Appearance"].exists)
        XCTAssertTrue(app.buttons["Play"].exists)
    }

    @MainActor func testActualApplePlaybackPauseSeekAndScrub() throws {
        let app = launch(simulated: false)
        let pause = app.buttons["Pause Playback"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "Apple speech must actually start")
        let appearance = app.buttons["Reading Appearance"]
        XCTAssertTrue(appearance.waitForNonExistence(timeout: 10), "Actual marker following should permit hiding")
        tapPage(app)
        XCTAssertTrue(pause.waitForExistence(timeout: 2))
        pause.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(appearance.exists)
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        app.buttons["Skip Forward 15 Seconds"].tap()
        XCTAssertTrue(appearance.exists)
        let scrubber = app.otherElements["Playback Position"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 2))
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 4.5, thenDragTo: end)
        XCTAssertTrue(appearance.exists, "The dock must not disappear during a held scrub")
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        tapPage(app) // A visible word tap retains its seek-and-play behavior.
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
    }
}
