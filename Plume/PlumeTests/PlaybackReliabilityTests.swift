import Combine
import Testing
import Foundation
import AVFoundation
import SwiftData
@testable import Plume

@MainActor private final class ReliabilitySpeech: SpeechSynthesizing {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    var usesApplicationAudioSession = false
    var spoken: [AVSpeechUtterance] = []
    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance); isSpeaking = true }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { isPaused = true; isSpeaking = false; return true }
    func continueSpeaking() -> Bool { isPaused = false; isSpeaking = true; return true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isSpeaking = false; return true }
}

@MainActor private final class ControlledGeneration: PlaybackChunkStream {
    private var result: CheckedContinuation<AudioGenerationOutcome, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func nextResult() async throws -> AudioGenerationOutcome {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func fail() { result?.resume(throwing: NSError(domain: "FixtureFailure", code: 9)); result = nil }
    func finish() { result?.resume(returning: .endOfDocument); result = nil }
}

@MainActor private final class TestSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    func send() { fired = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor private final class PunctuationGeneration: PlaybackChunkStream {
    private let segment: DocumentSegmentID
    private var returned = false
    init(segment: DocumentSegmentID) { self.segment = segment }
    func nextResult() async throws -> AudioGenerationOutcome {
        if returned { return .endOfDocument }
        returned = true
        return .nonSpeech(segment)
    }
}

// The old entity name/fields match the shipped, pre-measurement store. Opening
// that SQLite store with the current model exercises the additive migration.
private enum BeforeMeasurement {
    @Model final class ListeningSession {
        @Attribute(.unique) var id: UUID
        var documentId: UUID
        var date: Date
        var secondsListened: Double
        var wordsListened: Int
        var playbackSpeed: Double
        init() {
            id = UUID(); documentId = UUID(); date = Date()
            secondsListened = 60; wordsListened = 150; playbackSpeed = 1
        }
    }
}

@MainActor @Suite struct PlaybackLifecycleReliabilityTests {
    private func makeEngine(text: String = "First sentence. Next sentence.") -> (AudioPlaybackEngine, Document, ReliabilitySpeech) {
        let speech = ReliabilitySpeech()
        let coordinator = PlaybackRoutingCoordinator(appleProducer: AppleSpeechProducer(synthesizer: speech))
        let manager = AudioGenerationManager()
        manager.makeStream = { _, _, _ in throw NSError(domain: "UnexpectedGenerationInTest", code: 1) }
        let engine = AudioPlaybackEngine(observeSystem: false, manager: manager, routing: coordinator)
        engine.hasPrewarmedSpeech = true
        engine.audioReadyOverride = { true }
        engine.prepareAudioOverride = { $0(.success(())) }
        let doc = Document(title: "Fixture", bodyText: text)
        engine.load(document: doc)
        _ = coordinator.begin(document: doc, snapshot: PlaybackSessionSnapshot(documentID: doc.id,
            preferences: VoicePreferences(primary: .kokoro(identifier: "af_heart"), fallbackAppleVoiceIdentifier: nil)))
        return (engine, doc, speech)
    }

    @Test func pausedBackgroundNeverSwitchesOrStarts() {
        let (engine, _, speech) = makeEngine()
        engine.pause()
        engine.handleLifecycle(.background)
        engine.triggerFallbackToAppleSpeech(reason: "late-background-callback")
        engine.handleLifecycle(.active)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(!engine.isFallbackActive)
        #expect(speech.spoken.isEmpty)
        #expect(!engine.generationManager.isGeneratingAny)
    }

    @Test func inactivityPreservesBufferedQueueAndIntent() {
        let (engine, doc, speech) = makeEngine()
        let session = PlaybackGenerationSession(documentID: doc.id, voice: .kokoro(identifier: "af_heart"))
        engine.beginGenerationSession(session)
        let url = URL(fileURLWithPath: "/nonexistent/test-buffer.m4a")
        let item = AVPlayerItem(url: url)
        engine.insertQueuedItem(item)
        engine.coordinator.requestPlayIntent()
        engine.handleLifecycle(.inactive)
        #expect(engine.queuePlayer?.currentItem === item)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(!engine.isFallbackActive)
        #expect(speech.spoken.isEmpty)
        engine.pause()
    }

