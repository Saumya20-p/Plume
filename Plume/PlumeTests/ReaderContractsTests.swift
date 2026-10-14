import Foundation
import Testing
@testable import Plume

struct ReaderContractsTests {
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
