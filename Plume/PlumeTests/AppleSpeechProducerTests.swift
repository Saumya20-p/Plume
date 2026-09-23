import AVFoundation
import XCTest
@testable import Plume

@MainActor
private final class MockSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking: Bool = false
    var isPaused: Bool = false
    var usesApplicationAudioSession: Bool = false

    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopSpeakingCallCount: Int = 0
    private(set) var pauseSpeakingCallCount: Int = 0
    private(set) var continueSpeakingCallCount: Int = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
        isSpeaking = true
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseSpeakingCallCount += 1
        isPaused = true
        isSpeaking = false
        return true
    }

    func continueSpeaking() -> Bool {
        continueSpeakingCallCount += 1
        isPaused = false
        isSpeaking = true
        return true
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopSpeakingCallCount += 1
        isSpeaking = false
        isPaused = false
        return true
    }

    func simulateDidStart(utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)
    }

    func simulateWillSpeak(range: NSRange, utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: range, utterance: utterance)
    }

    func simulateDidFinish(utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
    }

    func simulateDidCancel(utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }
}

@MainActor
private final class TestProducerDelegate: AudioProducerDelegate {
    var startedCallbacks: [PlaybackCallbackIdentity] = []
    var spokenRanges: [(PlaybackCallbackIdentity, UTF16TextRange)] = []
    var finishedCallbacks: [PlaybackCallbackIdentity] = []
    var cancelledCallbacks: [PlaybackCallbackIdentity] = []

    func producerDidStart(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {
        startedCallbacks.append(callback)
    }

    func producerWillSpeak(
        _ producer: any AudioProducerProtocol,
        callback: PlaybackCallbackIdentity,
        globalRange: UTF16TextRange
    ) {
        spokenRanges.append((callback, globalRange))
    }

    func producerDidFinish(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {
        finishedCallbacks.append(callback)
    }

    func producerDidCancel(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {
        cancelledCallbacks.append(callback)
    }
}

@MainActor
final class AppleSpeechProducerTests: XCTestCase {

    private func makeCallback(
        sessionID: UUID = UUID(),
        generation: UInt64 = 0,
        utteranceID: UUID = UUID(),
        offset: Int = 0
    ) -> PlaybackCallbackIdentity {
        PlaybackCallbackIdentity(
            sessionID: sessionID,
            callbackGeneration: generation,
            utteranceID: utteranceID,
            producer: .apple,
            sourceBoundary: PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: offset)!
        )
    }

    // MARK: - UTF-16 Character Range Translation Tests

    func testMapToGlobalRange_StandardRange() {
        let text = "Hello world. This is Plume."
        let sourceRange = UTF16TextRange(location: 100, length: text.utf16.count)

        // "world" in local text is at location 6, length 5
        let localRange = NSRange(location: 6, length: 5)
        let mapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: localRange,
            utteranceText: text,
            sourceRange: sourceRange
        )

        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped?.location, 106)
        XCTAssertEqual(mapped?.length, 5)
    }

    func testMapToGlobalRange_Boundaries() {
        let text = "Quick brown fox"
        let sourceRange = UTF16TextRange(location: 50, length: text.utf16.count)

        // Start boundary: "Quick"
        let startMapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: NSRange(location: 0, length: 5),
            utteranceText: text,
            sourceRange: sourceRange
        )
        XCTAssertEqual(startMapped, UTF16TextRange(location: 50, length: 5))

