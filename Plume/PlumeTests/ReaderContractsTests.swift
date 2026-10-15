import Foundation
import Testing
@testable import Plume

struct ReaderContractsTests {
    @Test("Current word preserves full tokens and attached punctuation", arguments: [
        ("I", "I"),
        ("  extraordinary\n", "extraordinary"),
        ("pneumonoultramicroscopicsilicovolcanoconiosis", "pneumonoultramicroscopicsilicovolcanoconiosis"),
        ("“Hello,”", "“Hello,”"),
        ("can't", "can't"),
        ("mother-in-law", "mother-in-law"),
        ("cafe\u{301}", "cafe\u{301}"),
        ("你好。", "你好。"),
        ("مرحبا،", "مرحبا،"),
        ("１２３", "１２３"),
        ("Ⅷ", "Ⅷ"),
        (" 42! ", "42!")
    ])
    func testValidCurrentWordDisplay(word: String, expected: String) {
        var display = ReaderWordDisplay()
        display.update(word: word, documentID: UUID(), isPaused: false)
        #expect(display.currentWordValue == expected)
        #expect(display.displayText == expected)
    }

    @Test("Unavailable and non-word values use the descriptive fallback", arguments: [
        nil, "", " \n\t", ".", "…", "—", "?!", "👋", "\u{301}",
        "two words", "two\twords", "two\nwords", "two\u{00A0}words", "two\u{2003}words"
    ] as [String?])
    func testInvalidCurrentWordDisplay(word: String?) {
        var display = ReaderWordDisplay()
        display.update(word: word, documentID: UUID(), isPaused: false)
        #expect(display.currentWordValue == nil)
        #expect(display.displayText == "Return to Current Word")
    }

    @Test("Playback gaps retain the latest word until another valid token arrives", arguments: [
        nil, "", " \n\t", "…", "?!", "two words", "👋"
    ] as [String?])
    func testPlaybackGapsRetainLatestWord(word: String?) {
        let documentID = UUID()
        var display = ReaderWordDisplay()
        display.update(word: "previous", documentID: documentID, isPaused: false)
        display.update(word: word, documentID: documentID, isPaused: false)
        #expect(display.currentWordValue == "previous")
        #expect(display.displayText == "previous")

        display.update(word: word, documentID: documentID, isPaused: true)
        #expect(display.currentWordValue == "previous")
        #expect(display.displayText == "previous")
        display.update(word: "next", documentID: documentID, isPaused: false)
        #expect(display.displayText == "next")
    }

    @Test
    func testPauseRetainsLatestWordAndResumeUsesCurrentInput() {
        let documentID = UUID()
        var display = ReaderWordDisplay()
        display.update(word: "first", documentID: documentID, isPaused: false)
        display.update(word: nil, documentID: documentID, isPaused: true)
        #expect(display.displayText == "first")

        display.update(word: " second! ", documentID: documentID, isPaused: true)
        display.update(word: "", documentID: documentID, isPaused: true)
        #expect(display.currentWordValue == "second!")
        #expect(display.displayText == "second!")

        display.update(word: nil, documentID: documentID, isPaused: false)
        #expect(display.displayText == "second!")
        display.update(word: "third", documentID: documentID, isPaused: false)
        #expect(display.displayText == "third")
    }

    @Test("Changing chapters clears word history even while paused", arguments: [false, true])
    func testDocumentChangeResetsCurrentWordCache(isPaused: Bool) {
        let firstDocument = UUID()
        let secondDocument = UUID()
        var display = ReaderWordDisplay()
        display.update(word: "first", documentID: firstDocument, isPaused: false)
        display.update(word: nil, documentID: secondDocument, isPaused: isPaused)
        #expect(display.currentWordValue == nil)
        #expect(display.displayText == "Return to Current Word")

        display.update(word: nil, documentID: firstDocument, isPaused: true)
        #expect(display.displayText == "Return to Current Word")
        display.update(word: "new", documentID: secondDocument, isPaused: true)
        display.update(word: nil, documentID: secondDocument, isPaused: true)
        #expect(display.displayText == "new")
    }

    @Test
    func testPausedWithoutAnyValidWordUsesFallback() {
        var display = ReaderWordDisplay()
        #expect(display.currentWordValue == nil)
        #expect(display.displayText == "Return to Current Word")
        display.update(word: nil, documentID: UUID(), isPaused: true)
        #expect(display.displayText == "Return to Current Word")
    }

    @Test("Saved-position words use UTF-16 reader coordinates", arguments: [
        ("First second", 0, "First"),
        ("First second", 3, "First"),
        ("First second", 5, "second"),
        ("First, — second!", 5, "second"),
        ("First, — second!", 8, "second"),
        ("First second!", 13, "second"),
        ("First second!", 12, "second"),
        ("cafe\u{301} next", 4, "cafe\u{301}"),
        ("👩🏽‍🚀 café next", 2, "café"),
        ("你好 世界", 1, "你好"),
        ("can't stop", 3, "can't"),
        ("mother-in-law next", 7, "mother-in-law"),
        ("Hi", -1, nil),
        ("Hi", 3, nil),
        ("", 0, nil),
        ("... ", 4, nil)
    ] as [(String, Int, String?)])
    func testSavedPositionResolution(text: String, offset: Int, expected: String?) {
        #expect(ReaderWordDisplay.word(in: text, atUTF16Offset: offset) == expected)
    }

