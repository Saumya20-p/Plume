import Foundation
import Testing
@testable import Plume

struct ReaderControlsVisibilityTests {
    private func eligible() -> ReaderControlsContext {
        ReaderControlsContext(documentID: UUID(), enabled: true, readerVisible: true,
                              sceneActive: true, playing: true, following: true)
    }

    @Test func waitsFourSecondsAndIgnoresOrdinaryProgress() {
        var state = ReaderControlsVisibilityPolicy()
        let context = eligible()
        state.update(context, now: 10)
        let revision = state.revision
        #expect(state.state == .waiting)
        #expect(state.deadline == 14)
        for now in [10.1, 11, 12, 13] { state.update(context, now: now) }
        #expect(state.revision == revision)
        let result1 = state.hideIfDue(now: 13.999, revision: revision, documentID: context.documentID)
        #expect(!result1)
        let result2 = state.hideIfDue(now: 14, revision: revision, documentID: context.documentID)
        #expect(result2)
        state.update(context, now: 15)
        #expect(state.state == .hidden)
        #expect(state.deadline == nil)
    }

    @Test(arguments: ["preference", "reader", "scene", "playback", "follow", "interaction", "seek", "presentation", "voiceover"])
    func blockersRevealAndInvalidateDeadline(blocker: String) {
        var state = ReaderControlsVisibilityPolicy()
        var context = eligible()
        state.update(context, now: 0)
        let revision = state.revision
        let result3 = state.hideIfDue(now: 4, revision: revision, documentID: context.documentID)
        #expect(result3)
        let original = context
        switch blocker {
        case "preference": context.enabled = false
        case "reader": context.readerVisible = false
        case "scene": context.sceneActive = false
        case "playback": context.playing = false
        case "follow": context.following = false
        case "interaction": context.interacting = true
        case "seek": context.seeking = true
        case "presentation": context.presenting = true
        default: context.voiceOver = true
        }
        state.update(context, now: 5)
        #expect(state.state == .held)
        #expect(state.deadline == nil)
        let result4 = state.hideIfDue(now: 100, revision: revision, documentID: context.documentID)
        #expect(!result4)
        state.update(original, now: 100)
        #expect(state.deadline == 104)
    }

    @Test func repeatedInteractionAndChapterChangeRejectStaleDeadlines() {
        var state = ReaderControlsVisibilityPolicy()
        var context = eligible()
        state.update(context, now: 0)
        let firstRevision = state.revision
        for index in 1...100 { state.reveal(now: Double(index)) }
        #expect(state.deadline == 104)
        let result5 = state.hideIfDue(now: 104, revision: firstRevision, documentID: context.documentID)
        #expect(!result5)
        let oldChapter = context.documentID
        let oldRevision = state.revision
        context.documentID = UUID()
        state.update(context, now: 105)
        #expect(state.deadline == 109)
        let result6 = state.hideIfDue(now: 200, revision: oldRevision, documentID: oldChapter)
        #expect(!result6)
        let result7 = state.hideIfDue(now: 200, revision: state.revision, documentID: oldChapter)
        #expect(!result7)
    }

    @Test func browsingReturnAndHidingUseSeparateFullIntervals() {
        var follow = ReaderFollowContract()
        follow.setAutoResumeAllowed(true, now: 0)
        var visibility = ReaderControlsVisibilityPolicy()
        var context = eligible()
        visibility.update(context, now: 0)
        follow.beginInteraction()
        context.following = false
        visibility.update(context, now: 1)
        follow.endInteraction(now: 10)
        #expect(follow.deadline == 13)
        #expect(visibility.deadline == nil)
        let result8 = follow.resumeIfDue(now: 13, revision: follow.revision)
        #expect(result8)
        context.following = true
        visibility.update(context, now: 13)
        #expect(visibility.deadline == 17)
        follow.beginInteraction()
        context.following = false
        visibility.update(context, now: 14)
        follow.returnToCurrentWord()
        context.following = true
        visibility.update(context, now: 15)
        #expect(visibility.deadline == 19)
    }

    @MainActor @Test func preferenceDefaultsOffAndPersistsBothValues() throws {
        let suite = "ReaderControlsVisibilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppearanceManager(defaults: defaults)
        #expect(!first.autoHideReaderControls)
        first.autoHideReaderControls = true
        #expect(AppearanceManager(defaults: defaults).autoHideReaderControls)
        first.autoHideReaderControls = false
        #expect(!AppearanceManager(defaults: defaults).autoHideReaderControls)
    }

    /// Deliberately completes cancelled sleeps too, exercising the owner's
    /// cancellation/revision defenses rather than trusting a cooperative clock.
    @MainActor private final class ManualSleeper {
        var now: TimeInterval = 0
        var continuations: [CheckedContinuation<Void, Never>] = []
        let requests: AsyncStream<Int>
        let sender: AsyncStream<Int>.Continuation
        init() { (requests, sender) = AsyncStream.makeStream(of: Int.self) }
        func sleep(_ delay: TimeInterval) async {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                sender.yield(continuations.count - 1)
            }
        }
        func finish(_ index: Int) { continuations[index].resume() }
    }

    @MainActor @Test func cancelledSleepCannotHideAfterAnotherInteractionOrStop() async {
        let sleeper = ManualSleeper()
        let controller = ReaderControlsVisibility(now: { sleeper.now }, sleep: { await sleeper.sleep($0) })
        var requests = sleeper.requests.makeAsyncIterator()
        controller.update(eligible())
        _ = await requests.next()
        sleeper.now = 2
        controller.reveal()
        _ = await requests.next()
        sleeper.now = 4
        sleeper.finish(0)
        await Task.yield()
        #expect(!controller.isHidden)
        #expect(controller.policy.deadline == 6)
        controller.stop()
        sleeper.now = 20
        sleeper.finish(1)
        await Task.yield()
        #expect(!controller.isHidden)
        #expect(controller.policy.deadline == nil)
    }
}
