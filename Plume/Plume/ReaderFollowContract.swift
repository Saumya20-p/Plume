import Foundation

/// Deterministic reader-follow policy. The UIKit coordinator owns scheduling.
struct ReaderFollowContract: Equatable, Sendable {
    private(set) var isBrowsing = false
    private(set) var isInteracting = false
    private(set) var deadline: TimeInterval?
    private(set) var revision = 0
    private(set) var canAutoResume = false

    mutating func setAutoResumeAllowed(_ allowed: Bool, now: TimeInterval) {
        guard canAutoResume != allowed else { return }
        canAutoResume = allowed
        invalidateDeadline()
        if allowed && isBrowsing && !isInteracting { deadline = now + 3 }
    }

    mutating func beginInteraction() {
        isBrowsing = true
        isInteracting = true
        invalidateDeadline()
    }

    mutating func endInteraction(now: TimeInterval) {
        isInteracting = false
        invalidateDeadline()
        if canAutoResume && isBrowsing { deadline = now + 3 }
    }

    mutating func returnToCurrentWord() {
        isBrowsing = false
        isInteracting = false
        invalidateDeadline()
    }

    mutating func resumeIfDue(now: TimeInterval, revision expectedRevision: Int) -> Bool {
        guard expectedRevision == revision, canAutoResume, !isInteracting,
              let deadline, now >= deadline else { return false }
        returnToCurrentWord()
        return true
    }

    private mutating func invalidateDeadline() {
        revision += 1
        deadline = nil
    }
}
