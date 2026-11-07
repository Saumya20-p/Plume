import Foundation

// These are value types on purpose.  The playback implementation can keep them
// behind its control owner without exposing AVFoundation, MLX, or persistence to
// tests that only exercise session policy.

nonisolated enum PlaybackPlayIntent: Equatable, Sendable {
    case paused
    case playing
}

nonisolated enum PlaybackProducer: Equatable, Hashable, Sendable {
    case kokoro
    case apple
}

nonisolated enum PlaybackActualActivity: Equatable, Sendable {
    case idle
    case playing(PlaybackProducer)
    case paused
    case buffering
    case interrupted
    case recoverablePause

    var producer: PlaybackProducer? {
        if case .playing(let producer) = self {
            return producer
        }
        return nil
    }

    var isPlaying: Bool {
        producer != nil
    }
}

typealias PlaybackState = PlaybackActualActivity

nonisolated enum PlaybackPreparationStatus: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed
}

nonisolated enum PlaybackSessionLifecycle: Equatable, Sendable {
    case active
    case suspended
    case completed
    case cancelled
}

/// A source position is global to the document, not relative to an utterance
/// or an audio chunk.  UTF-16 offsets match `NSRange` and Apple's speech
/// delegate callbacks.
nonisolated struct PlaybackSourceCursor: Codable, Hashable, Comparable, Sendable {
    let segmentOrdinal: Int
    let globalUTF16Offset: Int

    init?(segmentOrdinal: Int, globalUTF16Offset: Int) {
        guard segmentOrdinal >= 0, globalUTF16Offset >= 0 else { return nil }
        self.segmentOrdinal = segmentOrdinal
        self.globalUTF16Offset = globalUTF16Offset
    }

    init?(segment: Int, offset: Int) {
        self.init(segmentOrdinal: segment, globalUTF16Offset: offset)
    }

    static let beginning = PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: 0)!

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.globalUTF16Offset != rhs.globalUTF16Offset {
            return lhs.globalUTF16Offset < rhs.globalUTF16Offset
        }
        return lhs.segmentOrdinal < rhs.segmentOrdinal
    }
}

typealias DocumentCursor = PlaybackSourceCursor

extension UTF16TextRange {
    /// Creates a range only after checking negative values, addition overflow,
    /// and the document's UTF-16 length.  Never use `upperBound` on untrusted
    /// callback input before this validation.
    nonisolated static func validated(
        location: Int,
        length: Int,
        withinUTF16Length sourceLength: Int
    ) -> Self? {
        guard location >= 0, length >= 0, sourceLength >= 0 else { return nil }
        guard location <= Int.max - length else { return nil }
        guard location + length <= sourceLength else { return nil }
        return Self(location: location, length: length)
    }
}

nonisolated struct PlaybackCursorState: Equatable, Sendable {
    private(set) var displayCursor: PlaybackSourceCursor?
    private(set) var committedCursor: PlaybackSourceCursor?

    init(initialCursor: PlaybackSourceCursor? = nil) {
        self.displayCursor = initialCursor
        self.committedCursor = initialCursor
    }

    /// Advances the highlight cursor.  A callback from a prior utterance is
    /// rejected by `PlaybackSessionContract` before this method is reached;
    /// this second monotonic guard protects the pure cursor itself as well.
    @discardableResult
    mutating func advanceDisplay(to cursor: PlaybackSourceCursor) -> Bool {
        guard displayCursor.map({ cursor >= $0 }) ?? true else { return false }
        displayCursor = cursor
        return true
    }

    /// Commits only an accepted source boundary (normally an owned utterance's
    /// `didFinish`).  Display callbacks alone never move this cursor.
    @discardableResult
    mutating func commit(to cursor: PlaybackSourceCursor) -> Bool {
        guard committedCursor.map({ cursor >= $0 }) ?? true else { return false }
        committedCursor = cursor
        return true
    }

    /// Intentional seeks are the only operation permitted to move either
    /// cursor backwards.
    mutating func seek(to cursor: PlaybackSourceCursor) {
        displayCursor = cursor
        committedCursor = cursor
    }

    var sourceCursor: PlaybackSourceCursor? {
        committedCursor ?? displayCursor
    }
}

nonisolated struct PlaybackCallbackIdentity: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let callbackGeneration: UInt64
    let utteranceID: UUID
    let producer: PlaybackProducer
    let sourceBoundary: PlaybackSourceCursor
}