    @Test func pausedFallbackReturnsToPrimaryWithoutSound() {
        let (engine, _, speech) = makeEngine()
        engine.coordinator.requestPlayIntent()
        #expect(engine.coordinator.triggerFallback())
        engine.pause()
        let count = speech.spoken.count
        engine.handleLifecycle(.background)
        engine.handleLifecycle(.active)
        #expect(!engine.isFallbackActive)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(speech.spoken.count == count)
    }

    @Test func completionSurvivesBackgroundAndFallbackRequests() {
        let (engine, doc, speech) = makeEngine(text: "A sentence…\"\n\n")
        engine.coordinator.requestPlayIntent()
        engine.generationEOF = true
        engine.completeLogicalPlayback()
        engine.completeLogicalPlayback()
        engine.handleLifecycle(.background)
        engine.triggerFallbackToAppleSpeech(reason: "late-underrun")
        #expect(engine.coordinator.contract?.lifecycle == .completed)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(doc.lastReadCharIndex == doc.bodyText.utf16.count)
        #expect(doc.readingProgress == 1)
        #expect(speech.spoken.isEmpty)
    }

    @Test func openingCompletedDocumentDoesNotStartOrAdvancePlayback() {
        let (engine, doc, speech) = makeEngine()
        doc.lastReadCharIndex = doc.bodyText.utf16.count
        var advances = 0
        engine.advanceQueue = { advances += 1 }
        engine.load(document: doc)
        engine.handleLifecycle(.active)
        #expect(engine.coordinator.contract?.lifecycle == .completed)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(!engine.isPlaying)
        #expect(advances == 0)
        #expect(speech.spoken.isEmpty)
    }

    @Test func generationEOFDoesNotCompleteUnplayedAudio() {
        let (engine, doc, _) = makeEngine()
        let session = PlaybackGenerationSession(documentID: doc.id, voice: .kokoro(identifier: "af_heart"))
        engine.beginGenerationSession(session)
        engine.insertQueuedItem(AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/queued.m4a")))
        engine.generationReachedEOF(sessionID: session.id)
        #expect(engine.coordinator.contract?.lifecycle == .active)
        #expect(engine.generationEOF)
    }

    @Test func interruptionPreservesIntentButPauseWins() {
        let (engine, _, speech) = makeEngine()
        engine.coordinator.requestPlayIntent()
        engine.handleInterruption(.began, shouldResume: false)
        #expect(engine.coordinator.contract?.lifecycle == .suspended)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        engine.pause()
        engine.handleInterruption(.ended, shouldResume: true)
        #expect(engine.coordinator.contract?.lifecycle == .active)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(speech.spoken.isEmpty)
    }

    @Test func activePreferenceChangeDoesNotMutateSnapshot() {
        let (engine, _, _) = makeEngine()
        let snapshot = engine.currentSnapshot
        engine.coordinator.updateVoicePreferences(VoicePreferences(primary: .apple(identifier: "different"), fallbackAppleVoiceIdentifier: "other"))
        #expect(engine.currentSnapshot == snapshot)
    }

    @Test func handbackPreparationFailureDoesNotSuppressApplePump() {
        let (engine, doc, speech) = makeEngine()
        let coordinator = engine.coordinator
        coordinator.requestPlayIntent()
        #expect(coordinator.triggerFallback())
        let session = PlaybackGenerationSession(documentID: doc.id, voice: .kokoro(identifier: "af_heart"))
        coordinator.beginHandbackPreparation(session)
        coordinator.finishHandbackPreparation(session.id)
        #expect(coordinator.handbackState == .idle)
        #expect(!coordinator.isHandbackPending)
        #expect(!speech.spoken.isEmpty)
        #expect(coordinator.desiredPlayIntent == .playing)
        engine.pause()
    }

    @Test func staleCallbacksCannotChangeSpeakingOrdinal() {
        let (engine, _, _) = makeEngine()
        let callback = PlaybackCallbackIdentity(sessionID: UUID(), callbackGeneration: 0, utteranceID: UUID(),
            producer: .apple, sourceBoundary: .beginning)
        engine.coordinator.appleProducer.onDidStart?(callback)
        engine.coordinator.appleProducer.onWillSpeak?(callback, UTF16TextRange(location: 0, length: 1))
        #expect(engine.coordinator.currentlySpeakingSegmentOrdinal == nil)
    }

    @Test func obsoleteHandbackCannotStageIntoAnotherPreparation() {
        let (engine, doc, _) = makeEngine()
        let coordinator = engine.coordinator
        coordinator.requestPlayIntent()
        _ = coordinator.triggerFallback()
        let old = PlaybackGenerationSession(documentID: doc.id, voice: .kokoro(identifier: "af_heart"))
        coordinator.beginHandbackPreparation(PlaybackGenerationSession(documentID: doc.id, voice: old.voice))
        let segment = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)[0]
        let chunk = AudioChunk(identity: GeneratedAudioChunkIdentity(session: old, segmentID: segment.id),
            fileURL: URL(fileURLWithPath: "/nonexistent/obsolete.m4a"), duration: 1, timestamps: [])
        coordinator.stageHandbackChunk(chunk, session: old)
        #expect(coordinator.stagedHandbackChunks.isEmpty)
        engine.pause()
    }