    @Test
    func testSavedPositionInitializesOnceAndAuthoritativeMarkerWins() {
        let document = UUID()
        var display = ReaderWordDisplay()
        display.update(word: nil, documentID: document, isPaused: true,
                       text: "First second third", savedPosition: 6)
        #expect(display.displayText == "second")
        display.update(word: "third", documentID: document, isPaused: false,
                       text: "First second third", rangeLocation: 13, savedPosition: 6)
        display.update(word: nil, documentID: document, isPaused: false,
                       text: "First second third", savedPosition: 6)
        #expect(display.displayText == "third")
        display.update(word: "", documentID: document, isPaused: false,
                       text: "First second third", rangeLocation: 0, savedPosition: 6)
        #expect(display.displayText == "third")

        var authoritative = ReaderWordDisplay()
        authoritative.update(word: "", documentID: document, isPaused: true,
                             text: "First second third", rangeLocation: 13, savedPosition: 6)
        #expect(authoritative.displayText == "third")
        var invalidMarker = ReaderWordDisplay()
        invalidMarker.update(word: "", documentID: document, isPaused: true,
                             text: "First second third", rangeLocation: 999, savedPosition: 6)
        #expect(invalidMarker.currentWordValue == nil)
    }

    @Test
    func testMissingPlaybackOwnershipDoesNotConsumePositionInitialization() {
        let document = UUID()
        var display = ReaderWordDisplay()
        display.update(word: nil, documentID: document, isPaused: true)
        #expect(display.currentWordValue == nil)
        display.update(word: "", documentID: document, isPaused: true,
                       text: "First second", rangeLocation: 6, savedPosition: 0)
        #expect(display.displayText == "second")
    }

    @Test
    func testSavedPositionIsReinitializedAcrossAToBToAWithoutWordLeak() {
        let first = UUID()
        let second = UUID()
        var display = ReaderWordDisplay()
        display.update(word: "advanced", documentID: first, isPaused: false)
        display.update(word: nil, documentID: second, isPaused: false, text: "", savedPosition: 0)
        #expect(display.currentWordValue == nil)
        display.update(word: nil, documentID: first, isPaused: true,
                       text: "First returned", savedPosition: 6)
        #expect(display.displayText == "returned")
    }

    @Test
    func testNewAndLegacyPreferencesKeepGeorgiaAndPersistMigration() throws {
        let suite = "ReaderContractsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReaderFont.migratedPreference(in: defaults) == .georgia)
        #expect(defaults.string(forKey: ReaderFont.preferenceKey) == "Georgia")
        defaults.removeObject(forKey: ReaderFont.preferenceKey)
        defaults.set("Rounded", forKey: "appearance.fontStyle")
        defaults.set("Georgia", forKey: "appearance.fontFamily")
        #expect(ReaderFont.migratedPreference(in: defaults) == .georgia)
    }

    @Test
    func testExplicitModernFontSurvivesMigration() throws {
        let suite = "ReaderContractsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for font in ReaderFont.allCases {
            defaults.set(font.rawValue, forKey: ReaderFont.preferenceKey)
            #expect(ReaderFont.migratedPreference(in: defaults) == font)
        }
    }

    @Test
    func testFollowWaitsThreeSecondsAfterDecelerationAndRejectsOldDeadline() {
        var state = ReaderFollowContract()
        state.setAutoResumeAllowed(true, now: 0)
        state.beginInteraction()
        #expect(state.deadline == nil)
        state.endInteraction(now: 10)
        let oldRevision = state.revision
        #expect(state.deadline == 13)
        let resumeResult1 = state.resumeIfDue(now: 12.9, revision: oldRevision)
        #expect(!resumeResult1)
        state.beginInteraction()
        state.endInteraction(now: 12)
        let resumeResult2 = state.resumeIfDue(now: 15, revision: oldRevision)
        #expect(!resumeResult2)
        let resumeResult3 = state.resumeIfDue(now: 15, revision: state.revision)
        #expect(resumeResult3)
        #expect(!state.isBrowsing)
    }

    @Test
    func testPausingBackgroundAndSheetsSuspendAndRestartFullInterval() {
        var state = ReaderFollowContract()
        state.setAutoResumeAllowed(true, now: 0)
        state.beginInteraction()
        state.endInteraction(now: 1)
        let oldRevision = state.revision
        state.setAutoResumeAllowed(false, now: 2)
        #expect(state.deadline == nil)
        #expect(state.isBrowsing)
        let resumeResult4 = state.resumeIfDue(now: 100, revision: oldRevision)
        #expect(!resumeResult4)
        state.setAutoResumeAllowed(true, now: 100)
        #expect(state.deadline == 103)
        let resumeResult5 = state.resumeIfDue(now: 102, revision: state.revision)
        #expect(!resumeResult5)
        let resumeResult6 = state.resumeIfDue(now: 103, revision: state.revision)
        #expect(resumeResult6)
    }

    @Test
    func testReturnWorksImmediatelyWhilePausedAndInvalidatesPendingResume() {
        var state = ReaderFollowContract()
        state.beginInteraction()
        state.endInteraction(now: 1)
        #expect(state.isBrowsing)
        #expect(state.deadline == nil)
        let oldRevision = state.revision
        state.returnToCurrentWord()
        #expect(!state.isBrowsing)
        #expect(!state.isInteracting)
        let resumeResult7 = state.resumeIfDue(now: 100, revision: oldRevision)
        #expect(!resumeResult7)
    }
}