/// Identity carried by producer status/preparation callbacks.  Unlike an
/// utterance callback, this intentionally has no source boundary: it scopes a
/// producer event to the logical session and callback epoch without allowing
/// a status update to advance a cursor.
nonisolated struct PlaybackEventIdentity: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let callbackGeneration: UInt64
    let producer: PlaybackProducer
}

/// Discrete routing events processed deterministically by the playback state machine.
nonisolated enum PlaybackRoutingEvent: Equatable, Sendable {
    case requestPlay
    case pause
    case beginInterruption
    case endInterruption
    case acquireProducer(PlaybackProducer)
    case releaseProducer(PlaybackProducer)
    case markProducerPlaying(PlaybackProducer, event: PlaybackEventIdentity)
    case confirmProducerPlaying(PlaybackProducer)
    case setPreparationStatus(PlaybackPreparationStatus, event: PlaybackEventIdentity)
    case markRecoverablePause(event: PlaybackEventIdentity)
    case markUnderrun(event: PlaybackEventIdentity)
    case triggerUnderrun(PlaybackProducer)
    case setValidBufferedAudio(Bool)
    case willSpeak(DocumentCursor, callback: PlaybackCallbackIdentity)
    case didFinish(DocumentCursor, callback: PlaybackCallbackIdentity)
    case didCancel(callback: PlaybackCallbackIdentity)
    case seek(DocumentCursor)
    case commitBoundary(DocumentCursor)
    case advanceDisplay(DocumentCursor)
    case resetPlayback(DocumentCursor)
    case cancel
    case completeLogicalDocument(DocumentCursor, callback: PlaybackCallbackIdentity)
    case completeLogicalDocumentAtEOF(DocumentCursor)
}

nonisolated struct PlaybackProducerOwnership: Equatable, Sendable {
    private(set) var owner: PlaybackProducer?

    init(owner: PlaybackProducer? = nil) {
        self.owner = owner
    }

    /// Acquiring an already-owned producer is idempotent.  A different
    /// producer must wait until the current owner is explicitly released.
    @discardableResult
    mutating func acquire(_ producer: PlaybackProducer) -> Bool {
        guard owner == nil || owner == producer else { return false }
        owner = producer
        return true
    }

    @discardableResult
    mutating func release(_ producer: PlaybackProducer) -> Bool {
        guard owner == producer else { return false }
        owner = nil
        return true
    }

    mutating func releaseAll() {
        owner = nil
    }
}

/// The preference values are captured once when a logical document run starts.
/// Saving a new `VoicePreferences` value cannot mutate an existing snapshot.
nonisolated struct PlaybackSessionSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let documentID: UUID
    let primaryVoice: PlaybackVoiceID
    let fallbackAppleVoiceIdentifier: String?

    init(
        documentID: UUID,
        preferences: VoicePreferences,
        sessionID: UUID = UUID()
    ) {
        self.sessionID = sessionID
        self.documentID = documentID
        self.primaryVoice = preferences.primary
        self.fallbackAppleVoiceIdentifier = preferences.fallbackAppleVoiceIdentifier
    }
}

