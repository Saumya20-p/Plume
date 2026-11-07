import AVFoundation
import Foundation
import os

/// Main-actor coordinator that manages a logical playback session.
/// The coordinator owns the `PlaybackStateMachine` (`PlaybackSessionContract`)
/// and arbitrates between `AppleSpeechProducer` and the legacy Kokoro playback logic.
@MainActor
final class PlaybackRoutingCoordinator {

    private enum Constants {
        static let voiceUnavailable = "The selected Apple voice is unavailable."
        static func playbackActivationFailed(_ desc: String) -> String { "Unable to activate audio playback: \(desc)" }
        static func fallbackActivationFailed(_ desc: String) -> String { "Unable to activate audio session for fallback: \(desc)" }
        static let speechCancelled = "Apple speech was cancelled."
        static let defaultLanguageCode = "en"
        static let defaultVoiceLanguage = "en-US"
        static let underscore = "_"
        static let dash = "-"
    }

    // MARK: - State Machine & Producer Ownership

    private(set) var contract: PlaybackSessionContract?



    private(set) var document: Document?
    let appleProducer: AppleSpeechProducer
    private var segments: [TextSegmenter.Chunk] = []
    private var nextSegmentIndex = 0
    private var terminalCallbacks = Set<UUID>()
    private var appleVoice: AVSpeechSynthesisVoice?
    private var resolvedFallbackIdentifier: String?
    private var speechRateMultiplier: Float = 1.0


    // MARK: - Callbacks

    weak var playbackEngine: AudioPlaybackEngine?
    var onPerformHandback: (([AudioChunk], PlaybackSourceCursor) -> Void)?
    var onStateChange: ((PlaybackSessionContract) -> Void)?
    var onDisplayRange: ((UTF16TextRange) -> Void)?
    var onProgress: ((TimeInterval, WordTimestamp?) -> Void)?
    var onActualPlayingChanged: ((Bool) -> Void)?
    var onCompleted: (() -> Void)?
    var onSpokenWordCompleted: ((UTF16TextRange) -> Void)?
    var onWaitingForPrimary: (() -> Void)?
    private var pendingWord: UTF16TextRange?
    var automaticFallbackAllowed = true
    private(set) var handbackPreparationID: UUID?
    enum HandbackState: Equatable { case idle, preparing(UUID), ready(UUID) }
    private(set) var handbackState: HandbackState = .idle
    private(set) var lastError: String?

    // MARK: - Speculative Handback State
    var isHandbackPending: Bool = false
    private(set) var stagedHandbackChunks: [AudioChunk] = []
    private(set) var stagedHandbackSession: PlaybackGenerationSession?
    var currentlySpeakingSegmentOrdinal: Int?

    // MARK: - Initialization

    init(appleProducer: AppleSpeechProducer? = nil) {
        self.appleProducer = appleProducer ?? AppleSpeechProducer()
        wireAppleProducer()
    }

    // MARK: - Arbitration Properties

    var desiredPlayIntent: PlaybackPlayIntent {
        contract?.desiredPlayIntent ?? .paused
    }

    var isFallbackActive: Bool = false

    var isAppleActive: Bool {
        if isFallbackActive { return true }
        guard let primaryVoice = contract?.primaryVoice else { return false }
        if case .apple = primaryVoice {
            return true
        }
        return false
    }

    var isPlaying: Bool {
        if isAppleActive {
            return contract?.actualActivity.isPlaying == true || appleProducer.isSpeaking
        }
        return contract?.actualActivity.isPlaying == true
    }

    var estimatedCurrentTime: TimeInterval {
        guard let document, contract?.sourceUTF16Length ?? 0 > 0 else { return 0 }
        let currentOffset = contract?.sourceCursor?.globalUTF16Offset ?? 0
        let ratio = Double(currentOffset) / Double(contract?.sourceUTF16Length ?? 1)
        let totalDuration = document.estimatedDuration > 0 ? document.estimatedDuration : 60.0
        return max(0, min(totalDuration, ratio * totalDuration))
    }

    var isAppleSpeaking: Bool {
        appleProducer.isSpeaking
    }

    var segmentsCount: Int {
        segments.count
    }

    var currentOrUpcomingSegmentIndex: Int {
        if let current = currentlySpeakingSegmentOrdinal {
            return current + 1
        }
        return firstSegmentIndex(after: contract?.committedCursor ?? .beginning)
    }

    // MARK: - Session Lifecycle

