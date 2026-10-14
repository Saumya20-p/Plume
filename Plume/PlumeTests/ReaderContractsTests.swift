import Foundation
import XCTest
@testable import Plume

final class ReaderContractsTests: XCTestCase {
    func testNewAndLegacyPreferencesKeepGeorgiaAndPersistMigration() throws {
        let suite = "ReaderContractsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderFont.migratedPreference(in: defaults), .georgia)
        XCTAssertEqual(defaults.string(forKey: ReaderFont.preferenceKey), "Georgia")
        defaults.removeObject(forKey: ReaderFont.preferenceKey)
        defaults.set("Rounded", forKey: "appearance.fontStyle")
        defaults.set("Georgia", forKey: "appearance.fontFamily")
        XCTAssertEqual(ReaderFont.migratedPreference(in: defaults), .georgia)
    }

    func testExplicitModernFontSurvivesMigration() throws {
        let suite = "ReaderContractsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for font in ReaderFont.allCases {
            defaults.set(font.rawValue, forKey: ReaderFont.preferenceKey)
            XCTAssertEqual(ReaderFont.migratedPreference(in: defaults), font)
        }
    }

    func testFollowWaitsThreeSecondsAfterDecelerationAndRejectsOldDeadline() {
        var state = ReaderFollowContract()
        state.setAutoResumeAllowed(true, now: 0)
        state.beginInteraction()
        XCTAssertNil(state.deadline)
        state.endInteraction(now: 10)
        let oldRevision = state.revision
        XCTAssertEqual(state.deadline, 13)
        XCTAssertFalse(state.resumeIfDue(now: 12.9, revision: oldRevision))
        state.beginInteraction()
        state.endInteraction(now: 12)
        XCTAssertFalse(state.resumeIfDue(now: 15, revision: oldRevision))
        XCTAssertTrue(state.resumeIfDue(now: 15, revision: state.revision))
        XCTAssertFalse(state.isBrowsing)
    }

    func testPausingBackgroundAndSheetsSuspendAndRestartFullInterval() {
        var state = ReaderFollowContract()
        state.setAutoResumeAllowed(true, now: 0)
        state.beginInteraction()
        state.endInteraction(now: 1)
        let oldRevision = state.revision
        state.setAutoResumeAllowed(false, now: 2)
        XCTAssertNil(state.deadline)
        XCTAssertTrue(state.isBrowsing)
        XCTAssertFalse(state.resumeIfDue(now: 100, revision: oldRevision))
        state.setAutoResumeAllowed(true, now: 100)
        XCTAssertEqual(state.deadline, 103)
        XCTAssertFalse(state.resumeIfDue(now: 102, revision: state.revision))
        XCTAssertTrue(state.resumeIfDue(now: 103, revision: state.revision))
    }

    func testReturnWorksImmediatelyWhilePausedAndInvalidatesPendingResume() {
        var state = ReaderFollowContract()
        state.beginInteraction()
        state.endInteraction(now: 1)
        XCTAssertTrue(state.isBrowsing)
        XCTAssertNil(state.deadline)
        let oldRevision = state.revision
        state.returnToCurrentWord()
        XCTAssertFalse(state.isBrowsing)
        XCTAssertFalse(state.isInteracting)
        XCTAssertFalse(state.resumeIfDue(now: 100, revision: oldRevision))
    }
}