    @Test(arguments: [false, true])
    func handbackRequiresTheExactNextUnspokenSentence(ahead: Bool) async throws {
        let (engine, doc, speech) = makeEngine(text: "First sentence. Second sentence. Third sentence.")
        let coordinator = engine.coordinator
        coordinator.playbackEngine = nil
        var handedOrdinal: Int?
        coordinator.onPerformHandback = { chunks, _ in handedOrdinal = chunks.first?.identity.segmentID.ordinal }
        var events = coordinator.appleProducer.makeEventStream().makeAsyncIterator()
        coordinator.requestPlayIntent()
        #expect(coordinator.triggerFallback())
        let utterance = try #require(speech.spoken.first)
        speech.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)
        _ = await events.next()
        let session = PlaybackGenerationSession(documentID: doc.id, voice: .kokoro(identifier: "af_heart"))
        coordinator.beginHandbackPreparation(session)
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        let id = segments[ahead ? 2 : 1].id
        coordinator.stageHandbackChunk(AudioChunk(identity: GeneratedAudioChunkIdentity(session: session, segmentID: id),
            fileURL: URL(fileURLWithPath: "/nonexistent/staged.m4a"), duration: 1, timestamps: []), session: session)
        speech.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
        _ = await events.next()
        #expect(coordinator.isFallbackActive == ahead)
        #expect(handedOrdinal == (ahead ? nil : 1))
        #expect(speech.spoken.count == (ahead ? 2 : 1))
        coordinator.pause()
    }

    @Test func disabledFallbackWaitsWithoutStartingSpeechOrGenerationInBackground() {
        let (engine, _, speech) = makeEngine()
        engine.automaticFallbackOverride = { false }
        engine.coordinator.requestPlayIntent()
        engine.handleLifecycle(.background)
        engine.reconcilePlayback(explicit: false)
        #expect(engine.isWaitingForForeground)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(!engine.isFallbackActive)
        #expect(speech.spoken.isEmpty)
        #expect(!engine.generationManager.isGeneratingAny)
        engine.pause()
        #expect(!engine.isWaitingForForeground)
    }

    @Test func failedRestorationWithFallbackDisabledExposesRetryInsteadOfWaitingForever() async throws {
        let (engine, doc, speech) = makeEngine()
        engine.coordinator.requestPlayIntent()
        _ = engine.coordinator.triggerFallback()
        speech.isSpeaking = false // between owned utterances
        engine.automaticFallbackOverride = { false }
        engine.coordinator.automaticFallbackAllowed = false
        engine.generationManager.startSpeculativePreparation(document: doc, playbackEngine: engine, startChunkIndex: 0)
        for await preparing in engine.generationManager.$isSpeculativeGenerating.values {
            if !preparing { break }
        }
        #expect(engine.generationManager.lastError != nil)
        // Disabling fallback lets the owned sentence finish before pausing.
        var events = engine.coordinator.appleProducer.makeEventStream().makeAsyncIterator()
        let utterance = try #require(speech.spoken.first)
        speech.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
        _ = await events.next()
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(!engine.isWaitingForForeground)
    }