    @discardableResult
    func begin(
        document: Document,
        snapshot: PlaybackSessionSnapshot,
        resumeCursor: PlaybackSourceCursor? = nil,
        speechRateMultiplier: Float = 1.0
    ) -> Bool {
        guard snapshot.documentID == document.id else { return false }

        isFallbackActive = false
        cancelPendingHandback()
        currentlySpeakingSegmentOrdinal = nil
        appleProducer.stop()
        terminalCallbacks.removeAll(keepingCapacity: true)
        self.document = document
        self.segments = TextSegmenter.segment(documentID: document.id, text: document.bodyText)
        self.speechRateMultiplier = speechRateMultiplier
        self.lastError = nil
        self.pendingWord = nil
        self.automaticFallbackAllowed = PlaybackPreferences.automaticFallback

        let startOffset = resumeCursor?.globalUTF16Offset ?? document.lastReadCharIndex
        guard let cursor = cursorForCharacterOffset(
            startOffset,
            sourceLength: document.bodyText.utf16.count
        ) else {
            contract = nil
            return false
        }
        guard let newContract = PlaybackSessionContract(
            documentID: document.id,
            preferences: VoicePreferences(
                primary: snapshot.primaryVoice,
                fallbackAppleVoiceIdentifier: snapshot.fallbackAppleVoiceIdentifier
            ),
            sourceUTF16Length: document.bodyText.utf16.count,
            initialCursor: cursor,
            sessionID: snapshot.sessionID
        ) else {
            contract = nil
            return false
        }
        contract = newContract
        nextSegmentIndex = firstSegmentIndex(after: cursor)
        appleVoice = nil
        resolvedFallbackIdentifier = nil

        if isAppleActive {
            appleVoice = resolveAppleVoice(identifier: snapshot.primaryVoice.identifier)
            guard appleVoice != nil else {
                lastError = Constants.voiceUnavailable
                if var failedContract = contract,
                   let event = failedContract.eventIdentity(for: .apple) {
                    _ = failedContract.setPreparationStatus(.failed, event: event)
                    _ = failedContract.markRecoverablePause(event: event)
                    contract = failedContract
                }
                notifyState()
                return false
            }
        } else {
            let fallbackIdentifier = snapshot.fallbackAppleVoiceIdentifier
                ?? VoicePreferencesStore().load().fallbackAppleVoiceIdentifier
            appleVoice = resolveAppleVoice(identifier: fallbackIdentifier)
            resolvedFallbackIdentifier = fallbackIdentifier
        }

        notifyState()
        return true
    }

    // MARK: - Playback Commands

    func requestPlayIntent() {
        contract?.requestPlay()
        notifyState()
    }

    func reportAudioSessionFailure(_ error: Error) {
        let value = error as NSError
        lastError = "Audio session preparation failed (\(value.domain):\(value.code))."
        notifyState()
    }

    @discardableResult
    func play() -> Bool {
        guard isAppleActive else {
            contract?.requestPlay()
            notifyState()
            return true
        }
        guard appleVoice != nil, var contract else { return false }

        if contract.lifecycle == .suspended {
            contract.requestPlay()
            self.contract = contract
            notifyState()
            return true
        }
        guard contract.lifecycle == .active else { return false }

        let alreadyPlaying = contract.desiredPlayIntent == .playing
        contract.requestPlay()
        self.contract = contract

        if alreadyPlaying, appleProducer.isSpeaking || appleProducer.totalBufferedCount > 0 {
            notifyState()
            return true
        }

        lastError = nil

        if appleProducer.totalBufferedCount == 0 {
            pumpAppleUtterances()
        } else if appleProducer.isPaused {
            appleProducer.resume()
        }
        notifyState()
        return true
    }

    func pause() {
        cancelPendingHandback()
        currentlySpeakingSegmentOrdinal = nil
        appleProducer.stop()
        pendingWord = nil
        terminalCallbacks.removeAll(keepingCapacity: true)
        contract?.pause()
        guard isAppleActive else {
            notifyState()
            return
        }
        let resetCursor = contract?.displayCursor ?? contract?.sourceCursor
        if let resetCursor {
            _ = contract?.seek(to: resetCursor)
            nextSegmentIndex = firstSegmentIndex(after: resetCursor)
        } else if let cursor = contract?.sourceCursor {
            nextSegmentIndex = firstSegmentIndex(after: cursor)
        }
        onActualPlayingChanged?(false)
        notifyState()
    }

