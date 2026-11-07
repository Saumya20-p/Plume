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

    // Routing/lifecycle regressions now live in PlaybackReliabilityTests with
    // isolated producers and injected generation. The previous singleton tests
    // asserted eager handback queue suppression and foreground GPU reopening,
    // which are precisely the unsafe policies this change replaces.

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "KokoroPlaybackFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