        // End boundary: "fox"
        let endMapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: NSRange(location: 12, length: 3),
            utteranceText: text,
            sourceRange: sourceRange
        )
        XCTAssertEqual(endMapped, UTF16TextRange(location: 62, length: 3))

        // Entire string
        let fullMapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: NSRange(location: 0, length: text.utf16.count),
            utteranceText: text,
            sourceRange: sourceRange
        )
        XCTAssertEqual(fullMapped, UTF16TextRange(location: 50, length: text.utf16.count))
    }

    func testMapToGlobalRange_MultiByteAndEmoji() {
        // "A 📚 feather" -> "📚" is 2 UTF-16 code units (surrogate pair)
        let text = "A 📚 feather"
        let sourceRange = UTF16TextRange(location: 200, length: text.utf16.count)

        // Book emoji is at UTF-16 index 2 with length 2
        let emojiMapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: NSRange(location: 2, length: 2),
            utteranceText: text,
            sourceRange: sourceRange
        )
        XCTAssertEqual(emojiMapped, UTF16TextRange(location: 202, length: 2))

        // "feather" after emoji starts at index 5, length 7
        let wordMapped = AppleSpeechProducer.mapToGlobalRange(
            localRange: NSRange(location: 5, length: 7),
            utteranceText: text,
            sourceRange: sourceRange
        )
        XCTAssertEqual(wordMapped, UTF16TextRange(location: 205, length: 7))
    }

    func testMapToGlobalRange_RejectsInvalidAndOutOfBounds() {
        let text = "Sample sentence"
        let sourceRange = UTF16TextRange(location: 10, length: text.utf16.count)

        // Negative location
        XCTAssertNil(
            AppleSpeechProducer.mapToGlobalRange(
                localRange: NSRange(location: -1, length: 5),
                utteranceText: text,
                sourceRange: sourceRange
            )
        )

        // Negative length
        XCTAssertNil(
            AppleSpeechProducer.mapToGlobalRange(
                localRange: NSRange(location: 0, length: -1),
                utteranceText: text,
                sourceRange: sourceRange
            )
        )

        // Exceeds utterance UTF-16 length
        XCTAssertNil(
            AppleSpeechProducer.mapToGlobalRange(
                localRange: NSRange(location: 5, length: text.utf16.count),
                utteranceText: text,
                sourceRange: sourceRange
            )
        )

        // Exceeds sourceRange length
        let smallSource = UTF16TextRange(location: 10, length: 5)
        XCTAssertNil(
            AppleSpeechProducer.mapToGlobalRange(
                localRange: NSRange(location: 4, length: 3),
                utteranceText: text,
                sourceRange: smallSource
            )
        )

        // Arithmetic overflow
        XCTAssertNil(
            AppleSpeechProducer.mapToGlobalRange(
                localRange: NSRange(location: 1, length: 2),
                utteranceText: text,
                sourceRange: UTF16TextRange(location: Int.max, length: text.utf16.count)
            )
        )
    }

    // MARK: - Monotonic Generation Fencing Tests

    @MainActor
    func testGenerationIncrementsMonotonicallyOnStopSeekAndReset() {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        XCTAssertEqual(producer.generationID, 0)

        producer.stop()
        XCTAssertEqual(producer.generationID, 1)

        producer.seek(to: PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: 20)!)
        XCTAssertEqual(producer.generationID, 2)

        producer.reset()
        XCTAssertEqual(producer.generationID, 3)

        producer.stop()
        XCTAssertEqual(producer.generationID, 4)
    }

    @MainActor
    func testFencingDropsCallbacksFromPreviousGenerationAfterStop() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        var didStartCalls = 0
        var willSpeakCalls = 0
        var didFinishCalls = 0

        producer.onDidStart = { _ in didStartCalls += 1 }
        producer.onWillSpeak = { _, _ in willSpeakCalls += 1 }
        producer.onDidFinish = { _ in didFinishCalls += 1 }

        let reqText = "First sentence."
        let request = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: reqText,
            sourceRange: UTF16TextRange(location: 0, length: reqText.utf16.count)
        )

        producer.speak(request)
        XCTAssertEqual(mock.spokenUtterances.count, 1)
        let utterance = mock.spokenUtterances[0]

        // Calling stop increments generation and invalidates pending registrations
        producer.stop()
        XCTAssertEqual(producer.generationID, 1)

        // Simulate stale callbacks arriving from the stopped generation 0
        mock.simulateDidStart(utterance: utterance)
        mock.simulateWillSpeak(range: NSRange(location: 0, length: 5), utterance: utterance)
        mock.simulateDidFinish(utterance: utterance)

        await producer.flushEventsForTesting()

        // All stale callbacks must be dropped
        XCTAssertEqual(didStartCalls, 0)
        XCTAssertEqual(willSpeakCalls, 0)
        XCTAssertEqual(didFinishCalls, 0)
    }

    @MainActor
    func testFencingDropsCallbacksFromPreviousGenerationAfterSeek() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        var didStartCalls = 0
        var willSpeakCalls = 0
        var didCancelCalls = 0

        producer.onDidStart = { _ in didStartCalls += 1 }
        producer.onWillSpeak = { _, _ in willSpeakCalls += 1 }
        producer.onDidCancel = { _ in didCancelCalls += 1 }

        let reqText = "Sentence before seek."
        let request = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: reqText,
            sourceRange: UTF16TextRange(location: 0, length: reqText.utf16.count)
        )

        producer.speak(request)
        XCTAssertEqual(mock.spokenUtterances.count, 1)
        let utterance = mock.spokenUtterances[0]

        // Seek to new cursor
        producer.seek(to: PlaybackSourceCursor(segmentOrdinal: 1, globalUTF16Offset: 50)!)
        XCTAssertEqual(producer.generationID, 1)

        // Stale callbacks from previous utterance
        mock.simulateDidStart(utterance: utterance)
        mock.simulateWillSpeak(range: NSRange(location: 0, length: 8), utterance: utterance)
        mock.simulateDidCancel(utterance: utterance)

        await producer.flushEventsForTesting()

        XCTAssertEqual(didStartCalls, 0)
        XCTAssertEqual(willSpeakCalls, 0)
        XCTAssertEqual(didCancelCalls, 0)
    }

    @MainActor
    func testFencingDropsCallbacksFromPreviousGenerationAfterReset() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        var didFinishCalls = 0
        producer.onDidFinish = { _ in didFinishCalls += 1 }

        let reqText = "Sentence before reset."
        let request = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: reqText,
            sourceRange: UTF16TextRange(location: 0, length: reqText.utf16.count)
        )

        producer.speak(request)
        let utterance = mock.spokenUtterances[0]

        producer.reset()
        XCTAssertEqual(producer.generationID, 1)

        mock.simulateDidFinish(utterance: utterance)
        await producer.flushEventsForTesting()

        XCTAssertEqual(didFinishCalls, 0)
    }

    @MainActor
    func testFencingAcceptsCallbacksMatchingActiveGeneration() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        var startedCallback: PlaybackCallbackIdentity?
        var spokenRange: UTF16TextRange?
        var finishedCallback: PlaybackCallbackIdentity?

        producer.onDidStart = { cb in startedCallback = cb }
        producer.onWillSpeak = { _, range in spokenRange = range }
        producer.onDidFinish = { cb in finishedCallback = cb }

        let reqText = "Testing active generation."
        let callbackID = makeCallback(offset: 200)
        let request = AppleSpeechProducer.Request(
            callback: callbackID,
            text: reqText,
            sourceRange: UTF16TextRange(location: 200, length: reqText.utf16.count)
        )

        producer.speak(request)
        XCTAssertEqual(mock.spokenUtterances.count, 1)
        let utterance = mock.spokenUtterances[0]

        // Deliver callbacks for the active utterance
        mock.simulateDidStart(utterance: utterance)
        mock.simulateWillSpeak(range: NSRange(location: 8, length: 6), utterance: utterance) // "active"
        mock.simulateDidFinish(utterance: utterance)

        await producer.flushEventsForTesting()

        XCTAssertEqual(startedCallback, callbackID)
        XCTAssertEqual(spokenRange, UTF16TextRange(location: 208, length: 6))
        XCTAssertEqual(finishedCallback, callbackID)
    }

    // MARK: - Bounded Buffer Queuing Tests

    @MainActor
    func testBoundedBufferOnlySpeaksUpToMaxInFlight() {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)
        producer.maxInFlightUtterances = 2

        let r1 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: "Sentence 1",
            sourceRange: UTF16TextRange(location: 0, length: 10)
        )
        let r2 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 10),
            text: "Sentence 2",
            sourceRange: UTF16TextRange(location: 10, length: 10)
        )
        let r3 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 20),
            text: "Sentence 3",
            sourceRange: UTF16TextRange(location: 20, length: 10)
        )

        producer.enqueue([r1, r2, r3])

        // Only 2 should be in flight to the synthesizer (current + 1 pre-buffer)
        XCTAssertEqual(mock.spokenUtterances.count, 2)
        XCTAssertEqual(producer.inFlightRequestCount, 2)
        XCTAssertEqual(producer.pendingRequestCount, 1)
        XCTAssertEqual(producer.totalBufferedCount, 3)
    }

    @MainActor
    func testBoundedBufferPumpsNextUtteranceWhenPreviousFinishes() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)
        producer.maxInFlightUtterances = 2

        let r1 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: "Sentence 1",
            sourceRange: UTF16TextRange(location: 0, length: 10)
        )
        let r2 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 10),
            text: "Sentence 2",
            sourceRange: UTF16TextRange(location: 10, length: 10)
        )
        let r3 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 20),
            text: "Sentence 3",
            sourceRange: UTF16TextRange(location: 20, length: 10)
        )

        producer.enqueue([r1, r2, r3])

        XCTAssertEqual(mock.spokenUtterances.count, 2)
        let utterance1 = mock.spokenUtterances[0]

        // Sentence 1 finishes
        mock.simulateDidFinish(utterance: utterance1)
        await producer.flushEventsForTesting()

        // Sentence 3 should now have been pumped to the synthesizer
        XCTAssertEqual(mock.spokenUtterances.count, 3)
        XCTAssertEqual(mock.spokenUtterances[2].speechString, "Sentence 3")
        XCTAssertEqual(producer.inFlightRequestCount, 2)
        XCTAssertEqual(producer.pendingRequestCount, 0)
    }

    @MainActor
    func testStopClearsBufferAndPendingQueue() {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)
        producer.maxInFlightUtterances = 2

        let r1 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: "Sentence 1",
            sourceRange: UTF16TextRange(location: 0, length: 10)
        )
        let r2 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 10),
            text: "Sentence 2",
            sourceRange: UTF16TextRange(location: 10, length: 10)
        )
        let r3 = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 20),
            text: "Sentence 3",
            sourceRange: UTF16TextRange(location: 20, length: 10)
        )

        producer.enqueue([r1, r2, r3])
        XCTAssertEqual(producer.totalBufferedCount, 3)

        producer.stop()

        XCTAssertEqual(producer.inFlightRequestCount, 0)
        XCTAssertEqual(producer.pendingRequestCount, 0)
        XCTAssertEqual(producer.totalBufferedCount, 0)
        XCTAssertEqual(mock.stopSpeakingCallCount, 1)
    }

    // MARK: - AudioProducerProtocol Conformance & Controls Tests

    @MainActor
    func testPauseAndResumePreservesGeneration() {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)

        let request = AppleSpeechProducer.Request(
            callback: makeCallback(offset: 0),
            text: "Pause test",
            sourceRange: UTF16TextRange(location: 0, length: 10)
        )

        producer.speak(request)
        let genBefore = producer.generationID

        producer.pause()
        XCTAssertEqual(mock.pauseSpeakingCallCount, 1)
        XCTAssertEqual(producer.generationID, genBefore, "Pause must not increment generation ID")

        producer.resume()
        XCTAssertEqual(mock.continueSpeakingCallCount, 1)
        XCTAssertEqual(producer.generationID, genBefore, "Resume must not increment generation ID")
    }

    @MainActor
    func testUsesApplicationAudioSessionIsConfigured() {
        let mock = MockSpeechSynthesizer()
        let _ = AppleSpeechProducer(synthesizer: mock)
        XCTAssertTrue(mock.usesApplicationAudioSession)
    }

    @MainActor
    func testProducerTypeIsApple() {
        let producer = AppleSpeechProducer(synthesizer: MockSpeechSynthesizer())
        XCTAssertEqual(producer.producerType, .apple)
    }

    @MainActor
    func testAudioProducerDelegateReceivesEvents() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)
        let delegate = TestProducerDelegate()
        producer.delegate = delegate

        let callback = makeCallback(offset: 50)
        let reqText = "Testing delegate dispatch."
        let request = AppleSpeechProducer.Request(
            callback: callback,
            text: reqText,
            sourceRange: UTF16TextRange(location: 50, length: reqText.utf16.count)
        )

        producer.speak(request)
        let utterance = mock.spokenUtterances[0]

        mock.simulateDidStart(utterance: utterance)
        mock.simulateWillSpeak(range: NSRange(location: 8, length: 8), utterance: utterance) // "delegate"
        mock.simulateDidFinish(utterance: utterance)

        await producer.flushEventsForTesting()

        XCTAssertEqual(delegate.startedCallbacks.count, 1)
        XCTAssertEqual(delegate.startedCallbacks.first, callback)

        XCTAssertEqual(delegate.spokenRanges.count, 1)
        XCTAssertEqual(delegate.spokenRanges.first?.0, callback)
        XCTAssertEqual(delegate.spokenRanges.first?.1, UTF16TextRange(location: 58, length: 8))

        XCTAssertEqual(delegate.finishedCallbacks.count, 1)
        XCTAssertEqual(delegate.finishedCallbacks.first, callback)
    }

    @MainActor
    func testEventStreamYieldsEvents() async {
        let mock = MockSpeechSynthesizer()
        let producer = AppleSpeechProducer(synthesizer: mock)
        let stream = producer.makeEventStream()

        let callback = makeCallback(offset: 100)
        let reqText = "Testing stream event delivery."
        let request = AppleSpeechProducer.Request(
            callback: callback,
            text: reqText,
            sourceRange: UTF16TextRange(location: 100, length: reqText.utf16.count)
        )

        var collectedEvents: [AudioProducerEvent] = []
        let collectTask = Task { @MainActor in
            for await event in stream {
                collectedEvents.append(event)
                if case .didFinish = event {
                    break
                }
            }
        }

        producer.speak(request)
        let utterance = mock.spokenUtterances[0]

        mock.simulateDidStart(utterance: utterance)
        mock.simulateWillSpeak(range: NSRange(location: 8, length: 6), utterance: utterance) // "stream"
        mock.simulateDidFinish(utterance: utterance)

        await producer.flushEventsForTesting()
        _ = await collectTask.result

        XCTAssertEqual(collectedEvents.count, 3)
        XCTAssertEqual(collectedEvents[0], .didStart(callback))
        XCTAssertEqual(collectedEvents[1], .willSpeak(callback, UTF16TextRange(location: 108, length: 6)))
        XCTAssertEqual(collectedEvents[2], .didFinish(callback))
    }

    func testSpeechRateCalculation() {
        let baseRate = AVSpeechUtteranceDefaultSpeechRate
        XCTAssertEqual(AppleSpeechProducer.speechRate(for: 1.0), baseRate)
        XCTAssertEqual(AppleSpeechProducer.speechRate(for: 0.1), baseRate * 0.5) // Clamped at min multiplier 0.5
        XCTAssertEqual(AppleSpeechProducer.speechRate(for: 100.0), AVSpeechUtteranceMaximumSpeechRate) // Clamped at max rate
    }

    func testAudioSessionActivation() {
        let producer = AppleSpeechProducer(synthesizer: MockSpeechSynthesizer())
        XCTAssertNoThrow(try producer.activateAudioSession())
    }
}