    @discardableResult
    func seek(to cursor: PlaybackSourceCursor) -> Bool {
        cancelPendingHandback()
        currentlySpeakingSegmentOrdinal = nil
        guard var contract else { return false }
        guard let normalizedCursor = cursorForCharacterOffset(
            cursor.globalUTF16Offset,
            sourceLength: contract.sourceUTF16Length
        ) else { return false }

        guard isAppleActive else {
            let success = contract.seek(to: normalizedCursor)
            self.contract = contract
            notifyState()
            return success
        }

        let wasPlaying = contract.desiredPlayIntent == .playing
        guard contract.seek(to: normalizedCursor) else { return false }
        self.contract = contract
        appleProducer.stop()
        pendingWord = nil
        terminalCallbacks.removeAll(keepingCapacity: true)
        nextSegmentIndex = firstSegmentIndex(after: normalizedCursor)
        onActualPlayingChanged?(false)
        if wasPlaying {
            pumpAppleUtterances()
        }
        notifyState()
        return true
    }

    @discardableResult
    func seek(toUTF16Offset offset: Int) -> Bool {
        guard let cursor = cursorForCharacterOffset(
            offset,
            sourceLength: document?.bodyText.utf16.count ?? 0
        ) else { return false }
        return seek(to: cursor)
    }

    func seek(to targetTime: TimeInterval) {
        guard let document = document else { return }
        let totalDuration = document.estimatedDuration > 0 ? document.estimatedDuration : 1.0
        let safeTargetTime = max(0, min(targetTime, totalDuration))
        let ratio = safeTargetTime / totalDuration
        let targetOffset = Int(ratio * Double(document.bodyText.utf16.count))
        _ = seek(toUTF16Offset: targetOffset)
    }



    @discardableResult
    func beginInterruption() -> Bool {
        guard var contract, contract.lifecycle == .active else { return false }
        cancelPendingHandback()
        currentlySpeakingSegmentOrdinal = nil
        appleProducer.stop()
        pendingWord = nil
        terminalCallbacks.removeAll(keepingCapacity: true)
        let resetCursor = contract.displayCursor ?? contract.sourceCursor
        if let resetCursor {
            _ = contract.seek(to: resetCursor)
            nextSegmentIndex = firstSegmentIndex(after: resetCursor)
        } else {
            nextSegmentIndex = 0
        }
        contract.beginInterruption()
        self.contract = contract
        onActualPlayingChanged?(false)
        notifyState()
        return true
    }

    @discardableResult
    func endInterruption(shouldResume: Bool) -> Bool {
        guard var contract,
              contract.lifecycle == .suspended,
              contract.endInterruption() else { return false }

        if !shouldResume, contract.desiredPlayIntent == .playing {
            contract.pause()
        }
        self.contract = contract
        if shouldResume, contract.desiredPlayIntent == .playing {
            _ = play()
            return true
        } else {
            onActualPlayingChanged?(false)
        }
        notifyState()
        return true
    }

    func setSpeechRateMultiplier(_ multiplier: Float) {
        speechRateMultiplier = max(0.5, min(3.0, multiplier))
    }

    func cancel() {
        isFallbackActive = false
        cancelPendingHandback()
        currentlySpeakingSegmentOrdinal = nil
        appleProducer.stop()
        pendingWord = nil
        terminalCallbacks.removeAll(keepingCapacity: true)
        let resetCursor = contract?.displayCursor ?? contract?.sourceCursor
        if let resetCursor {
            _ = contract?.seek(to: resetCursor)
        }
        _ = contract?.cancel()
        onActualPlayingChanged?(false)
        notifyState()
    }

    /// Final release after cancellation, used when the chapter may be deleted.
    func releaseSession() {
        cancel()
        document = nil
        contract = nil
        segments = []
        nextSegmentIndex = 0
        appleVoice = nil
        resolvedFallbackIdentifier = nil
        lastError = nil
    }

    // MARK: - Fallback & Boundary Routing

    /// Commits a completed sentence boundary into the state machine.
    func commitSentenceBoundary(at cursor: PlaybackSourceCursor) {
        guard var currentContract = self.contract else { return }
        if currentContract.commitBoundary(to: cursor) {
            self.contract = currentContract
        }
    }

