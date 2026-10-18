import AVFoundation
import Foundation
import os

/// All session mutations go through one transition at a time. Owners retain a
/// claim until stopped; releasing a preview cannot deactivate an active reader.
@MainActor final class AppAudioSession {
    static let shared = AppAudioSession()
    nonisolated enum Profile: Equatable, Sendable { case spoken, standalone }
    private struct Waiter {
        let completion: (Result<Void, Error>) -> Void
    }
    private let worker = DispatchQueue(label: "com.plume.audio-session", qos: .userInitiated)
    private var claims: [UUID: Profile] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var applied: Profile?
    private var active = false
    private var transitioning = false
    private var revision = 0
    private var resetRevision = 0
    private var reason = "initial"

    private var target: Profile? {
        claims.values.contains(.spoken) ? .spoken : claims.values.first
    }

    func isReady(owner: UUID) -> Bool {
        claims[owner] != nil && active && applied == target && !transitioning
    }

    func prepare(owner: UUID, profile: Profile = .spoken, reason: String,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        let old = waiters.removeValue(forKey: owner)
        claims[owner] = profile
        waiters[owner] = Waiter(completion: completion)
        revision &+= 1
        self.reason = reason
        old?.completion(.failure(CancellationError()))
        reconcile()
    }

    func prepare(owner: UUID, profile: Profile = .spoken, reason: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            prepare(owner: owner, profile: profile, reason: reason) { continuation.resume(with: $0) }
        }
    }

    func release(owner: UUID, reason: String) {
        let claim = claims.removeValue(forKey: owner)
        let old = waiters.removeValue(forKey: owner)
        guard claim != nil || old != nil else { return }
        revision &+= 1
        self.reason = reason
        old?.completion(.failure(CancellationError()))
        reconcile()
    }

    /// Interruption/media-server loss makes cached hardware state unknowable.
    func invalidate(reason: String) {
        active = false
        applied = nil
        resetRevision &+= 1
        revision &+= 1
        self.reason = reason
    }

    private func reconcile() {
        guard !transitioning else { return }
        let desired = target
        if applied == desired && active == (desired != nil) {
            let ready = waiters
            waiters.removeAll()
            for (owner, waiter) in ready {
                guard claims[owner] != nil else { waiter.completion(.failure(CancellationError())); continue }
                waiter.completion(.success(()))
            }
            return
        }
        transitioning = true
        let startedReset = resetRevision
        let configured = applied
        let wasActive = active
        let trace = StabilityTrace.begin("AudioSessionTransition", revision: revision, reason: reason)
        worker.async {
            Self.transition(to: desired, configured: configured, active: wasActive) { result in
                Task { @MainActor in
                    StabilityTrace.end("AudioSessionTransition", trace)
                    self.transitioning = false
                    guard self.resetRevision == startedReset else { self.reconcile(); return }
                    switch result {
                    case .success:
                        self.applied = desired
                        self.active = desired != nil
                        self.reconcile()
                    case .failure(let error):
                        // Stop/error callbacks can release owners. Reconcile
                        // only after all callbacks finish, not halfway through.
                        self.transitioning = true
                        self.active = false
                        self.applied = nil
                        let failed = self.waiters
                        self.waiters.removeAll()
                        Log.audio.error("Audio session transition failed: \(error.localizedDescription, privacy: .public)")
                        for waiter in failed.values { waiter.completion(.failure(error)) }
                        self.transitioning = false
                        // Only a new preparation request can retry a failure.
                        if !self.waiters.isEmpty { self.reconcile() }
                    }
                }
            }
        }
    }

    nonisolated private static func transition(to profile: Profile?, configured: Profile?, active: Bool,
                                               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let session = AVAudioSession.sharedInstance()
        let finish: @Sendable (Bool, Error?) -> Void = { succeeded, error in
            if let error { completion(.failure(error)) }
            else if succeeded { completion(.success(())) }
            else { completion(.failure(NSError(domain: "Plume.AudioSession", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The audio session could not be prepared."]))) }
        }
        do {
            if let profile {
                if profile != configured {
                    try session.setCategory(.playback, mode: profile == .spoken ? .spokenAudio : .default, options: [])
                }
                if active { completion(.success(())); return }
                if #available(iOS 27.0, *) {
                    session.activate(options: [], completionHandler: finish)
                } else {
                    try session.setActive(true)
                    completion(.success(()))
                }
            } else {
                if #available(iOS 27.0, *) {
                    session.deactivate(options: .notifyOthersOnDeactivation, completionHandler: finish)
                } else {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    completion(.success(()))
                }
            }
        } catch { completion(.failure(error)) }
    }
}