/// The narrow state contract shared by the eventual router and its pure tests.
/// It does not start audio, generate Kokoro data, or observe application state.
nonisolated struct PlaybackSessionContract: Equatable, Sendable {
    private(set) var snapshot: PlaybackSessionSnapshot
    private(set) var callbackGeneration: UInt64
    let sourceUTF16Length: Int
    private(set) var cursors: PlaybackCursorState
    private(set) var desiredPlayIntent: PlaybackPlayIntent
    private(set) var actualActivity: PlaybackActualActivity
    private(set) var preparationStatus: PlaybackPreparationStatus
    private(set) var lifecycle: PlaybackSessionLifecycle
    private(set) var producerOwnership: PlaybackProducerOwnership
    private(set) var hasValidBufferedAudio: Bool
    private(set) var activeCallbacks: [PlaybackCallbackIdentity] = []
    var activeCallback: PlaybackCallbackIdentity? {
        activeCallbacks.first
    }

    private var didCompleteLogicalDocument: Bool

    init?(
        documentID: UUID,
        preferences: VoicePreferences,
        sourceUTF16Length: Int,
        initialCursor: PlaybackSourceCursor = .beginning,
        desiredPlayIntent: PlaybackPlayIntent = .paused,
        sessionID: UUID = UUID()
    ) {
        guard sourceUTF16Length >= 0,
              initialCursor.globalUTF16Offset <= sourceUTF16Length
        else { return nil }
        self.snapshot = PlaybackSessionSnapshot(
            documentID: documentID,
            preferences: preferences,
            sessionID: sessionID
        )
        self.callbackGeneration = 0
        self.sourceUTF16Length = sourceUTF16Length
        self.cursors = PlaybackCursorState(initialCursor: initialCursor)
        self.desiredPlayIntent = desiredPlayIntent
        self.actualActivity = .idle
        self.preparationStatus = .idle
        self.lifecycle = .active
        self.producerOwnership = PlaybackProducerOwnership()
        self.hasValidBufferedAudio = false
        self.activeCallbacks = []
        self.didCompleteLogicalDocument = false
    }

    init?(
        documentID: UUID = UUID(),
        sourceUTF16Length: Int,
        initialCursor: DocumentCursor = .beginning,
        primaryVoice: PlaybackVoiceID = .kokoro(identifier: "af_heart"),
        fallbackAppleVoiceIdentifier: String? = nil,
        desiredPlayIntent: PlaybackPlayIntent = .paused,
        sessionID: UUID = UUID()
    ) {
        let prefs = VoicePreferences(
            primary: primaryVoice,
            fallbackAppleVoiceIdentifier: fallbackAppleVoiceIdentifier
        )
        self.init(
            documentID: documentID,
            preferences: prefs,
            sourceUTF16Length: sourceUTF16Length,
            initialCursor: initialCursor,
            desiredPlayIntent: desiredPlayIntent,
            sessionID: sessionID
        )
    }

    var sessionID: UUID { snapshot.sessionID }
    var documentID: UUID { snapshot.documentID }
    var primaryVoice: PlaybackVoiceID { snapshot.primaryVoice }
    var fallbackAppleVoiceIdentifier: String? { snapshot.fallbackAppleVoiceIdentifier }
    var displayCursor: PlaybackSourceCursor? { cursors.displayCursor }
    var committedCursor: PlaybackSourceCursor? { cursors.committedCursor }
    var sourceCursor: PlaybackSourceCursor? { cursors.sourceCursor }
    var documentCursor: DocumentCursor? { sourceCursor }
    var activeProducer: PlaybackProducer? { producerOwnership.owner }
    var playbackState: PlaybackState { actualActivity }
    var state: PlaybackState { actualActivity }

    mutating func updatePreferences(_ preferences: VoicePreferences) {
        self.snapshot = PlaybackSessionSnapshot(
            documentID: snapshot.documentID,
            preferences: preferences,
            sessionID: snapshot.sessionID
        )
    }

    private func accepts(_ cursor: PlaybackSourceCursor) -> Bool {
        cursor.globalUTF16Offset <= sourceUTF16Length
    }

    private func accepts(_ event: PlaybackEventIdentity) -> Bool {
        lifecycle == .active
            && event.sessionID == sessionID
            && event.callbackGeneration == callbackGeneration
    }

    /// Captures the current session/epoch for a producer status callback.
    /// The token remains valid only until an intentional seek, interruption,
    /// cancellation, or other callback invalidation advances the epoch.
    func eventIdentity(for producer: PlaybackProducer) -> PlaybackEventIdentity? {
        guard lifecycle == .active else { return nil }
        return PlaybackEventIdentity(
            sessionID: sessionID,
            callbackGeneration: callbackGeneration,
            producer: producer
        )
    }

    mutating func setDesiredPlayIntent(_ intent: PlaybackPlayIntent) {
        if intent == .paused, desiredPlayIntent != .paused {
            // Pausing preserves queued audio but makes an in-flight callback
            // ineligible to commit after the user has paused.
            invalidateCallbacks()
        }
        desiredPlayIntent = intent
        guard lifecycle == .active else { return }

        switch intent {
        case .paused:
            actualActivity = .paused
        case .playing:
            // Intent alone never claims audible activity. A producer must
            // confirm playback through `markProducerPlaying`.
            if actualActivity.producer == nil {
                actualActivity = .buffering
            }
        }
    }

    mutating func pause() {
        setDesiredPlayIntent(.paused)
    }

    mutating func requestPlay() {
        setDesiredPlayIntent(.playing)
    }

    /// Interruption changes actual activity, but deliberately does not change
    /// user intent or release valid queued audio.  Ending an interruption only
    /// returns to buffering when the user still wanted playback; it does not
    /// claim that audio resumed until a producer reports that it is playing.
    mutating func beginInterruption() {
        guard lifecycle == .active else { return }
        // Keep valid buffers and ownership, but establish a new callback epoch
        // so a delayed pre-interruption callback cannot advance the cursor.
        invalidateCallbacks()
        lifecycle = .suspended
        actualActivity = .interrupted
    }

    @discardableResult
    mutating func endInterruption() -> Bool {
        guard lifecycle == .suspended else { return false }
        lifecycle = .active
        actualActivity = desiredPlayIntent == .playing ? .buffering : .paused
        return true
    }

    @discardableResult
    mutating func setPreparationStatus(
        _ status: PlaybackPreparationStatus,
        event: PlaybackEventIdentity
    ) -> Bool {
        guard accepts(event) else { return false }
        preparationStatus = status
        // Preparation is speculative and independent from audible activity.
        // A failed Kokoro preparation must not stop an Apple producer that is
        // already playing; recovery state is set only by an explicit router
        // decision, not by this bookkeeping callback.
        return true
    }

    /// Records a recoverable preparation failure as an actual-state decision,
    /// separate from `setPreparationStatus`. The latter is deliberately
    /// allowed to report failure while another producer is still audible.
    @discardableResult
    mutating func markRecoverablePause(event: PlaybackEventIdentity) -> Bool {
        guard accepts(event), !actualActivity.isPlaying else { return false }
        actualActivity = .recoverablePause
        return true
    }

    @discardableResult
    mutating func markUnderrun(event: PlaybackEventIdentity) -> Bool {
        guard accepts(event) else { return false }
        guard actualActivity.producer == nil || actualActivity.producer == event.producer else {
            return false
        }
        actualActivity = desiredPlayIntent == .playing ? .buffering : .paused
        return true
    }

    /// Ordinary pause/interruption transitions preserve this flag.  Intentional
    /// seeks, cancellation, restart, and terminal completion clear it.
    mutating func setValidBufferedAudio(_ isValid: Bool) {
        hasValidBufferedAudio = isValid
    }

    @discardableResult
    mutating func acquireProducer(_ producer: PlaybackProducer) -> Bool {
        guard lifecycle == .active else { return false }
        return producerOwnership.acquire(producer)
    }

    @discardableResult
    mutating func markProducerPlaying(
        _ producer: PlaybackProducer,
        event: PlaybackEventIdentity
    ) -> Bool {
        guard accepts(event), event.producer == producer,
              producerOwnership.owner == producer
        else { return false }
        actualActivity = desiredPlayIntent == .playing ? .playing(producer) : .paused
        return true
    }

    @discardableResult
    mutating func releaseProducer(_ producer: PlaybackProducer) -> Bool {
        guard producerOwnership.release(producer) else { return false }
        // Release is an ownership boundary even when no utterance callback is
        // currently active.  Advancing the epoch prevents a delayed producer
        // status event from becoming valid again after a release/reacquire.
        invalidateCallbacks()
        actualActivity = desiredPlayIntent == .playing ? .buffering : .paused
        return true
    }

    /// Starts (or replaces) the current utterance/chunk callback token.  The
    /// utterance UUID makes a late callback from an earlier sentence stale even
    /// when both sentences belong to the same session and generation.
    @discardableResult
    mutating func beginCallback(
        for producer: PlaybackProducer,
        utteranceID: UUID = UUID(),
        sourceBoundary: PlaybackSourceCursor? = nil
    ) -> PlaybackCallbackIdentity? {
        guard lifecycle == .active else { return nil }
        let sourceBoundary = sourceBoundary ?? cursors.sourceCursor ?? .beginning
        let boundaryFloor = activeCallbacks.last?.sourceBoundary ?? cursors.sourceCursor ?? .beginning
        guard accepts(sourceBoundary),
              sourceBoundary >= boundaryFloor,
              producerOwnership.acquire(producer)
        else { return nil }
        let callback = PlaybackCallbackIdentity(
            sessionID: sessionID,
            callbackGeneration: callbackGeneration,
            utteranceID: utteranceID,
            producer: producer,
            sourceBoundary: sourceBoundary
        )
        activeCallbacks.append(callback)
        hasValidBufferedAudio = true
        return callback
    }

    func accepts(_ callback: PlaybackCallbackIdentity) -> Bool {
        lifecycle == .active
            && callback.sessionID == sessionID
            && callback.callbackGeneration == callbackGeneration
            && activeCallbacks.contains(callback)
            && producerOwnership.owner == callback.producer
    }

    /// Models Apple's `willSpeak` callback: display-only, never a committed
    /// handoff/document boundary.
    @discardableResult
    mutating func willSpeak(
        _ cursor: PlaybackSourceCursor,
        callback: PlaybackCallbackIdentity
    ) -> Bool {
        guard accepts(callback), cursor <= callback.sourceBoundary, accepts(cursor) else { return false }
        return cursors.advanceDisplay(to: cursor)
    }

    /// Models an owned utterance's `didFinish`: this is the only callback that
    /// can commit a source boundary.
    @discardableResult
    mutating func didFinish(
        at cursor: PlaybackSourceCursor,
        callback: PlaybackCallbackIdentity
    ) -> Bool {
        guard accepts(callback), cursor == callback.sourceBoundary, accepts(cursor), cursors.commit(to: cursor) else {
            return false
        }
        activeCallbacks.removeAll { $0 == callback }
        return true
    }

    /// Cancellation is intentionally cursor-neutral.  A stale cancellation is
    /// a no-op and cannot clear or move the current utterance's cursor.
    @discardableResult
    mutating func didCancel(callback: PlaybackCallbackIdentity) -> Bool {
        guard accepts(callback) else { return false }
        activeCallbacks.removeAll { $0 == callback }
        return true
    }

    /// Commits an explicit source boundary (e.g. when an audio chunk finishes playing).
    /// Monotonically advances the committed cursor without altering active callbacks or seeking.
    @discardableResult
    mutating func commitBoundary(to cursor: PlaybackSourceCursor) -> Bool {
        guard lifecycle == .active || lifecycle == .suspended, accepts(cursor) else { return false }
        return cursors.commit(to: cursor)
    }

    /// Advances the highlight/display cursor (e.g. from word timestamps during playback).
    /// Monotonically advances the display cursor without altering active callbacks.
    @discardableResult
    mutating func advanceDisplay(to cursor: PlaybackSourceCursor) -> Bool {
        guard lifecycle == .active || lifecycle == .suspended, accepts(cursor) else { return false }
        return cursors.advanceDisplay(to: cursor)
    }

    /// Seeks invalidate callbacks and clear queued audio because the old audio
    /// belongs to a different source position.  Preference snapshots remain
    /// unchanged.
    @discardableResult
    mutating func seek(to cursor: PlaybackSourceCursor) -> Bool {
        guard lifecycle != .cancelled, lifecycle != .completed, accepts(cursor) else { return false }
        let wasSuspended = lifecycle == .suspended
        invalidateCallbacks()
        cursors.seek(to: cursor)
        preparationStatus = .idle
        hasValidBufferedAudio = false
        actualActivity = wasSuspended
            ? .interrupted
            : (desiredPlayIntent == .playing ? .buffering : .paused)
        lifecycle = wasSuspended ? .suspended : .active
        return true
    }

    /// Same-session recovery/reset invalidates callbacks while preserving the
    /// logical run ID. A new logical run is created with a new initializer so
    /// that its preference snapshot is explicit and immutable.
    @discardableResult
    mutating func resetPlayback(at cursor: PlaybackSourceCursor) -> Bool {
        seek(to: cursor)
    }

    /// Invalidates the current callback without changing the preference
    /// snapshot.  The generation is monotonic for the lifetime of the value.
    @discardableResult
    mutating func invalidateCallbacks() -> UInt64 {
        callbackGeneration &+= 1
        activeCallbacks.removeAll(keepingCapacity: true)
        return callbackGeneration
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard lifecycle != .cancelled else { return false }
        invalidateCallbacks()
        producerOwnership.releaseAll()
        actualActivity = .idle
        preparationStatus = .idle
        hasValidBufferedAudio = false
        lifecycle = .cancelled
        return true
    }

    /// Terminal completion is separate from an utterance finishing, a handoff,
    /// preparation, or an underrun. It requires the currently-owned callback's
    /// captured boundary, so a delayed callback cannot complete a replacement
    /// run or jump to an arbitrary source position.
    @discardableResult
    mutating func completeLogicalDocument(
        at cursor: PlaybackSourceCursor,
        callback: PlaybackCallbackIdentity
    ) -> Bool {
        // This is the terminal alternative to `didFinish`: callers must pass
        // the final owned token directly.  A non-final boundary can finish an
        // utterance, but can never complete the logical document.
        guard !didCompleteLogicalDocument,
              accepts(callback),
              cursor == callback.sourceBoundary,
              cursor.globalUTF16Offset == sourceUTF16Length,
              accepts(cursor),
              cursors.commit(to: cursor)
        else { return false }
        didCompleteLogicalDocument = true
        desiredPlayIntent = .paused
        lifecycle = .completed
        actualActivity = .idle
        hasValidBufferedAudio = false
        activeCallbacks.removeAll(keepingCapacity: false)
        callbackGeneration &+= 1
        producerOwnership.releaseAll()
        return true
    }

    /// Completes an empty/whitespace-only document, or a session whose cursor
    /// is already at EOF and has no owned utterance left to finish.  This is a
    /// terminal alternative to the callback-based method above: it never
    /// fabricates a producer-playing event and is idempotent for late retries.
    @discardableResult
    mutating func completeLogicalDocumentAtEOF(
        at cursor: PlaybackSourceCursor
    ) -> Bool {
        guard !didCompleteLogicalDocument,
              lifecycle == .active,
              activeCallbacks.isEmpty,
              cursor.globalUTF16Offset == sourceUTF16Length,
              accepts(cursor),
              cursors.commit(to: cursor)
        else { return false }
        didCompleteLogicalDocument = true
        desiredPlayIntent = .paused
        lifecycle = .completed
        actualActivity = .idle
        hasValidBufferedAudio = false
        callbackGeneration &+= 1
        producerOwnership.releaseAll()
        return true
    }

    @discardableResult
    mutating func send(_ event: PlaybackRoutingEvent) -> Bool {
        switch event {
        case .requestPlay:
            requestPlay()
            return true
        case .pause:
            pause()
            return true
        case .beginInterruption:
            beginInterruption()
            return true
        case .endInterruption:
            return endInterruption()
        case .acquireProducer(let producer):
            return acquireProducer(producer)
        case .releaseProducer(let producer):
            return releaseProducer(producer)
        case .markProducerPlaying(let producer, let event):
            return markProducerPlaying(producer, event: event)
        case .confirmProducerPlaying(let producer):
            guard let event = eventIdentity(for: producer) else { return false }
            return markProducerPlaying(producer, event: event)
        case .setPreparationStatus(let status, let event):
            return setPreparationStatus(status, event: event)
        case .markRecoverablePause(let event):
            return markRecoverablePause(event: event)
        case .markUnderrun(let event):
            return markUnderrun(event: event)
        case .triggerUnderrun(let producer):
            guard let event = eventIdentity(for: producer) else { return false }
            return markUnderrun(event: event)
        case .setValidBufferedAudio(let valid):
            setValidBufferedAudio(valid)
            return true
        case .willSpeak(let cursor, let callback):
            return willSpeak(cursor, callback: callback)
        case .didFinish(let cursor, let callback):
            return didFinish(at: cursor, callback: callback)
        case .didCancel(let callback):
            return didCancel(callback: callback)
        case .seek(let cursor):
            return seek(to: cursor)
        case .commitBoundary(let cursor):
            return commitBoundary(to: cursor)
        case .advanceDisplay(let cursor):
            return advanceDisplay(to: cursor)
        case .resetPlayback(let cursor):
            return resetPlayback(at: cursor)
        case .cancel:
            return cancel()
        case .completeLogicalDocument(let cursor, let callback):
            return completeLogicalDocument(at: cursor, callback: callback)
        case .completeLogicalDocumentAtEOF(let cursor):
            return completeLogicalDocumentAtEOF(at: cursor)
        }
    }
}

