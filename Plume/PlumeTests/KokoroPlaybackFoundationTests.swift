import XCTest
@testable import Plume

@MainActor
final class KokoroPlaybackFoundationTests: XCTestCase {
    func testSegmentIDsAndUTF16RangesAreStableForDocumentSnapshot() throws {
        let documentID = UUID()
        let text = "Hello 👋🏽 world. Café is ready."

        let first = TextSegmenter.segment(documentID: documentID, text: text)
        let second = TextSegmenter.segment(documentID: documentID, text: text)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map(\.id), second.map(\.id))

        for (ordinal, chunk) in first.enumerated() {
            XCTAssertEqual(chunk.id.documentID, documentID)
            XCTAssertEqual(chunk.id.ordinal, ordinal)
            XCTAssertEqual(chunk.id.utf16Range, UTF16TextRange(chunk.nsRange))

            let stringRange = try XCTUnwrap(Range(chunk.id.utf16Range.nsRange, in: text))
            XCTAssertEqual(String(text[stringRange]), chunk.text)
        }
    }

    func testSameTextInDifferentDocumentsHasDifferentSegmentIDs() throws {
        let text = "One sentence."
        let first = try XCTUnwrap(
            TextSegmenter.segment(documentID: UUID(), text: text).first
        )
        let second = try XCTUnwrap(
            TextSegmenter.segment(documentID: UUID(), text: text).first
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id.utf16Range, second.id.utf16Range)
    }

    func testSegmentRangesHandleCombiningMarksEmojiNewlinesAndEmptyText() throws {
        let documentID = UUID()
        let text = "Cafe\u{301} is ready.\n\nA family 👨‍👩‍👧‍👦 is here."
        let chunks = TextSegmenter.segment(documentID: documentID, text: text)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(TextSegmenter.segment(documentID: documentID, text: "").isEmpty)

        for (ordinal, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.id.ordinal, ordinal)
            XCTAssertEqual(chunk.id.utf16Range.location, chunk.nsRange.location)
            XCTAssertEqual(chunk.id.utf16Range.length, chunk.nsRange.length)

            let sourceRange = try XCTUnwrap(Range(chunk.id.utf16Range.nsRange, in: text))
            XCTAssertEqual(String(text[sourceRange]), chunk.text)
        }
    }

    func testStartingLaterPreservesSourceOrdinalsAndRanges() {
        let documentID = UUID()
        let text = "First sentence. Second sentence. Third sentence."
        let allChunks = TextSegmenter.segment(documentID: documentID, text: text)
        let resumedChunks = Array(allChunks.dropFirst(1))

        XCTAssertEqual(resumedChunks.map(\.id.ordinal), [1, 2])
        XCTAssertEqual(resumedChunks.map(\.id), Array(allChunks[1...]).map(\.id))
    }

    func testGenerationGateRejectsReplacedInvalidatedAndMismatchedResults() {
        let documentID = UUID()
        let otherDocumentID = UUID()
        let segment = DocumentSegmentID(
            documentID: documentID,
            ordinal: 0,
            utf16Range: UTF16TextRange(location: 0, length: 5)
        )
        let firstSession = PlaybackGenerationSession(
            id: UUID(),
            documentID: documentID,
            voice: .kokoro(identifier: "af_heart")
        )
        let replacementSession = PlaybackGenerationSession(
            id: UUID(),
            documentID: documentID,
            voice: .kokoro(identifier: "af_bella")
        )
        let firstIdentity = GeneratedAudioChunkIdentity(
            session: firstSession,
            segmentID: segment
        )
        let replacementIdentity = GeneratedAudioChunkIdentity(
            session: replacementSession,
            segmentID: segment
        )
        let mismatchedSegmentIdentity = GeneratedAudioChunkIdentity(
            session: firstSession,
            segmentID: DocumentSegmentID(
                documentID: otherDocumentID,
                ordinal: 0,
                utf16Range: UTF16TextRange(location: 0, length: 5)
            )
        )

        var gate = PlaybackGenerationGate()
        gate.activate(firstSession)
        XCTAssertTrue(gate.isActive(sessionID: firstSession.id))
        XCTAssertTrue(gate.accepts(firstIdentity, currentDocumentID: documentID))
        XCTAssertFalse(gate.accepts(firstIdentity, currentDocumentID: otherDocumentID))
        XCTAssertFalse(gate.accepts(mismatchedSegmentIdentity, currentDocumentID: documentID))

        gate.activate(replacementSession)
        XCTAssertFalse(gate.accepts(firstIdentity, currentDocumentID: documentID))
        XCTAssertTrue(gate.accepts(replacementIdentity, currentDocumentID: documentID))

        gate.invalidate()
        XCTAssertFalse(gate.isActive(sessionID: replacementSession.id))
        XCTAssertFalse(gate.accepts(replacementIdentity, currentDocumentID: documentID))
        XCTAssertFalse(gate.matches(sessionID: replacementSession.id, documentID: documentID))
    }

    func testActiveSessionCanBeCleanedUpBeforeItsDocumentLoads() {
        let session = PlaybackGenerationSession(
            documentID: UUID(),
            voice: .kokoro(identifier: "af_heart")
        )
        var gate = PlaybackGenerationGate()

        gate.activate(session)

        XCTAssertTrue(gate.isActive(sessionID: session.id))
        XCTAssertFalse(gate.matches(sessionID: session.id, documentID: UUID()))
    }

    func testRunStateRejectsEveryStaleLifecycleEventAfterRestart() {
        let firstSessionID = UUID()
        let replacementSessionID = UUID()
        var state = PlaybackGenerationRunState()

        state.activate(sessionID: firstSessionID)
        XCTAssertTrue(state.accepts(.work(sessionID: firstSessionID)))
        XCTAssertTrue(state.accepts(.enqueue(sessionID: firstSessionID)))
        XCTAssertTrue(state.accepts(.failure(sessionID: firstSessionID)))
        XCTAssertTrue(state.accepts(.completion(sessionID: firstSessionID)))
        XCTAssertTrue(state.accepts(.cleanup(sessionID: firstSessionID)))

        state.activate(sessionID: replacementSessionID)
        XCTAssertFalse(state.accepts(.work(sessionID: firstSessionID)))
        XCTAssertFalse(state.accepts(.enqueue(sessionID: firstSessionID)))
        XCTAssertFalse(state.accepts(.failure(sessionID: firstSessionID)))
        XCTAssertFalse(state.accepts(.completion(sessionID: firstSessionID)))
        XCTAssertFalse(state.accepts(.cleanup(sessionID: firstSessionID)))
        XCTAssertFalse(state.finish(sessionID: firstSessionID))
        XCTAssertEqual(state.activeSessionID, replacementSessionID)

        XCTAssertTrue(state.finish(sessionID: replacementSessionID))
        XCTAssertNil(state.activeSessionID)
    }

    func testRunStateCancellationInvalidatesCurrentSessionBeforeCleanup() {
        let sessionID = UUID()
        var state = PlaybackGenerationRunState()
        state.activate(sessionID: sessionID)

        XCTAssertEqual(state.invalidateCurrent(), sessionID)
        XCTAssertNil(state.activeSessionID)
        XCTAssertFalse(state.accepts(.cleanup(sessionID: sessionID)))
        XCTAssertFalse(state.accepts(.failure(sessionID: sessionID)))
    }

    func testEngineGateRejectsSameDocumentRestartAndDocumentSwitchResults() {
        let firstDocumentID = UUID()
        let secondDocumentID = UUID()
        let firstSession = PlaybackGenerationSession(
            documentID: firstDocumentID,
            voice: .kokoro(identifier: "af_heart")
        )
        let sameDocumentRestart = PlaybackGenerationSession(
            documentID: firstDocumentID,
            voice: .kokoro(identifier: "af_heart")
        )
        let secondDocumentSession = PlaybackGenerationSession(
            documentID: secondDocumentID,
            voice: .kokoro(identifier: "af_heart")
        )
        let firstIdentity = GeneratedAudioChunkIdentity(
            session: firstSession,
            segmentID: DocumentSegmentID(
                documentID: firstDocumentID,
                ordinal: 0,
                utf16Range: UTF16TextRange(location: 0, length: 5)
            )
        )

        var gate = PlaybackGenerationGate()
        gate.activate(sameDocumentRestart)
        XCTAssertFalse(gate.accepts(firstIdentity, currentDocumentID: firstDocumentID))

        gate.activate(secondDocumentSession)
        XCTAssertFalse(gate.accepts(firstIdentity, currentDocumentID: secondDocumentID))
    }

    func testKokoroVoiceIsSnapshottedWhenSessionStarts() throws {
        try withDefaults { defaults in
            defaults.set("af_bella", forKey: "kokoroVoice")
            let session = KokoroGenerationSessionFactory.make(
                documentID: UUID(),
                defaults: defaults
            )

            defaults.set("bm_george", forKey: "kokoroVoice")

            XCTAssertEqual(session.voice, .kokoro(identifier: "af_bella"))
        }
    }

    func testGeneratedChunkIdentityPropagatesIntoPlayedChunk() {
        let documentID = UUID()
        let session = PlaybackGenerationSession(
            documentID: documentID,
            voice: .kokoro(identifier: "af_heart")
        )
        let identity = GeneratedAudioChunkIdentity(
            session: session,
            segmentID: DocumentSegmentID(
                documentID: documentID,
                ordinal: 2,
                utf16Range: UTF16TextRange(location: 12, length: 8)
            )
        )
        let chunk = AudioChunk(
            identity: identity,
            fileURL: URL(fileURLWithPath: "/tmp/chunk_2_af_heart.m4a"),
            duration: 1.5,
            timestamps: []
        )

        let played = PlayedChunk(chunk: chunk, globalStartTime: 4)

        XCTAssertEqual(played.identity, .generated(identity))
        XCTAssertEqual(played.globalStartTime, 4)
        XCTAssertEqual(played.duration, 1.5)
    }

    func testPlaybackRoutingCoordinatorPauseStopsAppleProducerUnconditionally() {
        let producer = AppleSpeechProducer()
        let coordinator = PlaybackRoutingCoordinator(appleProducer: producer)
        let document = Document(title: "Title", bodyText: "First sentence. Second sentence.")
        let preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: nil
        )
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        _ = coordinator.begin(document: document, snapshot: snapshot)

        // When isAppleActive is false:
        XCTAssertFalse(coordinator.isAppleActive)
        let prevGeneration = producer.generationID
        coordinator.pause()
        XCTAssertFalse(coordinator.isPlaying)
        // Verify appleProducer.stop() was called unconditionally (which increments generationID)
        XCTAssertGreaterThan(producer.generationID, prevGeneration)
    }

    func testPlaybackRoutingCoordinatorExecuteHandbackDoesNotTriggerOnActualPlayingChanged() {
        let coordinator = PlaybackRoutingCoordinator()
        let document = Document(title: "Title", bodyText: "First sentence. Second sentence.")
        let preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "com.apple.speech.voice.Alex"
        )
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        _ = coordinator.begin(document: document, snapshot: snapshot)

        // Trigger fallback so isFallbackActive is true
        _ = coordinator.triggerFallback(reason: "test")
        XCTAssertTrue(coordinator.isFallbackActive)

        // Stage a chunk for handback
        let session = PlaybackGenerationSession(documentID: document.id, voice: .kokoro(identifier: "af_heart"))
        let identity = GeneratedAudioChunkIdentity(
            session: session,
            segmentID: DocumentSegmentID(documentID: document.id, ordinal: 0, utf16Range: UTF16TextRange(location: 0, length: 15))
        )
        let chunk = AudioChunk(identity: identity, fileURL: URL(fileURLWithPath: "/tmp/test.m4a"), duration: 1.0, timestamps: [])
        coordinator.stageHandbackChunk(chunk, session: session)

        var onActualPlayingChangedCalled = false
        coordinator.onActualPlayingChanged = { _ in
            onActualPlayingChangedCalled = true
        }

        let executed = coordinator.executeHandback()
        XCTAssertTrue(executed)
        XCTAssertFalse(onActualPlayingChangedCalled, "executeHandback must not broadcast onActualPlayingChanged")
    }

    func testStageHandbackChunkAllowsUpcomingSentenceKPlusOneWhileSpeakingSentenceK() {
        let coordinator = PlaybackRoutingCoordinator()
        let document = Document(title: "Title", bodyText: "Sentence zero. Sentence one. Sentence two.")
        let preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "com.apple.speech.voice.Alex"
        )
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        _ = coordinator.begin(document: document, snapshot: snapshot)

        _ = coordinator.triggerFallback(reason: "test")
        XCTAssertTrue(coordinator.isFallbackActive)

        let session = PlaybackGenerationSession(documentID: document.id, voice: .kokoro(identifier: "af_heart"))
        
        // Simulate Apple Speech speaking Sentence 1 (K = 1)
        coordinator.currentlySpeakingSegmentOrdinal = 1
        
        // Chunk for Sentence 1 (currently speaking) must be discarded as stale
        let chunkCurrent = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 1, utf16Range: UTF16TextRange(location: 16, length: 13))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk1.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunkCurrent, session: session)
        XCTAssertFalse(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 1 }))

        // Chunk for Sentence 0 (already completed) must be discarded as stale
        let chunkPast = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 0, utf16Range: UTF16TextRange(location: 0, length: 14))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk0.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunkPast, session: session)
        XCTAssertFalse(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 0 }))

        // Chunk for Sentence 2 (K+1 = 2) must NOT be discarded
        let chunkNext = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 2, utf16Range: UTF16TextRange(location: 30, length: 13))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk2.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunkNext, session: session)
        XCTAssertTrue(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 2 }), "Sentence K+1 must be staged while Apple Speech is speaking Sentence K")
    }

    func testStageHandbackChunkAllowsUpcomingSentenceKPlusTwoAndRejectsNegativeOrdinal() {
        let coordinator = PlaybackRoutingCoordinator()
        let document = Document(title: "Title", bodyText: "Sentence zero. Sentence one. Sentence two. Sentence three.")
        let preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "com.apple.speech.voice.Alex"
        )
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        _ = coordinator.begin(document: document, snapshot: snapshot)

        _ = coordinator.triggerFallback(reason: "test")
        XCTAssertTrue(coordinator.isFallbackActive)

        let session = PlaybackGenerationSession(documentID: document.id, voice: .kokoro(identifier: "af_heart"))
        coordinator.currentlySpeakingSegmentOrdinal = 1 // Speaking sentence 1 (K = 1)

        // Chunk with negative ordinal must be rejected
        let chunkNegative = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: -1, utf16Range: UTF16TextRange(location: 0, length: 5))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunkNeg.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunkNegative, session: session)
        XCTAssertFalse(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == -1 }))

        // Chunk for Sentence 3 (K+2 = 3) must be allowed
        let chunkNextNext = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 3, utf16Range: UTF16TextRange(location: 45, length: 14))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk3.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunkNextNext, session: session)
        XCTAssertTrue(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 3 }), "Sentence K+2 must be staged while Apple Speech is speaking Sentence K")
    }

    func testStageHandbackChunkBetweenSentencesAllowsUpcomingSentence() {
        let coordinator = PlaybackRoutingCoordinator()
        let document = Document(title: "Title", bodyText: "Sentence zero. Sentence one. Sentence two.")
        let preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "com.apple.speech.voice.Alex"
        )
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        _ = coordinator.begin(document: document, snapshot: snapshot)

        _ = coordinator.triggerFallback(reason: "test")
        XCTAssertTrue(coordinator.isFallbackActive)

        let session = PlaybackGenerationSession(documentID: document.id, voice: .kokoro(identifier: "af_heart"))
        
        // Between sentences: currentlySpeakingSegmentOrdinal is nil, committed ordinal is 0
        coordinator.currentlySpeakingSegmentOrdinal = nil
        let cursor0 = PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: 14)!
        coordinator.commitSentenceBoundary(at: cursor0)

        // Chunk 0 (already committed with offset > 0) must be discarded
        let chunk0 = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 0, utf16Range: UTF16TextRange(location: 0, length: 14))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk0.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunk0, session: session)
        XCTAssertFalse(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 0 }))

        // Chunk 1 (upcoming) must be staged
        let chunk1 = AudioChunk(
            identity: GeneratedAudioChunkIdentity(
                session: session,
                segmentID: DocumentSegmentID(documentID: document.id, ordinal: 1, utf16Range: UTF16TextRange(location: 16, length: 13))
            ),
            fileURL: URL(fileURLWithPath: "/tmp/chunk1.m4a"),
            duration: 1.0,
            timestamps: []
        )
        coordinator.stageHandbackChunk(chunk1, session: session)
        XCTAssertTrue(coordinator.stagedHandbackChunks.contains(where: { $0.identity.segmentID.ordinal == 1 }))
    }

    func testAudioGenerationManagerSpeculativePreparationRestartsWhenAlreadyGenerating() {
        let manager = AudioGenerationManager.shared
        let engine = AudioPlaybackEngine.shared
        let document = Document(title: "Title", bodyText: "Sentence zero. Sentence one. Sentence two.")
        engine.load(document: document)
        _ = engine.coordinator.triggerFallback(reason: "test")

        // First start
        manager.startSpeculativePreparation(document: document, playbackEngine: engine, startChunkIndex: 0)
        XCTAssertTrue(manager.isSpeculativeGenerating)

        // Second start with a different chunk index while already generating:
        // Must cancel previous preparation and restart
        manager.startSpeculativePreparation(document: document, playbackEngine: engine, startChunkIndex: 1)
        XCTAssertTrue(manager.isSpeculativeGenerating)
        manager.cancelSpeculativePreparation()
        XCTAssertFalse(manager.isSpeculativeGenerating)
    }

    func testAudioPlaybackEnginePauseUnconditionallyPausesBoth() {
        let engine = AudioPlaybackEngine.shared
        let document = Document(title: "Title", bodyText: "Sample test sentence.")
        engine.load(document: document)
        
        // Trigger fallback so coordinator.isAppleActive becomes true
        _ = engine.coordinator.triggerFallback(reason: "Test pause asymmetry")
        XCTAssertTrue(engine.coordinator.isAppleActive)
        
        // In the prior buggy implementation, isAppleActive would cause pause() to return early
        // without pausing queuePlayer. Now both must be paused unconditionally.
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.coordinator.desiredPlayIntent, .paused)
    }

    func testAudioPlaybackEngineDoesNotToggleIsPlayingViaCoordinatorCallback() {
        let engine = AudioPlaybackEngine.shared
        let document = Document(title: "Title", bodyText: "Sample test sentence.")
        engine.load(document: document)
        
        engine.isPlaying = true
        // If someone triggers onActualPlayingChanged on the coordinator, engine.isPlaying must remain unaffected
        engine.coordinator.onActualPlayingChanged?(false)
        XCTAssertTrue(engine.isPlaying, "Engine isPlaying must not be clobbered by coordinator onActualPlayingChanged")
        engine.pause()
    }

    func testAudioPlaybackEngineFallbackPreservesPlayingIntentWhenQueuePaused() {
        let engine = AudioPlaybackEngine.shared
        let document = Document(title: "Title", bodyText: "Sample test sentence for fallback.")
        engine.load(document: document)
        
        // Simulate active play intent
        _ = engine.coordinator.play()
        engine.isPlaying = true
        
        // Trigger fallback
        engine.triggerFallbackToAppleSpeech(reason: "Buffer underrun simulation")
        
        // Engine must remain playing in fallback
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "KokoroPlaybackFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
