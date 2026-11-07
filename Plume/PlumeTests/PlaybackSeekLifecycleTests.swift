import XCTest
import SwiftData
@testable import Plume

final class PlaybackSeekLifecycleTests: XCTestCase {
    @MainActor func testHandoffGenerationCompletionPreservesPlayIntent() throws {
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let document = Document(title: "Handoff", bodyText: "An isolated passage for a generation cancellation handoff.")
        context.insert(document)
        try context.save()
        let engine = AudioPlaybackEngine.shared
        defer { engine.stopAndRelease(); withExtendedLifetime((container, context)) {} }
        let session = KokoroGenerationSessionFactory.make(documentID: document.id, defaults: .standard)
        engine.load(document: document, generationSession: session)
        _ = engine.coordinator.begin(document: document, snapshot: PlaybackSessionSnapshot(
            documentID: document.id,
            preferences: VoicePreferences(primary: .kokoro(identifier: "af_heart"), fallbackAppleVoiceIdentifier: nil)
        ))
        XCTAssertFalse(engine.coordinator.isAppleActive)
        XCTAssertTrue(engine.generationGate.isActive(sessionID: session.id))
        engine.coordinator.play()
        engine.finishGeneration(sessionID: session.id, termination: .retired)
        XCTAssertEqual(engine.coordinator.desiredPlayIntent, .playing)
        engine.beginGenerationSession(session)
        engine.finishGeneration(sessionID: session.id, termination: .cancelled)
        XCTAssertEqual(engine.coordinator.desiredPlayIntent, .paused)
    }
    @MainActor func testPendingFallbackCannotRestartReleasedChapter() async throws {
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let document = Document(title: "Released fallback", bodyText: "A pending fallback must not reopen a released chapter.")
        context.insert(document)
        try context.save()
        let engine = AudioPlaybackEngine.shared
        defer { engine.stopAndRelease(); withExtendedLifetime((container, context)) {} }
        engine.load(document: document)
        _ = engine.coordinator.begin(document: document, snapshot: PlaybackSessionSnapshot(
            documentID: document.id,
            preferences: VoicePreferences(primary: .kokoro(identifier: "af_heart"), fallbackAppleVoiceIdentifier: nil)
        ))
        engine.coordinator.play()
        engine.triggerFallbackToAppleSpeech(reason: "Isolated regression check")
        engine.stopAndRelease()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(engine.currentDocument)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isFallbackActive)
    }
    @MainActor func testPendingSeekIsDiscardedWhenChapterChanges() async throws {
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let first = Document(title: "First", bodyText: "A sufficiently long chapter passage for a pending seek.")
        let second = Document(title: "Second", bodyText: "A different chapter passage must retain its own position.")
        context.insert(first); context.insert(second)
        try context.save()
        let engine = AudioPlaybackEngine.shared
        defer { engine.stopAndRelease(); withExtendedLifetime((container, context)) {} }
        engine.load(document: first)
        engine.seek(toCharIndex: 30)
        engine.load(document: second)
        let marker = WordTimestamp(word: "different", startTime: 0, endTime: 1, rangeLocation: 2, rangeLength: 9)
        engine.currentWord = marker
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(engine.currentDocument?.id, second.id)
        XCTAssertEqual(engine.currentWord, marker)
        XCTAssertTrue(AudioGenerationManager.shared.generatingDocumentIDs.isEmpty)
    }

    @MainActor func testStoppingDiscardsPendingSeekBeforeSameChapterReload() async throws {
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let document = Document(title: "Reloaded", bodyText: "A sufficiently long chapter passage for a pending seek.")
        context.insert(document)
        try context.save()
        let engine = AudioPlaybackEngine.shared
        defer { engine.stopAndRelease(); withExtendedLifetime((container, context)) {} }
        engine.load(document: document)
        engine.seek(toCharIndex: 30)
        engine.stopAndRelease()
        engine.load(document: document)
        let marker = WordTimestamp(word: "chapter", startTime: 0, endTime: 1, rangeLocation: 20, rangeLength: 7)
        engine.currentWord = marker
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(engine.currentWord, marker)
        XCTAssertTrue(AudioGenerationManager.shared.generatingDocumentIDs.isEmpty)
    }
    @MainActor func testPermanentDeletionReleasesPlaybackAndWaitsForCanceledWriter() async throws {
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let document = Document(title: "Deleted current chapter", bodyText: "An isolated chapter used only by this test.")
        context.insert(document)
        try context.save()
        let documentID = document.id
        let engine = AudioPlaybackEngine.shared
        defer { engine.stopAndRelease(); withExtendedLifetime((container, context)) {} }
        engine.load(document: document)
        PlaybackQueueManager.shared.enqueue(documentID)
        let token = try AudioCacheStore.shared.beginWriting(documentID: documentID)
        let release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            AudioCacheStore.shared.finishWriting(token)
        }
        _ = await DocumentDeletion.permanentlyDelete([document], context: context)
        await release.value
        try context.save()
        XCTAssertNil(engine.currentDocument)
        XCTAssertNil(engine.coordinator.document)
        XCTAssertFalse(PlaybackQueueManager.shared.queue.contains(documentID))
        XCTAssertFalse(AudioCacheStore.shared.protectedWriterIDs.contains(documentID))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Document>()).isEmpty)
    }

}