typealias PlaybackStateMachine = PlaybackSessionContract

nonisolated enum AppleSpeechVoiceResolutionReason: Equatable, Sendable {
    case chosen
    case sameLocale
    case highestQuality
    case compatibleSystemDefault
    case unavailable
}

nonisolated enum AppleSpeechVoiceResolution: Equatable, Sendable {
    case chosen(AppleSpeechVoiceDescriptor)
    case sameLocale(AppleSpeechVoiceDescriptor)
    case highestQuality(AppleSpeechVoiceDescriptor)
    case compatibleSystemDefault(AppleSpeechVoiceCandidate)
    case unavailable

    var voice: AppleSpeechVoiceDescriptor? {
        switch self {
        case .chosen(let voice), .sameLocale(let voice), .highestQuality(let voice):
            return voice
        case .compatibleSystemDefault, .unavailable:
            return nil
        }
    }

    var reason: AppleSpeechVoiceResolutionReason {
        switch self {
        case .chosen: return .chosen
        case .sameLocale: return .sameLocale
        case .highestQuality: return .highestQuality
        case .compatibleSystemDefault: return .compatibleSystemDefault
        case .unavailable: return .unavailable
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.chosen(let lhs), .chosen(let rhs)),
             (.sameLocale(let lhs), .sameLocale(let rhs)),
             (.highestQuality(let lhs), .highestQuality(let rhs)):
            return lhs == rhs
        case (.compatibleSystemDefault(let lhs), .compatibleSystemDefault(let rhs)):
            return lhs.identifier == rhs.identifier
                && lhs.name == rhs.name
                && lhs.language == rhs.language
                && sameQuality(lhs.quality, rhs.quality)
                && lhs.isNoveltyVoice == rhs.isNoveltyVoice
                && lhs.isPersonalVoice == rhs.isPersonalVoice
        case (.unavailable, .unavailable):
            return true
        default:
            return false
        }
    }

    private static func sameQuality(
        _ lhs: AppleSpeechVoiceCandidateQuality,
        _ rhs: AppleSpeechVoiceCandidateQuality
    ) -> Bool {
        switch (lhs, rhs) {
        case (.default, .default), (.enhanced, .enhanced), (.premium, .premium):
            return true
        default:
            return false
        }
    }
}

