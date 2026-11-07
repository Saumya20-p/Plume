import AVFoundation
import SwiftData
import Testing
@testable import Plume

@MainActor
@Suite(.serialized)
struct WordTapSeekTests {
    @MainActor private final class CompletionGate {
        let events: AsyncStream<CMTime>
        private let eventsContinuation: AsyncStream<CMTime>.Continuation
        private var completions: [CheckedContinuation<Bool, Never>] = []

        init() {
            (events, eventsContinuation) = AsyncStream.makeStream(of: CMTime.self)
        }

        func seek(_ item: AVPlayerItem, to time: CMTime) async -> Bool {
            await withCheckedContinuation { continuation in
                completions.append(continuation)
                eventsContinuation.yield(time)
            }
        }

        func finish(_ index: Int, success: Bool = true) { completions[index].resume(returning: success) }
    }

    @MainActor private final class Fixture {
        let engine = AudioPlaybackEngine(observeSystem: false, manager: AudioGenerationManager())
        let document: Document
        let container: ModelContainer
        let file: URL
        let originalOperation: @MainActor (AVPlayerItem, CMTime) async -> Bool
        let gate = CompletionGate()

        init(buffered: Bool = true) throws {
            engine.hasPrewarmedSpeech = true
            engine.audioReadyOverride = { true }
            engine.prepareAudioOverride = { $0(.success(())) }
            engine.generationManager.makeStream = { _, _, _ in throw CancellationError() }
            container = try ModelContainer(for: Document.self, Folder.self, ListeningSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            document = Document(title: "Seek regression", bodyText: "First word. Second paragraph. Third paragraph.")
            container.mainContext.insert(document)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".scratch/playback-reliability/tests", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("seek-\(UUID()).caf")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            buffer.floatChannelData?[0].update(repeating: 0, count: 16000)
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
            originalOperation = engine.seekItemOperation
            engine.stopAndRelease()
            engine.load(document: document)
            _ = engine.coordinator.begin(document: document, snapshot: PlaybackSessionSnapshot(
                documentID: document.id,
                preferences: VoicePreferences(primary: .kokoro(identifier: "af_heart"), fallbackAppleVoiceIdentifier: nil)
            ))
            engine.seekItemOperation = { [gate] item, time in await gate.seek(item, to: time) }
            if buffered {
                engine.chunks = [PlayedChunk(legacyDocumentID: document.id, url: file, duration: 2,
                                            globalStartTime: 0, timestamps: timestamps)]
                engine.duration = 2
            }
        }

        var timestamps: [WordTimestamp] {
            [WordTimestamp(word: "First", startTime: 0, endTime: 0.2, rangeLocation: 0, rangeLength: 5),
             WordTimestamp(word: "word", startTime: 0.3, endTime: 0.6, rangeLocation: 6, rangeLength: 4),
             WordTimestamp(word: "Second", startTime: 0.8, endTime: 1.1, rangeLocation: 12, rangeLength: 6)]
        }

        func close() {
            engine.stopAndRelease()
            engine.seekItemOperation = originalOperation
            try? FileManager.default.removeItem(at: file)
        }
    }

    @Test func transientQueuePauseDoesNotLoseSeekIntentAndCompletionGatesPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        _ = engine.coordinator.play()
        engine.isPlaying = true
        var events = fixture.gate.events.makeAsyncIterator()
        engine.performSeek(toCharIndex: 6)
        let time = try #require(await events.next())
        #expect(time.seconds == 0.3)
        let player = try #require(engine.queuePlayer)
        engine.handlePlayerStatus(player)
        #expect(engine.isPlaying)
        #expect(player.rate == 0)
        #expect(engine.pendingSeek != nil)
        let task = engine.currentSeekTask
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
        #expect(engine.currentTime == 0.3)
    }