    /// Commits the boundary of a completed played chunk.
    func commitChunkBoundary(_ chunk: PlayedChunk) {
        if case .generated(let identity) = chunk.identity {
            if let cursor = PlaybackSourceCursor(
                segmentOrdinal: identity.segmentID.ordinal,
                globalUTF16Offset: identity.segmentID.utf16Range.upperBound
            ) {
                commitSentenceBoundary(at: cursor)
            }
        } else if let lastWord = chunk.timestamps.last,
                  let loc = lastWord.rangeLocation,
                  let len = lastWord.rangeLength {
            let offset = loc + len
            if let cursor = cursorForCharacterOffset(offset, sourceLength: contract?.sourceUTF16Length ?? 0) {
                commitSentenceBoundary(at: cursor)
            }
        }
    }

    /// Synchronizes the session contract cursor to an explicit character offset (e.g. on seek).
    func syncCursor(toUTF16Offset offset: Int) {
        let sourceLength = contract?.sourceUTF16Length ?? document?.bodyText.utf16.count ?? 0
        guard let cursor = cursorForCharacterOffset(offset, sourceLength: sourceLength) else { return }
        _ = contract?.seek(to: cursor)
    }

    /// Advances the highlight/display cursor during playback (e.g. from word timestamps during Kokoro playback).
    func advanceDisplay(toUTF16Offset offset: Int) {
        let sourceLength = contract?.sourceUTF16Length ?? document?.bodyText.utf16.count ?? 0
        guard let cursor = cursorForCharacterOffset(offset, sourceLength: sourceLength) else { return }
        guard var currentContract = self.contract else { return }
        if currentContract.advanceDisplay(to: cursor) {
            self.contract = currentContract
        }
    }

    /// Dynamically updates preferences and immediately applies Apple voice changes.
    func updateVoicePreferences(_ preferences: VoicePreferences) {
        // Intentionally leave the running snapshot unchanged.
    }

    func restorePausedPrimary(at offset: Int) {
        guard isFallbackActive, var current = contract, current.lifecycle == .active,
              current.desiredPlayIntent == .paused else { return }
        cancelPendingHandback()
        appleProducer.stop()
        terminalCallbacks.removeAll()
        currentlySpeakingSegmentOrdinal = nil
        pendingWord = nil
        _ = current.releaseProducer(.apple)
        _ = current.acquireProducer(.kokoro)
        if let cursor = cursorForCharacterOffset(offset, sourceLength: current.sourceUTF16Length) { _ = current.seek(to: cursor) }
        contract = current
        isFallbackActive = false
        notifyState()
    }

    @discardableResult func completeAtEOF() -> Bool {
        guard var current = contract else { return false }
        if current.lifecycle == .completed { isFallbackActive = false; cancelPendingHandback(); return true }
        guard current.lifecycle == .active,
              let cursor = PlaybackSourceCursor(segmentOrdinal: max(0, segments.count - 1), globalUTF16Offset: current.sourceUTF16Length) else { return false }
        if let producer = current.activeProducer { _ = current.releaseProducer(producer) }
        guard current.completeLogicalDocumentAtEOF(at: cursor) else { return false }
        contract = current
        isFallbackActive = false
        cancelPendingHandback()
        appleProducer.stop(); terminalCallbacks.removeAll(); pendingWord = nil
        return true
    }

    /// Triggers one-way fallback from Kokoro to Apple Speech.
    /// Seamlessly switches the active producer to AppleSpeechProducer and resumes
    /// exactly at the last spoken sentence or word boundary without crashing or stopping playback.
    @discardableResult
    func triggerFallback(
        resumeCursor: PlaybackSourceCursor? = nil,
        reason: String? = nil
    ) -> Bool {
        guard !isFallbackActive, let current = contract, current.lifecycle == .active,
              current.desiredPlayIntent == .playing,
              current.displayCursor?.globalUTF16Offset != current.sourceUTF16Length else { return false }
        guard contract?.activeProducer != .apple else { return false }
        if case .apple = contract?.primaryVoice {
            return false // Primary voice is already Apple Speech; no fallback necessary
        }

        if let reason { PlaybackDiagnostics.shared.record("fallback reason=\(reason)") }

        isFallbackActive = true

        // 1. Resolve fallback Apple voice from contract or stored preferences
        let fallbackIdentifier = contract?.fallbackAppleVoiceIdentifier
            ?? VoicePreferencesStore().load().fallbackAppleVoiceIdentifier
        if appleVoice == nil || resolvedFallbackIdentifier != fallbackIdentifier {
            appleVoice = resolveAppleVoice(identifier: fallbackIdentifier)
            resolvedFallbackIdentifier = fallbackIdentifier
        }

        // 2. Determine target cursor (prefer active display/source cursor to avoid repeating mid-chunk)
        let targetCursor = resumeCursor
            ?? contract?.displayCursor
            ?? contract?.sourceCursor
            ?? contract?.committedCursor
            ?? .beginning

        // 3. Reconcile state machine contract: release Kokoro, acquire Apple, and seek to targetCursor
        if var currentContract = self.contract {
            if currentContract.activeProducer == .kokoro {
                _ = currentContract.releaseProducer(.kokoro)
            }
            _ = currentContract.acquireProducer(.apple)
            _ = currentContract.seek(to: targetCursor)
            self.contract = currentContract
        }

        // 4. Invalidate Apple producer's internal queues and set next segment
        appleProducer.stop()
        terminalCallbacks.removeAll(keepingCapacity: true)
        nextSegmentIndex = firstSegmentIndex(after: targetCursor)

        // 5. If playback was active or desired, activate audio session and start Apple speech immediately
        let wasPlaying = desiredPlayIntent == .playing || (contract?.desiredPlayIntent == .playing)
        if wasPlaying {
            _ = contract?.requestPlay()
            pumpAppleUtterances()
        }

        notifyState()
        onActualPlayingChanged?(isPlaying)
        return true
    }



