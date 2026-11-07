import Foundation
import Combine
import UIKit
import os

nonisolated enum PlaybackAppPhase: String, Sendable { case active, inactive, background }

/// A lease is reserved before resuming a waiter. All ticket state, including
/// cancellation before continuation registration, is protected by this condition.
nonisolated final class EngineBackgroundState: @unchecked Sendable {
    static let shared = EngineBackgroundState(paused: true)
    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        var cancelled = false
        var continuation: CheckedContinuation<UUID, Error>?
    }
    private let condition = NSCondition()
    private var paused: Bool
    private var owner: UUID?
    private var waiting: [Ticket] = []

    init(paused: Bool = false) { self.paused = paused }

    var isPaused: Bool {
        get { condition.lock(); defer { condition.unlock() }; return paused }
        set {
            condition.lock()
            paused = newValue
            grantNextLocked()
            condition.unlock()
        }
    }
    var isExecuting: Bool {
        condition.lock(); defer { condition.unlock() }; return owner != nil
    }
    func acquire() async throws -> UUID {
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if ticket.cancelled {
                    condition.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    ticket.continuation = continuation
                    waiting.append(ticket)
                    grantNextLocked()
                    condition.unlock()
                }
            }
        } onCancel: {
            self.condition.lock()
            ticket.cancelled = true
            let continuation = ticket.continuation
            ticket.continuation = nil
            self.waiting.removeAll { $0.id == ticket.id }
            self.condition.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }
    func release(_ lease: UUID) {
        condition.lock(); defer { condition.unlock() }
        guard owner == lease else { return }
        owner = nil
        condition.broadcast()
        grantNextLocked()
    }
    private func grantNextLocked() {
        guard !paused, owner == nil else { return }
        while !waiting.isEmpty {
            let ticket = waiting.removeFirst()
            guard !ticket.cancelled, let continuation = ticket.continuation else { continue }
            ticket.continuation = nil
            owner = ticket.id
            continuation.resume(returning: ticket.id)
            return
        }
    }
    func waitForIdle(timeoutSeconds: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while owner != nil {
            if !condition.wait(until: deadline) { return owner == nil }
        }
        return true
    }
}

/// Exists independently of model loading; a late-created engine inherits the
/// same closed gate. Inactivity affects GPU permission, not playback intent.
@MainActor final class PlaybackLifecycle: ObservableObject {
    static let shared = PlaybackLifecycle()
    @Published private(set) var phase: PlaybackAppPhase
    private var observations: [NSObjectProtocol] = []

    private init() {
        phase = UIApplication.shared.applicationState == .active ? .active : .inactive
        EngineBackgroundState.shared.isPaused = phase != .active
        for (name, phase) in [(UIApplication.willResignActiveNotification, PlaybackAppPhase.inactive),
                              (UIApplication.didEnterBackgroundNotification, .background),
                              (UIApplication.didBecomeActiveNotification, .active)] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    EngineBackgroundState.shared.isPaused = phase != .active
                    if phase == .background {
                        let token = UIApplication.shared.beginBackgroundTask(withName: "GPUBackgroundDrain", expirationHandler: nil)
                        KokoroTTSService.shared.waitForGPUIdleSync()
                        if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
                    }
                    self?.phase = phase
                    PlaybackDiagnostics.shared.record("lifecycle=\(phase.rawValue)")
                }
            })
        }
    }
}

nonisolated enum PlaybackSourceProgress {
    static func fraction(offset: Int, length: Int) -> Double {
        guard length > 0 else { return 0 }
        return Double(min(length, max(0, offset))) / Double(length)
    }
    static func hasSpeech(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil
    }
}

nonisolated struct PlaybackRecoveryBudget {
    private var attemptedSegments: Set<Int> = []
    private var attempted = false
    private var verifiedSeconds: TimeInterval = 0
    mutating func verifiedPlayback(seconds: TimeInterval) { verifiedSeconds += max(0, seconds) }
    mutating func stoppedPlayback() {
        // Once earned, eligibility survives the failure/underrun that consumes it.
        // Short interrupted intervals cannot accumulate toward the threshold.
        if verifiedSeconds < 30 { verifiedSeconds = 0 }
    }
    mutating func allow(segment: Int, now: TimeInterval) -> Bool {
        guard !attemptedSegments.contains(segment), !attempted || verifiedSeconds >= 30 else { return false }
        attemptedSegments.insert(segment)
        attempted = true
        verifiedSeconds = 0
        return true
    }
}

nonisolated struct PlaybackIssue: Equatable, Sendable {
    let id = UUID()
    let documentID: UUID
    let runID: UUID
    let segment: Int
    let stage: String
    let codes: [String]

    init(documentID: UUID, runID: UUID, segment: Int, stage: String, error: Error) {
        self.documentID = documentID; self.runID = runID; self.segment = segment
        self.stage = (error as? AudioPreparationError)?.stage ?? stage
        var current: NSError? = ((error as? AudioPreparationError)?.underlying ?? error) as NSError
        var codes: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            codes.append("\(value.domain):\(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.codes = codes
    }
    var message: String {
        "Audio preparation failed during \(stage). Retry from your current position. Reference: \(id.uuidString.prefix(8))."
    }
}

nonisolated struct AudioPreparationError: Error {
    let stage: String
    let underlying: Error
}

@MainActor final class PlaybackDiagnostics {
    static let shared = PlaybackDiagnostics()
    private(set) var events: [String] = []
    func record(_ event: String) {
        guard events.last != event else { return }
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        Log.audio.info("\(event, privacy: .public)")
    }
}

@MainActor enum PlaybackPreferences {
    static var automaticFallback: Bool {
        UserDefaults.standard.object(forKey: "automaticAppleFallback") as? Bool ?? true
    }
}