    @Test func latestTapWinsWhenAnOlderSeekCompletesLate() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        engine.performSeek(toCharIndex: 6)
        _ = try #require(await events.next())
        let oldTask = engine.currentSeekTask
        engine.performSeek(toCharIndex: 12)
        _ = try #require(await events.next())
        let latestRevision = engine.seekRevision
        let latestTask = engine.currentSeekTask
        fixture.gate.finish(0)
        await oldTask?.value
        #expect(engine.pendingSeek?.revision == latestRevision)
        #expect(engine.currentTime == 0.8)
        fixture.gate.finish(1)
        await latestTask?.value
        #expect(engine.pendingSeek == nil)
        #expect(engine.currentTime == 0.8)
    }

    @Test func rapidDebouncedWordTapsDoNotStartOldAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        engine.seek(toCharIndex: 6, playAfterSeek: true)
        engine.seek(toCharIndex: 12, playAfterSeek: true)
        #expect(engine.queuePlayer?.rate == 0)
        let time = try #require(await events.next())
        #expect(time.seconds == 0.8)
        let task = engine.currentSeekTask
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
    }

    @Test func realAVFoundationSeekCompletesAtTappedWord() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        engine.seekItemOperation = fixture.originalOperation
        engine.performSeek(toCharIndex: 6)
        let task = try #require(engine.currentSeekTask)
        await task.value
        #expect(engine.pendingSeek == nil)
        let item = try #require(engine.queuePlayer?.currentItem)
        #expect(item.status == .readyToPlay)
        #expect(abs(item.currentTime().seconds - 0.3) < 0.01)
        #expect(engine.queuePlayer?.rate == 0)
    }

    @Test func explicitPauseOverridesPlayAfterSeek() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        let request = try #require(engine.beginSeek(playAfterSeek: true, characterOffset: 6))
        engine.performSeek(toCharIndex: 6, request: request)
        _ = try #require(await events.next())
        let task = engine.currentSeekTask
        engine.pause()
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(!engine.isPlaying)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(engine.queuePlayer?.rate == 0)
    }

    @Test(arguments: [false, true])
    func oldCompletionCannotRestartAfterReleaseOrChapterChange(changeChapter: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        let request = try #require(engine.beginSeek(playAfterSeek: true))
        engine.performSeek(to: 0.3, request: request)
        _ = try #require(await events.next())
        let task = engine.currentSeekTask
        engine.stopAndRelease()
        if changeChapter {
            let next = Document(title: "Next", bodyText: "Another chapter.")
            fixture.container.mainContext.insert(next)
            engine.load(document: next)
            engine.currentTime = 0.125
        }
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == (changeChapter ? 0.125 : 0))
    }

    @Test func regenerationAtSegmentZeroPreservesSessionAndPositionsBeforePlaying() async throws {
        let fixture = try Fixture(buffered: false)
        defer { fixture.close() }
        let engine = fixture.engine
        let sessionID = engine.coordinator.contract?.sessionID
        let request = try #require(engine.beginSeek(playAfterSeek: true, characterOffset: 6))
        engine.performSeek(toCharIndex: 6, request: request)
        #expect(engine.coordinator.contract?.sessionID == sessionID)
        #expect(engine.pendingSeek?.revision == request.revision)
        #expect(engine.pendingSeek?.phase == .generating)
        let generation = try #require(engine.generationGate.activeSession)
        let segment = try #require(TextSegmenter.segment(documentID: fixture.document.id, text: fixture.document.bodyText).first)
        let chunk = AudioChunk(identity: GeneratedAudioChunkIdentity(session: generation, segmentID: segment.id),
                               fileURL: fixture.file, duration: 2, timestamps: fixture.timestamps)
        #expect(engine.enqueue(chunk: chunk))
        // Cancel real generation before it can run; the supplied chunk exercises the same enqueue boundary.
        engine.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        #expect(engine.pendingSeek?.phase == .positioning)
        #expect(engine.queuePlayer?.rate == 0)
        var events = fixture.gate.events.makeAsyncIterator()
        let time = try #require(await events.next())
        #expect(time.seconds == 0.3)
        let task = engine.currentSeekTask
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(engine.coordinator.desiredPlayIntent == .playing)
    }

    @Test func retiredItemEndCannotAdvanceOrTriggerFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        engine.performSeek(to: 0.3)
        _ = try #require(await events.next())
        let retiredItem = try #require(engine.queuePlayer?.currentItem)
        let oldTask = engine.currentSeekTask
        engine.performSeek(to: 0.8)
        _ = try #require(await events.next())
        let task = engine.currentSeekTask
        fixture.gate.finish(0)
        await oldTask?.value
        fixture.gate.finish(1)
        await task?.value
        let cursor = engine.coordinator.contract?.committedCursor
        engine.handlePlaybackItemEnded(retiredItem)
        #expect(engine.coordinator.contract?.committedCursor == cursor)
        #expect(!engine.coordinator.isAppleActive)
        #expect(engine.currentTime == 0.8)
    }

    @Test func completedChapterCanSeekBackWhileRemainingPaused() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        #expect(engine.coordinator.completeAtEOF())
        var events = fixture.gate.events.makeAsyncIterator()
        engine.performSeek(to: 0.3)
        _ = try #require(await events.next())
        let task = engine.currentSeekTask
        fixture.gate.finish(0)
        await task?.value
        #expect(engine.coordinator.contract?.lifecycle == .active)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
        #expect(fixture.document.lastReadCharIndex == 6)
        #expect(fixture.document.readingProgress < 1)
    }

    @Test func oldGenerationCompletionCannotCancelANewerDebouncedTap() throws {
        let fixture = try Fixture(buffered: false)
        defer { fixture.close() }
        let engine = fixture.engine
        let session = KokoroGenerationSessionFactory.make(documentID: fixture.document.id, defaults: .standard)
        engine.beginGenerationSession(session)
        let request = try #require(engine.beginSeek(playAfterSeek: true, characterOffset: 6))
        engine.finishGeneration(sessionID: session.id, termination: .retired)
        #expect(engine.isCurrentSeek(request))
        #expect(engine.pendingSeek?.shouldPlay == true)
        #expect(engine.isPlaying)
    }

    @Test(arguments: [false, true])
    func bufferedSeekCountsOnlyTraversedWordsIncludingEndFlush(partialWord: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var now: TimeInterval = 0
        engine.listeningClock = { now }
        var events = fixture.gate.events.makeAsyncIterator()
        if partialWord { engine.performSeek(to: 0.4) }
        else { engine.performSeek(toCharIndex: 6) }
        _ = try #require(await events.next())
        let seek = engine.currentSeekTask
        fixture.gate.finish(0)
        await seek?.value
        let item = try #require(engine.queuePlayer?.currentItem)
        let chunk = try #require(engine.chunks.first)
        engine.coordinator.requestPlayIntent()
        engine.setActualPlayback(true)
        engine.observeDeliveredKokoroWords(in: chunk, item: item, time: 0.6)
        #expect(engine.listeningAccumulator.words == (partialWord ? 0 : 1))
        now = 1
        engine.setActualPlayback(false)
        engine.setActualPlayback(true) // Ordinary pause/resume retains the item cursor.
        now = 2
        engine.generationEOF = true
        engine.handlePlaybackItemEnded(item)
        let rows = try fixture.container.mainContext.fetch(FetchDescriptor<ListeningSession>())
        let expected = partialWord ? 1 : 2
        #expect(rows.reduce(0) { $0 + $1.wordsListened } == expected)
        #expect(ListeningMetrics.wpm(words: expected, seconds: rows.reduce(0) { $0 + $1.secondsListened }) == Double(expected) * 30)

        // A backward seek replays words; the discarded item's late end cannot count again.
        engine.performSeek(toCharIndex: 0)
        _ = try #require(await events.next())
        let replaySeek = engine.currentSeekTask
        fixture.gate.finish(1)
        await replaySeek?.value
        let replayItem = try #require(engine.queuePlayer?.currentItem)
        engine.coordinator.requestPlayIntent()
        engine.setActualPlayback(true)
        engine.observeDeliveredKokoroWords(in: chunk, item: replayItem, time: 0.6)
        engine.handlePlaybackItemEnded(item)
        #expect(engine.listeningAccumulator.words == 2)
        now = 3
        engine.setActualPlayback(false)
        let replayRows = try fixture.container.mainContext.fetch(FetchDescriptor<ListeningSession>())
        #expect(replayRows.reduce(0) { $0 + $1.wordsListened } == expected + 2)
    }

    @Test func failedSeekDoesNotResumeOrLeavePendingPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = fixture.engine
        var events = fixture.gate.events.makeAsyncIterator()
        engine.performSeek(to: 0.3)
        _ = try #require(await events.next())
        let task = engine.currentSeekTask
        fixture.gate.finish(0, success: false)
        await task?.value
        #expect(engine.pendingSeek == nil)
        #expect(!engine.isPlaying)
        #expect(engine.coordinator.desiredPlayIntent == .paused)
    }
}
