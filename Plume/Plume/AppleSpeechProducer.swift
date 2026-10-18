import AVFoundation
import Foundation
import Synchronization

@MainActor
protocol SpeechSynthesizing: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var usesApplicationAudioSession: Bool { get set }

    func speak(_ utterance: AVSpeechUtterance)
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {
    #if !os(iOS) && !os(tvOS) && !os(watchOS) && !targetEnvironment(macCatalyst)
    var usesApplicationAudioSession: Bool {
        get { true }
        set {}
    }
    #endif
}

nonisolated private struct AppleSpeechEvent: Sendable {
    nonisolated enum Kind: Sendable {
        case didStart
        case willSpeak(UTF16TextRange)
        case didFinish
        case didCancel

        var isTerminal: Bool {
            switch self {
            case .didFinish, .didCancel:
                true
            case .didStart, .willSpeak:
                false
            }
        }
    }

    let requestID: UUID
    let generationID: UInt64
    let kind: Kind
}

nonisolated private final class AppleSpeechEventBridge: Sendable {
    private struct Registration: Sendable {
        let requestID: UUID
        let generationID: UInt64
    }

    private let state = Mutex<(activeGenerationID: UInt64, registrations: [ObjectIdentifier: Registration])>(
        (activeGenerationID: 0, registrations: [:])
    )
    private let continuation: AsyncStream<AppleSpeechEvent>.Continuation

    init(continuation: AsyncStream<AppleSpeechEvent>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func setGenerationID(_ generationID: UInt64) {
        state.withLock { state in
            state.activeGenerationID = generationID
            state.registrations.removeAll(keepingCapacity: true)
        }
    }

    nonisolated func register(utteranceID: ObjectIdentifier, generationID: UInt64) -> UUID {
        let requestID = UUID()
        state.withLock { state in
            state.registrations[utteranceID] = Registration(
                requestID: requestID,
                generationID: generationID
            )
        }
        return requestID
    }

    nonisolated func yield(
        _ kind: AppleSpeechEvent.Kind,
        for utteranceID: ObjectIdentifier
    ) {
        state.withLock { state in
            guard let registration = state.registrations[utteranceID] else { return }
            guard registration.generationID == state.activeGenerationID else { return }

            continuation.yield(
                AppleSpeechEvent(
                    requestID: registration.requestID,
                    generationID: registration.generationID,
                    kind: kind
                )
            )
            if kind.isTerminal {
                state.registrations.removeValue(forKey: utteranceID)
            }
        }
    }

    nonisolated func removeAllRegistrations() {
        state.withLock { state in
            state.registrations.removeAll(keepingCapacity: true)
        }
    }

    nonisolated func finish() {
        state.withLock { state in
            state.registrations.removeAll(keepingCapacity: false)
            continuation.finish()
        }
    }
}

@MainActor
final class AppleSpeechProducer: NSObject, AVSpeechSynthesizerDelegate, AudioProducerProtocol {
    struct Request: Equatable, Sendable {
        let callback: PlaybackCallbackIdentity
        let text: String
        let sourceRange: UTF16TextRange
        let voice: AVSpeechSynthesisVoice?
        let rate: Float

        init(
            callback: PlaybackCallbackIdentity,
            text: String,
            sourceRange: UTF16TextRange,
            voice: AVSpeechSynthesisVoice? = nil,
            rate: Float = AVSpeechUtteranceDefaultSpeechRate
        ) {
            self.callback = callback
            self.text = text
            self.sourceRange = sourceRange
            self.voice = voice
            self.rate = rate
        }
    }

    private struct RegisteredRequest {
        let request: Request
        let utterance: AVSpeechUtterance
        let generationID: UInt64
    }

    var producerType: PlaybackProducer { .apple }

    private let synthesizer: any SpeechSynthesizing
    private let eventBridge: AppleSpeechEventBridge
    private var eventConsumer: Task<Void, Never>?
    private var streamContinuations: [UUID: AsyncStream<AudioProducerEvent>.Continuation] = [:]

    private var requests: [UUID: RegisteredRequest] = [:]
    private var pendingQueue: [Request] = []
    private var inFlightUtteranceCount: Int = 0

    var maxInFlightUtterances: Int = 2
    private(set) var generationID: UInt64 = 0
    private var activeCursor: Int?
    private var activeRequestID: UUID?

    weak var delegate: (any AudioProducerDelegate)?
    var onDidStart: ((PlaybackCallbackIdentity) -> Void)?
    var onWillSpeak: ((PlaybackCallbackIdentity, UTF16TextRange) -> Void)?
    var onDidFinish: ((PlaybackCallbackIdentity) -> Void)?
    var onDidCancel: ((PlaybackCallbackIdentity) -> Void)?

    var isSpeaking: Bool {
        synthesizer.isSpeaking || inFlightUtteranceCount > 0
    }

    var isPaused: Bool {
        synthesizer.isPaused
    }

    var inFlightRequestCount: Int {
        inFlightUtteranceCount
    }

    var pendingRequestCount: Int {
        pendingQueue.count
    }

    var totalBufferedCount: Int {
        inFlightUtteranceCount + pendingQueue.count
    }

    private let audioSessionOwner = UUID()
    private let managesAudioSession: Bool
    private var preparingAudioGeneration: UInt64?

    init(synthesizer: (any SpeechSynthesizing)? = nil) {
        managesAudioSession = synthesizer == nil
        let actualSynthesizer = synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = actualSynthesizer
        let (stream, continuation) = AsyncStream.makeStream(of: AppleSpeechEvent.self)
        self.eventBridge = AppleSpeechEventBridge(continuation: continuation)
        super.init()

        self.synthesizer.delegate = self
        self.synthesizer.usesApplicationAudioSession = true

        self.eventConsumer = Task { @MainActor [weak self, stream] in
            for await event in stream {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    deinit {
        eventBridge.finish()
        eventConsumer?.cancel()
        for continuation in streamContinuations.values {
            continuation.finish()
        }
    }
    
    func activateAudioSession() throws {
        // Preparation is asynchronous through AppAudioSession before pumping.
        // Retain the protocol entry point without synchronous session mutations.
    }

    func speak(_ request: Request) {
        enqueue(request)
    }

    func enqueue(_ request: Request) {
        pendingQueue.append(request)
        pumpQueue()
    }

    func enqueue(_ requests: [Request]) {
        pendingQueue.append(contentsOf: requests)
        pumpQueue()
    }

    func clearPendingQueue() {
        pendingQueue.removeAll(keepingCapacity: true)
    }

    func pause() {
        guard isSpeaking else { return }
        _ = synthesizer.pauseSpeaking(at: .immediate)
        
        if let activeCursor = activeCursor,
           let activeRequestID = activeRequestID,
           let request = requests[activeRequestID] {
             if let globalRange = Self.mapToGlobalRange(
                 localRange: NSRange(location: activeCursor, length: 0),
                 utteranceText: request.request.text,
                 sourceRange: request.request.sourceRange
             ) {
                 onWillSpeak?(request.request.callback, globalRange)
                 delegate?.producerWillSpeak(self, callback: request.request.callback, globalRange: globalRange)
                 yieldProducerEvent(.willSpeak(request.request.callback, globalRange))
             }
        }
    }

    func resume() {
        if managesAudioSession && !AppAudioSession.shared.isReady(owner: audioSessionOwner) {
            let generation = generationID
            AppAudioSession.shared.prepare(owner: audioSessionOwner, reason: "speech-resume") { [weak self] result in
                guard let self, self.generationID == generation else { return }
                switch result {
                case .success: self.resume()
                case .failure(let error): self.handleAudioSessionFailure(error)
                }
            }
            return
        }
        if synthesizer.isPaused {
            _ = synthesizer.continueSpeaking()
        }
    }

    func stop() {
        invalidatePlaybackState()
    }

    func seek(to cursor: PlaybackSourceCursor) {
        invalidatePlaybackState()
    }

    func reset() {
        invalidatePlaybackState()
    }

    private func invalidatePlaybackState() {
        generationID &+= 1
        preparingAudioGeneration = nil
        eventBridge.setGenerationID(generationID)
        _ = synthesizer.stopSpeaking(at: .immediate)
        if managesAudioSession { AppAudioSession.shared.release(owner: audioSessionOwner, reason: "speech-stop") }
        requests.removeAll(keepingCapacity: true)
        pendingQueue.removeAll(keepingCapacity: true)
        inFlightUtteranceCount = 0
        activeCursor = nil
        activeRequestID = nil
    }

    private func pumpQueue() {
        guard !pendingQueue.isEmpty else { return }
        if managesAudioSession && !AppAudioSession.shared.isReady(owner: audioSessionOwner) {
            guard preparingAudioGeneration != generationID else { return }
            let generation = generationID
            preparingAudioGeneration = generation
            AppAudioSession.shared.prepare(owner: audioSessionOwner, reason: "apple-speech") { [weak self] result in
                guard let self, self.generationID == generation else { return }
                self.preparingAudioGeneration = nil
                switch result {
                case .success: self.pumpQueue()
                case .failure(let error): self.handleAudioSessionFailure(error)
                }
            }
            return
        }
        while inFlightUtteranceCount < maxInFlightUtterances && !pendingQueue.isEmpty {
            let nextRequest = pendingQueue.removeFirst()
            dispatchUtterance(for: nextRequest)
        }
    }

    private func handleAudioSessionFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        invalidatePlaybackState()
        AudioPlaybackEngine.shared.pause()
        AudioPlaybackEngine.shared.coordinator.reportAudioSessionFailure(error)
    }

    private func dispatchUtterance(for request: Request) {
        let utterance = AVSpeechUtterance(string: request.text)
        if let voice = request.voice {
            utterance.voice = voice
        }
        utterance.rate = request.rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        let requestID = eventBridge.register(
            utteranceID: ObjectIdentifier(utterance),
            generationID: generationID
        )
        requests[requestID] = RegisteredRequest(
            request: request,
            utterance: utterance,
            generationID: generationID
        )
        inFlightUtteranceCount += 1
        synthesizer.speak(utterance)
    }

    func makeEventStream() -> AsyncStream<AudioProducerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioProducerEvent.self)
        streamContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.streamContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func yieldProducerEvent(_ event: AudioProducerEvent) {
        for continuation in streamContinuations.values {
            continuation.yield(event)
        }
    }

    nonisolated static func mapToGlobalRange(
        localRange: NSRange,
        utteranceText: String,
        sourceRange: UTF16TextRange
    ) -> UTF16TextRange? {
        guard let validatedRange = UTF16TextRange.validated(
            location: localRange.location,
            length: localRange.length,
            withinUTF16Length: utteranceText.utf16.count
        ),
        validatedRange.location <= sourceRange.length,
        validatedRange.length <= sourceRange.length - validatedRange.location,
        sourceRange.location <= Int.max - validatedRange.location
        else { return nil }

        return UTF16TextRange(
            location: sourceRange.location + validatedRange.location,
            length: validatedRange.length
        )
    }

    nonisolated static func speechRate(for playbackMultiplier: Float) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * max(0.5, playbackMultiplier)
        return min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, rate)
        )
    }

    private func handle(_ event: AppleSpeechEvent) {
        guard event.generationID == self.generationID else {
            return
        }

        switch event.kind {
        case .didStart:
            handleDidStart(event.requestID)
        case .willSpeak(let localRange):
            handleWillSpeak(event.requestID, localRange: localRange)
        case .didFinish:
            handleDidFinish(event.requestID)
        case .didCancel:
            handleDidCancel(event.requestID)
        }
    }

    private func handleDidStart(_ requestID: UUID) {
        guard let registered = requests[requestID],
              registered.generationID == self.generationID else {
            return
        }
        onDidStart?(registered.request.callback)
        delegate?.producerDidStart(self, callback: registered.request.callback)
        yieldProducerEvent(.didStart(registered.request.callback))
    }

    private func handleWillSpeak(
        _ requestID: UUID,
        localRange: UTF16TextRange
    ) {
        guard let registered = requests[requestID],
              registered.generationID == self.generationID,
              let globalRange = Self.mapToGlobalRange(
                  localRange: localRange.nsRange,
                  utteranceText: registered.request.text,
                  sourceRange: registered.request.sourceRange
              ) else {
            return
        }
        activeCursor = localRange.location
        activeRequestID = requestID
        onWillSpeak?(registered.request.callback, globalRange)
        delegate?.producerWillSpeak(self, callback: registered.request.callback, globalRange: globalRange)
        yieldProducerEvent(.willSpeak(registered.request.callback, globalRange))
    }

    private func handleDidFinish(_ requestID: UUID) {
        guard let registered = requests.removeValue(forKey: requestID),
              registered.generationID == self.generationID else {
            return
        }
        inFlightUtteranceCount = max(0, inFlightUtteranceCount - 1)
        pumpQueue()
        onDidFinish?(registered.request.callback)
        delegate?.producerDidFinish(self, callback: registered.request.callback)
        yieldProducerEvent(.didFinish(registered.request.callback))
    }

    private func handleDidCancel(_ requestID: UUID) {
        guard let registered = requests.removeValue(forKey: requestID),
              registered.generationID == self.generationID else {
            return
        }
        inFlightUtteranceCount = max(0, inFlightUtteranceCount - 1)
        pumpQueue()
        onDidCancel?(registered.request.callback)
        delegate?.producerDidCancel(self, callback: registered.request.callback)
        yieldProducerEvent(.didCancel(registered.request.callback))
    }

    #if DEBUG
    func flushEventsForTesting() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    #endif

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        eventBridge.yield(.didStart, for: ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard characterRange.location != NSNotFound,
              characterRange.location >= 0,
              characterRange.length >= 0,
              characterRange.location <= Int.max - characterRange.length else {
            return
        }
        
        eventBridge.yield(
            .willSpeak(UTF16TextRange(location: characterRange.location, length: characterRange.length)),
            for: ObjectIdentifier(utterance)
        )
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        eventBridge.yield(.didFinish, for: ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        eventBridge.yield(.didCancel, for: ObjectIdentifier(utterance))
    }
}
