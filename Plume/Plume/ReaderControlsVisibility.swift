import Foundation
import Observation

/// Changes only when follow readiness changes, never on every scroll or word.
nonisolated struct ReaderFollowStatus: Equatable {
    var documentID: UUID?
    var isBrowsing = false
    var isInteracting = false
    var hasDestination = false
}

nonisolated struct ReaderControlsContext: Equatable {
    var documentID: UUID?
    var enabled = false
    var readerVisible = false
    var sceneActive = false
    var playing = false
    var following = false
    var interacting = false
    var seeking = false
    var presenting = false
    var voiceOver = false

    var eligible: Bool {
        documentID != nil && enabled && readerVisible && sceneActive && playing && following &&
            !interacting && !seeking && !presenting && !voiceOver
    }
}

/// Pure monotonic-time policy. Following has its own existing resume contract;
/// this policy never changes the reading cursor or playback intent.
nonisolated struct ReaderControlsVisibilityPolicy {
    enum State: Equatable { case held, waiting, hidden }
    static let inactivityDelay: TimeInterval = 4
    private(set) var state: State = .held
    private(set) var context = ReaderControlsContext()
    private(set) var deadline: TimeInterval?
    private(set) var revision = 0

    mutating func update(_ next: ReaderControlsContext, now: TimeInterval) {
        guard next != context else { return }
        let chapterChanged = next.documentID != context.documentID
        let wasEligible = context.eligible
        context = next
        if chapterChanged || !next.eligible || !wasEligible { reveal(now: now) }
    }

    mutating func reveal(now: TimeInterval) {
        revision &+= 1
        state = context.eligible ? .waiting : .held
        deadline = context.eligible ? now + Self.inactivityDelay : nil
    }

    @discardableResult
    mutating func hideIfDue(now: TimeInterval, revision expected: Int, documentID: UUID?) -> Bool {
        guard expected == revision, documentID == context.documentID, context.eligible,
              let deadline, now >= deadline else { return false }
        state = .hidden
        self.deadline = nil
        return true
    }
}

/// One replaceable sleep, with revision checking even if an injected sleeper
/// finishes after cancellation. No polling and no work on ordinary word updates.
@MainActor @Observable final class ReaderControlsVisibility {
    private(set) var isHidden = false
    @ObservationIgnored private(set) var policy = ReaderControlsVisibilityPolicy()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func update(_ context: ReaderControlsContext) {
        let revision = policy.revision
        policy.update(context, now: now())
        if revision != policy.revision { reconcile() }
    }

    func reveal() {
        policy.reveal(now: now())
        reconcile()
    }

    func stop() {
        var context = policy.context
        context.readerVisible = false
        update(context)
    }

    private func reconcile() {
        task?.cancel()
        task = nil
        isHidden = policy.state == .hidden
        guard let deadline = policy.deadline else { return }
        let revision = policy.revision
        let documentID = policy.context.documentID
        let sleep = sleep
        let delay = max(0, deadline - now())
        task = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.policy.hideIfDue(now: self.now(), revision: revision, documentID: documentID) else { return }
            self.task = nil
            self.isHidden = true
        }
    }
}