    // MARK: - Speculative Handback Coordination (Phase 6)

    func beginHandbackPreparation(_ session: PlaybackGenerationSession) {
        cancelPendingHandback()
        handbackPreparationID = session.id
        handbackState = .preparing(session.id)
    }

    func finishHandbackPreparation(_ id: UUID) {
        guard handbackPreparationID == id else { return }
        if stagedHandbackChunks.isEmpty { cancelPendingHandback() }
        // Apple keeps pumping unless a contiguous successor is actually ready.
    }

    func stageHandbackChunk(_ chunk: AudioChunk, session: PlaybackGenerationSession? = nil) {
        guard isFallbackActive, let session, session.id == handbackPreparationID,
              contract?.lifecycle == .active, contract?.desiredPlayIntent == .playing,
              session.documentID == document?.id, session.voice == contract?.primaryVoice,
              chunk.identity.sessionID == session.id, chunk.identity.documentID == session.documentID,
              chunk.identity.voice == session.voice,
              playbackEngine.map({ $0.applicationPhase == .active }) ?? true else { return }
        let target = currentOrUpcomingSegmentIndex
        guard chunk.identity.segmentID.ordinal >= target else { return }
        if !stagedHandbackChunks.contains(where: { $0.identity.segmentID == chunk.identity.segmentID }) {
            stagedHandbackChunks.append(chunk)
            stagedHandbackChunks.sort { $0.identity.segmentID.ordinal < $1.identity.segmentID.ordinal }
        }
        stagedHandbackSession = session
        handbackState = .ready(session.id)
        isHandbackPending = true
        if currentlySpeakingSegmentOrdinal == nil && !appleProducer.isSpeaking { _ = executeHandback() }
    }

    func cancelPendingHandback() {
        isHandbackPending = false
        stagedHandbackChunks.removeAll()
        stagedHandbackSession = nil
        handbackPreparationID = nil
        handbackState = .idle
    }

    @discardableResult func triggerHandback(chunks: [AudioChunk]? = nil) -> Bool {
        guard isFallbackActive else { return false }
        if currentlySpeakingSegmentOrdinal != nil || appleProducer.isSpeaking { return false }
        return executeHandback()
    }

    @discardableResult func executeHandback() -> Bool {
        guard isFallbackActive, var current = contract, current.lifecycle == .active,
              current.desiredPlayIntent == .playing, let session = stagedHandbackSession,
              session.id == handbackPreparationID,
              playbackEngine.map({ $0.applicationPhase == .active }) ?? true else { return false }
        let target = firstSegmentIndex(after: current.committedCursor ?? .beginning)
        stagedHandbackChunks.removeAll { $0.identity.segmentID.ordinal < target }
        guard let first = stagedHandbackChunks.first, first.identity.segmentID.ordinal == target else { return false }
        let chunks = stagedHandbackChunks
        appleProducer.stop(); terminalCallbacks.removeAll(); pendingWord = nil
        currentlySpeakingSegmentOrdinal = nil
        _ = current.releaseProducer(.apple)
        guard current.acquireProducer(.kokoro) else { return false }
        contract = current
        isFallbackActive = false
        cancelPendingHandback()
        if let playbackEngine { playbackEngine.resumeFromHandback(chunks: chunks, session: session) }
        else { onPerformHandback?(chunks, current.committedCursor ?? .beginning) }
        notifyState()
        return true
    }

