import XCTest

final class UIExperimentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(reader: Bool = false, theme: String = "Warm", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-experiment-fixture", "-appearance.matchDevice", "NO", "-appearance.selectedTheme", theme] + (reader ? ["--ui-experiment-reader"] : []) + extra
        app.launch()
        return app
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testReaderThemesAndPausedReturn() throws {
        for theme in ["Basic", "Warm", "Muted"] {
            let app = launch(reader: true, theme: theme)
            XCTAssertTrue(app.buttons["Reading Appearance"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Minimize Player"].exists)
            XCTAssertTrue(app.buttons["Stop Playback and Close Player"].exists)
            XCTAssertTrue(app.otherElements["Playback Position"].exists)
            capture("reader-soft-\(theme)", app: app)
            app.textViews.firstMatch.swipeUp()
            XCTAssertTrue(app.buttons["Return to Current Word"].waitForExistence(timeout: 3))
            app.buttons["Return to Current Word"].tap()
            XCTAssertTrue(app.buttons["Return to Current Word"].waitForNonExistence(timeout: 3))
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
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Reading Speed"].waitForExistence(timeout: 3))
        capture("reader-landscape", app: app)
        app.buttons["Reading Speed"].tap()
        XCTAssertTrue(app.buttons["Increase reading speed"].waitForExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.switches.firstMatch.exists)
        capture("speed-landscape", app: app)
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
}