/// Resolves only among catalog descriptors already known to be eligible.  The
/// resolver does not create a second voice catalog or persist its emergency
/// choice over the user's fallback preference.
nonisolated enum AppleSpeechVoiceResolver {
    static func resolve(
        preferredIdentifier: String?,
        preferredLocale: String?,
        eligibleVoices: [AppleSpeechVoiceDescriptor],
        compatibleSystemDefault: AppleSpeechVoiceCandidate? = nil
    ) -> AppleSpeechVoiceResolution {
        if let preferredIdentifier,
           let chosen = eligibleVoices.first(where: { $0.id == preferredIdentifier }) {
            return .chosen(chosen)
        }

        if let preferredLocale {
            let localeVoices = eligibleVoices.filter {
                localeKey($0.language) == localeKey(preferredLocale)
            }
            if let sameLocale = ordered(localeVoices).first {
                return .sameLocale(sameLocale)
            }
        }

        let compatibleVoices = eligibleVoices.filter {
            isCompatibleVoice($0, with: preferredLocale)
        }
        if let highestQuality = ordered(compatibleVoices).first {
            return .highestQuality(highestQuality)
        }

        if let compatibleSystemDefault,
           isCompatibleSystemDefault(compatibleSystemDefault, with: preferredLocale) {
            return .compatibleSystemDefault(compatibleSystemDefault)
        }
        return .unavailable
    }

    private static func ordered(_ voices: [AppleSpeechVoiceDescriptor]) -> [AppleSpeechVoiceDescriptor] {
        voices.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func localeKey(_ language: String) -> String {
        Locale(identifier: language.replacingOccurrences(of: "_", with: "-")).identifier
            .lowercased()
    }

    private static func isCompatibleVoice(
        _ voice: AppleSpeechVoiceDescriptor,
        with preferredLocale: String?
    ) -> Bool {
        guard let voiceLang = languageCode(voice.language) else { return false }
        guard let preferredLocale else {
            return voiceLang == "en"
        }
        guard let preferredLang = languageCode(preferredLocale) else { return false }
        return preferredLang == voiceLang
    }

    private static func isCompatibleSystemDefault(
        _ candidate: AppleSpeechVoiceCandidate,
        with preferredLocale: String?
    ) -> Bool {
        guard !candidate.isNoveltyVoice,
              !candidate.isPersonalVoice,
              languageCode(candidate.language) == "en"
        else { return false }

        guard let preferredLocale else { return true }
        return languageCode(preferredLocale) == languageCode(candidate.language)
    }

    private static func languageCode(_ language: String) -> String? {
        Locale.Language(identifier: language.replacingOccurrences(of: "_", with: "-"))
            .languageCode?.identifier
            .lowercased()
    }
}