    // MARK: - Private Producer Wiring & Scheduling

    private func wireAppleProducer() {
        appleProducer.onActivityChanged = { [weak self] callback, active in
            guard let self, self.contract?.accepts(callback) == true else { return }
            self.onActualPlayingChanged?(active)
        }
        appleProducer.onDidStart = { [weak self] callback in
            self?.handleDidStart(callback)
        }
        appleProducer.onWillSpeak = { [weak self] callback, range in
            self?.handleWillSpeak(callback, range: range)
        }
        appleProducer.onDidFinish = { [weak self] callback in
            self?.handleDidFinish(callback)
        }
        appleProducer.onDidCancel = { [weak self] callback in
            self?.handleDidCancel(callback)
        }
    }

    private func pumpAppleUtterances() {
        guard isAppleActive,
              let voice = appleVoice,
              var contract = self.contract,
              contract.lifecycle == .active,
              contract.desiredPlayIntent == .playing
        else { return }

        if isFallbackActive && !automaticFallbackAllowed {
            if appleProducer.totalBufferedCount == 0 { onActualPlayingChanged?(false); onWaitingForPrimary?() }
            return
        }
        while appleProducer.totalBufferedCount < 1 && nextSegmentIndex < segments.count {
            let segment = segments[nextSegmentIndex]
            let segmentStart = segment.nsRange.location
            let segmentEnd = segment.nsRange.location + segment.nsRange.length
            let cursorOffset = max(
                0,
                min(
                    contract.sourceCursor?.globalUTF16Offset ?? 0,
                    contract.sourceUTF16Length
                )
            )
            var requestedLocalOffset = max(
                0,
                min(cursorOffset - segmentStart, segment.text.utf16.count)
            )
            
            let utf16 = segment.text.utf16
            var currentIdx = utf16.index(utf16.startIndex, offsetBy: requestedLocalOffset)
            let boundaryChars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            while currentIdx > utf16.startIndex && currentIdx < utf16.endIndex {
                let codeUnit = utf16[currentIdx]
                if codeUnit < 0xD800 || codeUnit > 0xDFFF {
                    if let scalar = UnicodeScalar(codeUnit), boundaryChars.contains(scalar) {
                        break
                    }
                }
                
                let prevIdx = utf16.index(before: currentIdx)
                let prevCodeUnit = utf16[prevIdx]
                if prevCodeUnit < 0xD800 || prevCodeUnit > 0xDFFF {
                    if let scalar = UnicodeScalar(prevCodeUnit), boundaryChars.contains(scalar) {
                        break
                    }
                }
                currentIdx = prevIdx
            }
            requestedLocalOffset = utf16.distance(from: utf16.startIndex, to: currentIdx)

            let localOffset = normalizedUTF16Offset(
                requestedLocalOffset,
                in: segment.text
            )
            let sourceStart = segmentStart + localOffset
            let sourceLength = segment.nsRange.length - localOffset
            nextSegmentIndex += 1

            guard sourceLength > 0 else { continue }
            let isTerminal = nextSegmentIndex == segments.count
            let boundaryOffset = isTerminal ? contract.sourceUTF16Length : segmentEnd
            guard let sourceBoundary = PlaybackSourceCursor(
                segmentOrdinal: segment.id.ordinal,
                globalUTF16Offset: boundaryOffset
            ),
            let sourceRange = UTF16TextRange.validated(
                location: sourceStart,
                length: sourceLength,
                withinUTF16Length: contract.sourceUTF16Length
            ) else { continue }

            let text = suffix(of: segment.text, utf16Offset: localOffset)
            guard PlaybackSourceProgress.hasSpeech(text),
                  let callback = contract.beginCallback(
                      for: .apple,
                      sourceBoundary: sourceBoundary
                  ) else { continue }

            self.contract = contract
            if isTerminal {
                terminalCallbacks.insert(callback.utteranceID)
            }
            appleProducer.speak(
                AppleSpeechProducer.Request(
                    callback: callback,
                    text: text,
                    sourceRange: sourceRange,
                    voice: voice,
                    rate: AppleSpeechProducer.speechRate(for: speechRateMultiplier)
                )
            )
        }

        self.contract = contract
        notifyState()

        if appleProducer.totalBufferedCount == 0 && nextSegmentIndex >= segments.count {
            guard let eofCursor = PlaybackSourceCursor(
                segmentOrdinal: max(
                    contract.sourceCursor?.segmentOrdinal ?? 0,
                    segments.last?.id.ordinal ?? 0
                ),
                globalUTF16Offset: contract.sourceUTF16Length
            ), contract.completeLogicalDocumentAtEOF(at: eofCursor) else { return }
            self.contract = contract
            notifyState()
            onActualPlayingChanged?(false)
            onCompleted?()
        }
    }



