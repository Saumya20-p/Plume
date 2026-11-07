import XCTest

final class LibraryWelcomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func fixtureArguments(empty: Bool = true) -> [String] {
        [
            "--ui-experiment-fixture",
            "--ui-experiment-appearance-suite", "LibraryWelcome-\(UUID().uuidString)",
            "--ui-experiment-reset-appearance"
        ] + (empty ? ["--ui-experiment-empty-library"] : [])
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments() + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func measureLaunch(empty: Bool, extra: [String] = []) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments(empty: empty) + extra
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
            app.terminate()
        }
    }

    @MainActor func testEmptyLibraryLaunchPerformance() throws { measureLaunch(empty: true) }

    @MainActor func testPopulatedLibraryLaunchPerformance() throws { measureLaunch(empty: false) }

    @MainActor func testHundredDocumentLaunchPerformance() throws {
        measureLaunch(empty: false, extra: ["--ui-experiment-startup-library"])
    }

    @MainActor func testThousandDocumentLaunchPerformance() throws {
        measureLaunch(empty: false, extra: ["--ui-experiment-startup-library", "--ui-experiment-large-library"])
    }

    @MainActor func testEmptyLibraryAddImportsTextAndRemovesWelcome() throws {
        let app = launch()
        defer { app.terminate() }
        let add = app.buttons["library.empty.add"]
        XCTAssertTrue(add.isHittable)
        capture("empty-library-before-import")
        add.tap()
        let paste = app.buttons["Type or Paste Text"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("My First Read")
        let text = app.textViews.firstMatch
        text.tap()
        text.typeText("A short passage imported through the Library welcome action.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["My First Read"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(add.exists)
    }

    @MainActor func testFolderOnlyLibraryDoesNotShowWelcome() throws {
        let app = launch()
        defer { app.terminate() }
        app.buttons["library.empty.add"].tap()
        let createFolder = app.buttons["Create Folder"]
        XCTAssertTrue(createFolder.waitForExistence(timeout: 3))
        createFolder.tap()
        let field = app.textFields["Folder Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("First Folder")
        app.alerts["New Folder"].buttons["Create"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "First Folder"))
            .firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["library.empty.title"].exists)
        XCTAssertFalse(app.buttons["library.empty.add"].exists)
    }

    @MainActor func testSearchAndFiltersKeepTheirRecoveryStates() throws {
        let app = launch()
        defer { app.terminate() }
        app.segmentedControls.buttons["Finished"].tap()
        XCTAssertTrue(app.staticTexts["No finished chapters"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["library.empty.title"].exists)
        let clear = app.buttons["Clear Search and Filters"]
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 3))
        app.buttons["Search All Chapters"].tap()
        let search = app.textFields["Search all chapters"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("No matching chapter")
        XCTAssertTrue(app.staticTexts["No search results"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["library.empty.title"].exists)
        XCTAssertFalse(app.buttons["library.empty.add"].exists)
        XCTAssertTrue(clear.exists)
        app.buttons["Clear Search"].tap()
        app.buttons["Close Search"].tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 3))
    }

    @MainActor func testReducedMotionLargeTextWelcomeRemainsReachableInLandscape() throws {
        let app = launch(extra: ["--ui-experiment-reduce-motion", "--ui-experiment-large-text"])
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        capture("empty-library-reduced-motion-largest-text-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        let add = app.buttons["library.empty.add"]
        capture("empty-library-reduced-motion-largest-text-landscape-before-scroll")
        let content = app.scrollViews.firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        for _ in 0..<6 {
            if add.isHittable { break }
            content.swipeUp()
        }
        XCTAssertTrue(add.isHittable, "Add must remain reachable by scrolling at the largest text size")
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        capture("empty-library-reduced-motion-largest-text-landscape")
        add.tap()
        XCTAssertTrue(app.buttons["Type or Paste Text"].waitForExistence(timeout: 3))
    }
    @MainActor func testTitleRevealTargetsEachLibraryShape() throws {
        for (arguments, target) in [
            (["--ui-experiment-empty-library"], "welcome"),
            (["--ui-experiment-startup-library"], "title"),
            (["--ui-experiment-folder-only"], "title")
        ] {
            let app = XCUIApplication()
            app.launchArguments = fixtureArguments(empty: false) + arguments
            app.launch()
            let title = app.descendants(matching: .any).matching(identifier: "library.title").firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "\(target):finished"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 3), .completed)
            XCTAssertTrue(app.navigationBars.buttons["Add to Library"].isHittable)
            capture("library-title-\(target)-\(arguments.last!)")
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertEqual(title.value as? String, "\(target):finished")
            app.terminate()
        }
    }

    @MainActor func testPopulatedLibraryNavigationAndReducedMotion() throws {
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments(empty: false) + [
            "--ui-experiment-startup-library", "--ui-experiment-reduce-motion"
        ]
        app.launch()
        defer { app.terminate() }
        let title = app.descendants(matching: .any).matching(identifier: "library.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "title:finished")
        XCTAssertFalse(app.staticTexts["library.empty.title"].exists)
        capture("populated-library-reduced-motion")
        app.buttons["Search All Chapters"].tap()
        XCTAssertTrue(app.textFields["Search all chapters"].waitForExistence(timeout: 3))
        app.buttons["Close Search"].tap()
        app.staticTexts["Startup Folder 1"].tap()
        XCTAssertTrue(app.staticTexts["Startup Chapter 96"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["Library"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.value as? String, "title:finished")
        app.navigationBars.buttons["Add to Library"].tap()
        XCTAssertTrue(app.buttons["Type or Paste Text"].waitForExistence(timeout: 3))
    }

    @MainActor func testLandscapeLaunchKeepsLibraryAvailable() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launchArguments = fixtureArguments(empty: false) + ["--ui-experiment-startup-library"]
        app.launch()
        let title = app.descendants(matching: .any).matching(identifier: "library.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.width, frame.height)
        XCTAssertTrue(app.navigationBars.buttons["Add to Library"].isHittable)
        capture("landscape-launch-library")
    }

}