    @Test(arguments: [false, true])
    func interruptedGenerationRetainsIntentAndSeekDestination(seeking: Bool) async throws {
        let (engine, doc, _) = makeEngine()
        let old = ControlledGeneration(), replacement = ControlledGeneration()
        let oldDone = TestSignal(), replacementDone = TestSignal()
        var starts = 0
        var oldID: UUID?
        engine.generationManager.onTaskFinished = { id in
            if id == oldID { oldDone.send() } else { replacementDone.send() }
        }
        engine.generationManager.makeStream = { _, session, _ in
            starts += 1
            if starts == 1 { oldID = session.id }
            return starts == 1 ? old : replacement
        }
        engine.coordinator.requestPlayIntent()
        if seeking { engine.performSeek(toCharIndex: 17) }
        else { engine.generationManager.generate(document: doc, playbackEngine: engine) }
        await old.waitUntilRequested()
        engine.handleInterruption(.began, shouldResume: false)
        #expect((engine.pendingSeek != nil) == seeking)
        old.finish()
        await oldDone.wait()
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(engine.coordinator.contract?.lifecycle == .suspended)
        engine.handleInterruption(.ended, shouldResume: true)
        await replacement.waitUntilRequested()
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        if seeking { #expect(engine.pendingSeek?.characterOffset == 17) }
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.pause()
        replacement.finish()
        await replacementDone.wait()
    }

    @Test func resetRetiresOldGenerationBeforeNewPlay() async {
        let (engine, doc, _) = makeEngine()
        let old = ControlledGeneration(), replacement = ControlledGeneration()
        let oldDone = TestSignal(), replacementDone = TestSignal()
        var starts = 0
        var oldID: UUID?
        engine.generationManager.onTaskFinished = { id in
            if id == oldID { oldDone.send() } else { replacementDone.send() }
        }
        engine.generationManager.makeStream = { _, session, _ in
            starts += 1
            if starts == 1 { oldID = session.id }
            return starts == 1 ? old : replacement
        }
        engine.coordinator.requestPlayIntent()
        engine.generationManager.generate(document: doc, playbackEngine: engine)
        await old.waitUntilRequested()
        engine.rebuildAfterMediaReset()
        #expect(!engine.generationManager.isGeneratingAny)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        engine.play()
        await replacement.waitUntilRequested()
        old.fail()
        await oldDone.wait()
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(engine.generationManager.generatingDocumentIDs.contains(doc.id))
        #expect(engine.generationManager.lastError == nil)
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.pause()
        replacement.finish()
        await replacementDone.wait()
    }

    @Test(arguments: [false, true], [false, true])
    func seekDuringInterruptionDefersUntilEnd(playing: Bool, timeSeek: Bool) async {
        let (engine, _, _) = makeEngine()
        let stream = ControlledGeneration(), done = TestSignal()
        engine.generationManager.makeStream = { _, _, _ in stream }
        engine.generationManager.onTaskFinished = { _ in done.send() }
        if playing { engine.coordinator.requestPlayIntent() }
        engine.handleInterruption(.began, shouldResume: false)
        if timeSeek { engine.performSeek(to: 1) }
        else { engine.performSeek(toCharIndex: 17) }
        #expect(!engine.generationManager.isGeneratingAny)
        #expect(engine.pendingSeek?.phase == .debouncing)
        engine.handleInterruption(.ended, shouldResume: true)
        await stream.waitUntilRequested()
        #expect(engine.pendingSeek?.phase == .generating)
        #expect(engine.pendingSeek?.shouldPlay == playing)
        #expect(engine.coordinator.desiredPlayIntent == (playing ? .playing : .paused))
        if timeSeek { #expect(engine.currentTime == 1) }
        else { #expect(engine.pendingSeek?.characterOffset == 17) }
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.pause()
        engine.cancelPendingSeek()
        stream.finish()
        await done.wait()
    }

    @Test(arguments: [false, true])
    func preInterruptionPreparationCannotCompleteSuspension(failing: Bool) {
        let (engine, _, _) = makeEngine()
        var completion: ((Result<Void, Error>) -> Void)?
        engine.prepareAudioOverride = { completion = $0 }
        engine.coordinator.requestPlayIntent()
        engine.isPlaying = true
        engine.prepareReaderAudioSession(reason: "held-test")
        engine.handleInterruption(.began, shouldResume: false)
        engine.play()
        completion?(failing ? .failure(NSError(domain: "OldPreparation", code: 1)) : .success(()))
        #expect(engine.coordinator.contract?.lifecycle == .suspended)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(engine.audioPreparationID == nil)
        #expect(engine.generationManager.lastError == nil)
        engine.pause()
        engine.handleInterruption(.ended, shouldResume: true)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
    }

    @Test(arguments: [false, true])
    func interruptedAppleSeekRetainsIntentButUserPauseWins(paused: Bool) {
        let (engine, _, _) = makeEngine()
        engine.coordinator.requestPlayIntent()
        #expect(engine.coordinator.triggerFallback())
        engine.seek(toCharIndex: 17, playAfterSeek: true)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(engine.pendingSeek?.shouldPlay == true)
        engine.handleInterruption(.began, shouldResume: false)
        if paused { engine.pause() }
        engine.handleInterruption(.ended, shouldResume: true)
        #expect(engine.pendingSeek == nil)
        #expect(engine.coordinator.desiredPlayIntent == (paused ? .paused : .playing))
        engine.pause()
    }

    @Test(arguments: [false, true])
    func failedBackgroundItemCannotBlockFallback(allowed: Bool) {
        let (engine, _, speech) = makeEngine()
        engine.automaticFallbackOverride = { allowed }
        engine.coordinator.automaticFallbackAllowed = allowed
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/failed-background.caf"))
        engine.insertQueuedItem(item)
        engine.coordinator.requestPlayIntent()
        engine.handleLifecycle(.background)
        engine.handlePlaybackItemFailure(item, error: NSError(domain: "FailedItem", code: 2))
        let spoken = speech.spoken.count
        engine.handlePlaybackItemFailure(item, error: nil)
        #expect(engine.activeQueueItems.isEmpty)
        #expect(engine.isFallbackActive == allowed)
        #expect(engine.isWaitingForForeground == !allowed)
        #expect(speech.spoken.count == spoken)
        #expect(speech.spoken.isEmpty == !allowed)
        #expect(!engine.generationManager.isGeneratingAny)
        engine.pause()
    }

    @Test(arguments: ["pause", "reset", "seek", "document"], [false, true])
    func obsoletePreparationCannotMutateReplacement(action: String, failing: Bool) {
        let (engine, _, _) = makeEngine()
        var completions: [(Result<Void, Error>) -> Void] = []
        engine.prepareAudioOverride = { completions.append($0) }
        engine.coordinator.requestPlayIntent()
        engine.prepareReaderAudioSession(reason: "obsolete-test")
        let old = completions[0]
        switch action {
        case "pause": engine.pause()
        case "reset": engine.rebuildAfterMediaReset()
        case "seek": _ = engine.beginSeek(characterOffset: 17)
        default: engine.load(document: Document(title: "New", bodyText: "Replacement sentence."))
        }
        let document = engine.currentDocument?.id
        let preparation = engine.audioPreparationID
        let revision = engine.seekRevision
        let intent = engine.coordinator.desiredPlayIntent
        old(failing ? .failure(NSError(domain: "Obsolete", code: 1)) : .success(()))
        #expect(engine.currentDocument?.id == document)
        #expect(engine.audioPreparationID == preparation)
        #expect(engine.seekRevision == revision)
        #expect(engine.coordinator.desiredPlayIntent == intent)
        #expect(engine.generationManager.lastError == nil)
        engine.pause()
        engine.cancelPendingSeek()
    }

    @Test func failedForegroundItemRegeneratesFromItsSourcePosition() async {
        let (engine, _, _) = makeEngine()
        let stream = ControlledGeneration(), done = TestSignal()
        engine.generationManager.makeStream = { _, _, _ in stream }
        engine.generationManager.onTaskFinished = { _ in done.send() }
        engine.coordinator.syncCursor(toUTF16Offset: 17)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/failed-owned-item.caf"))
        engine.insertQueuedItem(item)
        engine.coordinator.requestPlayIntent()
        engine.handlePlaybackItemFailure(item, error: nil)
        await stream.waitUntilRequested()
        #expect(engine.pendingSeek?.characterOffset == 17)
        #expect(engine.activeQueueItems.isEmpty)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.pause()
        engine.cancelPendingSeek()
        stream.finish()
        await done.wait()
    }

    @Test func exhaustedFailureRecoveryProducesActionablePause() {
        let (engine, _, _) = makeEngine()
        _ = engine.recoveryBudget.allow(segment: 0, now: 0)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/failed-foreground.caf"))
        engine.insertQueuedItem(item)
        engine.coordinator.requestPlayIntent()
        engine.handlePlaybackItemFailure(item, error: nil)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(engine.generationManager.lastError != nil)
        #expect(engine.pendingSeek == nil)
    }

    @Test func failedPrefetchedItemIsHandledWhenItBecomesCurrent() throws {
        let (engine, _, _) = makeEngine()
        engine.automaticFallbackOverride = { false }
        let first = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/first-item.caf"))
        let second = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/second-item.caf"))
        engine.insertQueuedItem(first)
        engine.insertQueuedItem(second)
        engine.coordinator.requestPlayIntent()
        engine.handleLifecycle(.background)
        engine.handlePlaybackItemFailure(second, error: NSError(domain: "PrefetchedFailure", code: 1))
        #expect(engine.queuePlayer?.currentItem === first)
        #expect(engine.activeQueueItems.count == 2)
        engine.queuePlayer?.advanceToNextItem()
        engine.handlePlayerStatus(try #require(engine.queuePlayer))
        #expect(engine.activeQueueItems.isEmpty)
        #expect(engine.isWaitingForForeground)
        engine.pause()
    }

    @Test func earnedRecoverySurvivesTheFailureStopBoundary() async {
        let (engine, _, _) = makeEngine()
        let stream = ControlledGeneration(), done = TestSignal()
        engine.generationManager.makeStream = { _, _, _ in stream }
        engine.generationManager.onTaskFinished = { _ in done.send() }
        var now: TimeInterval = 0
        engine.listeningClock = { now }
        _ = engine.recoveryBudget.allow(segment: 0, now: 0)
        engine.coordinator.requestPlayIntent()
        engine.coordinator.syncCursor(toUTF16Offset: 17)
        engine.setActualPlayback(true)
        now = 31
        engine.setActualPlayback(true)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/recovery-earned.caf"))
        engine.insertQueuedItem(item)
        engine.handlePlaybackItemFailure(item, error: nil)
        await stream.waitUntilRequested()
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(engine.generationManager.lastError == nil)
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.pause()
        engine.cancelPendingSeek()
        stream.finish()
        await done.wait()
    }

    @Test func cancelledOldGenerationCannotReportIntoReplacement() async {
        let (engine, doc, _) = makeEngine()
        let old = ControlledGeneration(), new = ControlledGeneration()
        var starts = 0
        var oldID: UUID?
        let oldFinished = TestSignal()
        engine.generationManager.onTaskFinished = { if $0 == oldID { oldFinished.send() } }
        engine.generationManager.makeStream = { _, session, _ in
            #expect(session.voice == .kokoro(identifier: "af_heart"))
            starts += 1
            if starts == 1 { oldID = session.id }
            return starts == 1 ? old : new
        }
        engine.generationManager.generate(document: doc, playbackEngine: engine)
        await old.waitUntilRequested()
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        engine.generationManager.generate(document: doc, playbackEngine: engine)
        await new.waitUntilRequested()
        old.fail()
        await oldFinished.wait()
        #expect(engine.generationManager.lastError == nil)
        #expect(engine.generationManager.generatingDocumentIDs.contains(doc.id))
        new.finish()
    }

    @Test func punctuationOnlyGenerationCompletesWithoutOpeningAnAudioFile() async throws {
        let (engine, doc, _) = makeEngine(text: "…\"\n")
        let segment = DocumentSegmentID(documentID: doc.id, ordinal: 0,
            utf16Range: UTF16TextRange(location: 0, length: doc.bodyText.utf16.count))
        let done = TestSignal()
        engine.generationManager.makeStream = { _, _, _ in PunctuationGeneration(segment: segment) }
        engine.generationManager.onTaskFinished = { _ in done.send() }
        engine.generationManager.generate(document: doc, playbackEngine: engine)
        await done.wait()
        #expect(engine.coordinator.contract?.lifecycle == .completed)
        #expect(engine.generationManager.lastError == nil)
    }

    @Test func currentGenerationFailureIsScopedAndClearedOnNewDocument() async {
        let (engine, doc, _) = makeEngine()
        let stream = ControlledGeneration()
        engine.generationManager.makeStream = { _, _, _ in stream }
        engine.generationManager.generate(document: doc, playbackEngine: engine)
        await stream.waitUntilRequested()
        stream.fail()
        // Wait for the manager's explicit completion signal, not a timing sleep.
        for await ids in engine.generationManager.$generatingDocumentIDs.values {
            if ids.isEmpty { break }
        }
        #expect(engine.generationManager.issue?.documentID == doc.id)
        #expect(engine.generationManager.lastError?.contains("speech generation") == true)
        engine.load(document: Document(title: "Replacement", bodyText: "New text."))
        #expect(engine.generationManager.lastError == nil)
    }
}

@Suite struct PlaybackRecoveryTests {
    @Test func recoveryIsBoundedPerSegmentAndEpisode() {
        var budget = PlaybackRecoveryBudget()
        let first = budget.allow(segment: 1, now: 0)
        #expect(first)
        let repeated = budget.allow(segment: 1, now: 100)
        #expect(!repeated)
        let immediate = budget.allow(segment: 2, now: 5)
        #expect(!immediate)
        budget.verifiedPlayback(seconds: 30)
        let later = budget.allow(segment: 2, now: 31)
        #expect(later)
    }
    @Test func gpuGateSerializesAndPauseBlocksAdmission() async throws {
        let gate = EngineBackgroundState()
        let first = try await gate.acquire()
        #expect(gate.isExecuting)
        gate.isPaused = true
        gate.release(first)
        #expect(!gate.isExecuting)
        let cancelled = Task {
            let lease = try await gate.acquire()
            defer { gate.release(lease) }
            try Task.checkCancellation()
        }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Cancelled waiter was admitted") } catch is CancellationError {} catch { Issue.record("Unexpected error") }
        gate.isPaused = false
        let next = try await gate.acquire()
        gate.release(first) // obsolete release must not release next
        #expect(gate.isExecuting)
        gate.release(next)
        #expect(!gate.isExecuting)
    }
    @Test func nonSpeechClassificationKeepsPunctuationWithActualSentences() {
        #expect(!PlaybackSourceProgress.hasSpeech("… .\"\n"))
        #expect(PlaybackSourceProgress.hasSpeech("Was…\""))
        #expect(PlaybackSourceProgress.hasSpeech("42."))
    }
    @Test func errorDetailsExcludeChapterContent() {
        let underlying = NSError(domain: "FileValidation", code: 12,
            userInfo: [NSLocalizedDescriptionKey: "SECRET CHAPTER CONTENT"])
        let issue = PlaybackIssue(documentID: UUID(), runID: UUID(), segment: 2, stage: "audio validation",
            error: NSError(domain: "Audio", code: 3, userInfo: [NSUnderlyingErrorKey: underlying]))
        #expect(issue.codes == ["Audio:3", "FileValidation:12"])
        #expect(!issue.message.contains("SECRET"))
    }
}

@MainActor @Suite struct PlaybackProgressTests {
    @Test func generatedRunwayDoesNotDetermineLibraryProgress() {
        let doc = Document(title: "Fixture", bodyText: String(repeating: "word ", count: 1000), progress: 0.98, lastReadCharIndex: 500)
        #expect(doc.readingProgress == 0.1)
        #expect(doc.lastReadCharIndex == 500)
        doc.progress = doc.readingProgress
        doc.lastReadCharIndex = 250
        #expect(doc.readingProgress == 0.05)
        doc.lastReadCharIndex = doc.bodyText.utf16.count
        #expect(doc.readingProgress == 1)
    }
    @Test func progressHandlesEmptyBoundsAndFinalThreshold() {
        #expect(PlaybackSourceProgress.fraction(offset: -1, length: 10) == 0)
        #expect(PlaybackSourceProgress.fraction(offset: 99, length: 10) == 1)
        #expect(PlaybackSourceProgress.fraction(offset: 5, length: 0) == 0)
        #expect(!LibraryFilter.finished.matches(progress: 0.99))
        #expect(LibraryFilter.finished.matches(progress: 1))
    }
    @Test func listeningExcludesPausedTimeAndKeepsShortIntervals() {
        var meter = ListeningAccumulator()
        meter.activity(true, at: 10)
        meter.addWord()
        meter.activity(false, at: 11)
        meter.activity(true, at: 100)
        meter.addWord()
        meter.activity(false, at: 102)
        let value = meter.take(at: 200)
        #expect(value.seconds == 3)
        #expect(value.words == 2)
        #expect(ListeningMetrics.wpm(words: 2, seconds: 3) == 40)
        #expect(ListeningMetrics.wpm(words: 0, seconds: 0) == nil)
    }
    @Test func nullableMeasurementVersionPreservesLegacyRecords() throws {
        let container = try ModelContainer(for: ListeningSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let old = ListeningSession(documentId: UUID(), secondsListened: 60, wordsListened: 150, playbackSpeed: 1)
        let measured = ListeningSession(documentId: UUID(), secondsListened: 30, wordsListened: 100, playbackSpeed: 1, measurementVersion: 2)
        context.insert(old); context.insert(measured)
        try context.save()
        let saved = try context.fetch(FetchDescriptor<ListeningSession>())
        #expect(saved.count == 2)
        #expect(saved.filter { $0.measurementVersion == 2 }.count == 1)
        #expect(saved.first { $0.measurementVersion == nil }?.wordsListened == 150)
    }
    @Test func existingSQLiteListeningHistoryMigratesWithoutReset() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".scratch/playback-reliability/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("History.store")
        func writeLegacy() throws -> UUID {
            let old = try ModelContainer(for: BeforeMeasurement.ListeningSession.self,
                configurations: ModelConfiguration(url: url))
            let row = BeforeMeasurement.ListeningSession()
            old.mainContext.insert(row)
            try old.mainContext.save()
            return row.id
        }
        let id = try writeLegacy()
        let upgraded = try ModelContainer(for: ListeningSession.self, configurations: ModelConfiguration(url: url))
        let rows = try upgraded.mainContext.fetch(FetchDescriptor<ListeningSession>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.wordsListened == 150)
        #expect(rows.first?.measurementVersion == nil)
    }
    @Test func readerIdleTimerReleasesOnEveryBlockingCondition() {
        var values: [Bool] = []
        let timer = ReaderIdleTimer { values.append($0) }
        let base = ReaderAwakeContext(enabled: true, visible: true, active: true, intended: true, advancing: true, preparing: false, blocked: false)
        for blocked in [0, 1, 2, 3, 4] {
            timer.update(base)
            var changed = base
            switch blocked {
            case 0: changed.enabled = false
            case 1: changed.visible = false
            case 2: changed.active = false
            case 3: changed.intended = false
            default: changed.blocked = true
            }
            timer.update(changed)
            #expect(values.suffix(2) == [true, false])
        }
        timer.update(base); timer.release()
        #expect(values.last == false)
    }
}