    private func handleDidStart(_ callback: PlaybackCallbackIdentity) {
        guard var contract,
              contract.accepts(callback),
              contract.markProducerPlaying(
                  .apple,
                  event: PlaybackEventIdentity(
                      sessionID: callback.sessionID,
                      callbackGeneration: callback.callbackGeneration,
                      producer: callback.producer
                  )
              )
        else { return }
        self.contract = contract
        currentlySpeakingSegmentOrdinal = callback.sourceBoundary.segmentOrdinal
        onActualPlayingChanged?(true)
        notifyState()
    }

    private func handleWillSpeak(
        _ callback: PlaybackCallbackIdentity,
        range: UTF16TextRange
    ) {
        guard var contract,
              let cursor = PlaybackSourceCursor(
                  segmentOrdinal: callback.sourceBoundary.segmentOrdinal,
                  globalUTF16Offset: range.location
              ),
              contract.willSpeak(cursor, callback: callback)
        else { return }
        self.contract = contract
        currentlySpeakingSegmentOrdinal = callback.sourceBoundary.segmentOrdinal
        if let pendingWord, pendingWord != range { onSpokenWordCompleted?(pendingWord) }
        pendingWord = range
        onDisplayRange?(range)
        let estimatedTime = estimatedTime(for: cursor)

        var wordText = ""
        if let bodyText = document?.bodyText {
            let nsString = bodyText as NSString
            let safeLocation = max(0, min(range.location, nsString.length))
            let safeLength = max(0, min(range.length, nsString.length - safeLocation))
            if safeLength > 0 {
                wordText = nsString.substring(with: NSRange(location: safeLocation, length: safeLength))
            }
        }
        let wordDuration = max(0.05, Double(max(1, range.length)) * 0.05 / Double(speechRateMultiplier))
        let wordEndTime = estimatedTime + wordDuration

        onProgress?(
            estimatedTime,
            WordTimestamp(
                word: wordText,
                startTime: estimatedTime,
                endTime: wordEndTime,
                rangeLocation: range.location,
                rangeLength: range.length
            )
        )
        notifyState()
    }

    private func handleDidFinish(_ callback: PlaybackCallbackIdentity) {
        guard var current = contract, current.accepts(callback) else { return }
        let terminal = terminalCallbacks.remove(callback.utteranceID) != nil
        let accepted = terminal
            ? current.completeLogicalDocument(at: callback.sourceBoundary, callback: callback)
            : current.didFinish(at: callback.sourceBoundary, callback: callback)
        guard accepted else { return }
        if let pendingWord { onSpokenWordCompleted?(pendingWord) }
        pendingWord = nil
        contract = current
        currentlySpeakingSegmentOrdinal = nil
        onActualPlayingChanged?(false)
        if terminal { onCompleted?(); notifyState(); return }
        if isFallbackActive, !stagedHandbackChunks.isEmpty, executeHandback() { return }
        if current.desiredPlayIntent == .playing { pumpAppleUtterances() }
        notifyState()
    }

    private func handleDidCancel(_ callback: PlaybackCallbackIdentity) {
        guard contract?.accepts(callback) == true else { return }
        pendingWord = nil
        terminalCallbacks.remove(callback.utteranceID)
        if currentlySpeakingSegmentOrdinal == callback.sourceBoundary.segmentOrdinal {
            currentlySpeakingSegmentOrdinal = nil
        }
        guard var contract,
              contract.accepts(callback) else { return }

        contract.pause()
        if let event = contract.eventIdentity(for: callback.producer) {
            _ = contract.markRecoverablePause(event: event)
        }
        lastError = Constants.speechCancelled
        let resetCursor = contract.displayCursor ?? contract.sourceCursor
        if let resetCursor {
            _ = contract.seek(to: resetCursor)
            nextSegmentIndex = firstSegmentIndex(after: resetCursor)
        } else {
            nextSegmentIndex = 0
        }
        self.contract = contract
        onActualPlayingChanged?(false)
        notifyState()
    }

    private func resolveAppleVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        let provider = AVFoundationSpeechVoiceProvider()
        let candidates = provider.availableVoices()
        let preferredLocale = identifier.flatMap { id in
            candidates.first(where: { $0.identifier == id })?.language
        } ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let catalog = AppleSpeechVoiceCatalog(provider: provider, changeObserver: nil)
        let defaultCandidate = candidates.first(where: { candidate in
            guard case .default = candidate.quality,
                  !candidate.isNoveltyVoice,
                  !candidate.isPersonalVoice
            else { return false }
            let preferredLang = languageCode(preferredLocale) ?? Constants.defaultLanguageCode
            return languageCode(candidate.language) == preferredLang
        })
        let resolution = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: identifier,
            preferredLocale: preferredLocale,
            eligibleVoices: catalog.voices,
            compatibleSystemDefault: defaultCandidate
        )
        switch resolution {
        case .chosen(let descriptor), .sameLocale(let descriptor), .highestQuality(let descriptor):
            if let voice = AVSpeechSynthesisVoice(identifier: descriptor.id) {
                return voice
            }
        case .compatibleSystemDefault(let candidate):
            if let voice = AVSpeechSynthesisVoice(identifier: candidate.identifier) ?? AVSpeechSynthesisVoice(language: candidate.language) {
                return voice
            }
        case .unavailable:
            break
        }
        // Fallback for physical devices / simulators without enhanced voices downloaded
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Constants.defaultVoiceLanguage)
            ?? candidates.first(where: { languageCode($0.language) == Constants.defaultLanguageCode }).flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? candidates.first.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
    }

    private func firstSegmentIndex(after cursor: PlaybackSourceCursor) -> Int {
        segments.firstIndex {
            $0.id.ordinal > cursor.segmentOrdinal
                || ($0.id.ordinal == cursor.segmentOrdinal
                    && $0.nsRange.location + $0.nsRange.length > cursor.globalUTF16Offset)
        } ?? segments.count
    }

    private func cursorForCharacterOffset(
        _ offset: Int,
        sourceLength: Int
    ) -> PlaybackSourceCursor? {
        let safeLength = max(0, sourceLength)
        let safeOffset = normalizedUTF16Offset(offset, sourceLength: safeLength)
        if let segment = segments.first(where: {
            $0.nsRange.location + $0.nsRange.length > safeOffset
        }) {
            return PlaybackSourceCursor(
                segmentOrdinal: segment.id.ordinal,
                globalUTF16Offset: safeOffset
            )
        }
        return PlaybackSourceCursor(
            segmentOrdinal: segments.last?.id.ordinal ?? 0,
            globalUTF16Offset: safeOffset
        )
    }

    private func suffix(of text: String, utf16Offset: Int) -> String {
        let safeOffset = max(0, min(utf16Offset, text.utf16.count))
        guard safeOffset > 0 else { return text }
        guard safeOffset < text.utf16.count else { return "" }

        var start = text.startIndex
        for index in text.indices {
            let boundary = index.utf16Offset(in: text)
            if boundary > safeOffset { break }
            start = index
        }
        return String(text[start...])
    }

    private func normalizedUTF16Offset(_ offset: Int, sourceLength: Int) -> Int {
        guard sourceLength > 0 else { return 0 }
        let safeOffset = max(0, min(offset, sourceLength))
        guard safeOffset < sourceLength,
              let source = document?.bodyText,
              source.utf16.count == sourceLength else {
            return safeOffset
        }
        return normalizedUTF16Offset(safeOffset, in: source)
    }

    private func normalizedUTF16Offset(_ offset: Int, in text: String) -> Int {
        let safeOffset = max(0, min(offset, text.utf16.count))
        guard safeOffset > 0, safeOffset < text.utf16.count else {
            return safeOffset
        }

        var normalized = 0
        for index in text.indices {
            let boundary = index.utf16Offset(in: text)
            if boundary > safeOffset { break }
            normalized = boundary
        }
        return normalized
    }

    private func estimatedTime(for cursor: PlaybackSourceCursor) -> TimeInterval {
        guard let document, contract?.sourceUTF16Length ?? 0 > 0 else { return 0 }
        let ratio = Double(cursor.globalUTF16Offset)
            / Double(contract?.sourceUTF16Length ?? 1)
        return max(0, min(document.estimatedDuration, ratio * document.estimatedDuration))
    }

    private func languageCode(_ language: String) -> String? {
        Locale.Language(identifier: language.replacingOccurrences(of: Constants.underscore, with: Constants.dash))
            .languageCode?.identifier
            .lowercased()
    }

    private func notifyState() {
        if let contract {
            onStateChange?(contract)
        }
    }
}


