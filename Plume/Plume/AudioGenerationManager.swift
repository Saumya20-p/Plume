import Combine
import Foundation
import SwiftUI
import AVFoundation

public enum GenerationMode: Sendable { case standard, preparationOnly }
enum GenerationTermination { case eof, failed, retired, cancelled }

@MainActor protocol PlaybackChunkStream: AnyObject {
    func nextResult() async throws -> AudioGenerationOutcome
}
extension AudioChunkGenerator: PlaybackChunkStream {}

/// Generation is scoped to a logical run and seek. Task cancellation never sets
/// a process-wide bit that can poison a replacement run or a voice preview.
@MainActor public class AudioGenerationManager: ObservableObject {
    public static let shared = AudioGenerationManager()
    @Published public var generatingDocumentIDs: Set<UUID> = []
    @Published public var lastError: String?
    @Published public var generationProgress: String?
    @Published public private(set) var generationMode: GenerationMode = .standard
    @Published public private(set) var isSpeculativeGenerating = false
    private(set) var issue: PlaybackIssue?
    private var generationTask: Task<Void, Never>?
    private var speculativeGenerationTask: Task<Void, Never>?
    private var speculativeSessionID: UUID?
    internal var cancellationTask: Task<Void, Never>?
    private var generationRunState = PlaybackGenerationRunState()
    private weak var activePlaybackEngine: AudioPlaybackEngine?
    var onTaskFinished: ((UUID) -> Void)?
    var makeStream: (Document, PlaybackGenerationSession, Int) async throws -> any PlaybackChunkStream = {
        try await KokoroTTSService.shared.synthesizeGenerator(document: $0, session: $1, startChunkIndex: $2)
    }
    public var isGeneratingAny: Bool { !generatingDocumentIDs.isEmpty || isSpeculativeGenerating }
    init() {}

    private struct Context {
        let runID: UUID
        let seek: Int
        let source: String
        let voice: PlaybackVoiceID
        let documentID: UUID
        init?(document: Document, engine: AudioPlaybackEngine) {
            guard let contract = engine.coordinator.contract, contract.lifecycle == .active,
                  case .kokoro = contract.primaryVoice else { return nil }
            runID = contract.sessionID; seek = engine.seekRevision; source = document.bodyText
            voice = contract.primaryVoice; documentID = document.id
        }
        func accepts(_ engine: AudioPlaybackEngine) -> Bool {
            engine.currentDocument?.id == documentID && engine.currentDocument?.bodyText == source &&
            engine.coordinator.contract?.sessionID == runID && engine.seekRevision == seek &&
            engine.coordinator.contract?.primaryVoice == voice && engine.coordinator.contract?.lifecycle == .active
        }
    }

    func clearIssue() { lastError = nil; issue = nil }
    func reportPlaybackFailure(_ error: Error, engine: AudioPlaybackEngine, stage: String) {
        guard !(error is CancellationError), let document = engine.currentDocument,
              let contract = engine.coordinator.contract, contract.lifecycle != .completed else { return }
        let issue = PlaybackIssue(documentID: document.id, runID: contract.sessionID,
            segment: engine.coordinator.currentOrUpcomingSegmentIndex, stage: stage, error: error)
        self.issue = issue; lastError = issue.message
        engine.generationFailed = true
        PlaybackDiagnostics.shared.record("playback-failed stage=\(issue.stage) codes=\(issue.codes.joined(separator: ",")) id=\(issue.id)")
    }
    public func generate(document: Document, playbackEngine: AudioPlaybackEngine, startChunkIndex: Int = 0,
                         preservingPlaybackSession: Bool = false) {
        guard !generatingDocumentIDs.contains(document.id), startChunkIndex >= 0 else { return }
        cancelSpeculativePreparation()
        guard generatingDocumentIDs.isEmpty else { return }
        if playbackEngine.currentDocument?.id != document.id || playbackEngine.coordinator.contract == nil {
            playbackEngine.load(document: document)
        }
        guard let context = Context(document: document, engine: playbackEngine) else { return }
        let session = PlaybackGenerationSession(documentID: document.id, voice: context.voice)
        generationRunState.activate(sessionID: session.id)
        activePlaybackEngine = playbackEngine
        generatingDocumentIDs.insert(document.id)
        clearIssue()
        generationProgress = "Preparing…"
        playbackEngine.beginGenerationSession(session)
        generationTask = Task { @MainActor [weak self, weak playbackEngine] in
            guard let self, let engine = playbackEngine else { return }
            var stage = "cache preparation"
            var segment = startChunkIndex
            var termination = GenerationTermination.retired
            defer {
                self.completeGeneration(sessionID: session.id, documentID: document.id, playbackEngine: engine, termination: termination)
                self.onTaskFinished?(session.id)
            }
            do {
                let writer = try AudioCacheStore.shared.beginWriting(documentID: document.id)
                defer { AudioCacheStore.shared.finishWriting(writer) }
                stage = "model preparation"
                let stream = try await self.makeStream(document, session, startChunkIndex)
                var throttled = false
                while self.generationRunState.accepts(.work(sessionID: session.id)) && context.accepts(engine) {
                    try Task.checkCancellation()
                    let ahead = engine.bufferedTime - engine.currentTime
                    if ahead > 120 { throttled = true }
                    if ahead <= 90 { throttled = false }
                    if throttled { try await Task.sleep(for: .seconds(1)); continue }
                    stage = "speech generation"
                    let outcome = try await stream.nextResult()
                    try Task.checkCancellation()
                    guard context.accepts(engine), self.generationRunState.accepts(.enqueue(sessionID: session.id)) else { return }
                    switch outcome {
                    case .endOfDocument:
                        termination = .eof
                        engine.generationReachedEOF(sessionID: session.id)
                        return
                    case .nonSpeech(let id):
                        segment = id.ordinal + 1
                        continue
                    case .audio(let chunk):
                        segment = chunk.identity.segmentID.ordinal
                        stage = "audio validation"
                        let validated = try await Self.validate(chunk)
                        try Task.checkCancellation()
                        guard context.accepts(engine), self.generationRunState.accepts(.enqueue(sessionID: session.id)) else { return }
                        self.generationProgress = "Preparing audio…"
                        guard engine.enqueue(chunk: validated) else { return }
                        if engine.pendingSeek == nil && engine.coordinator.desiredPlayIntent == .playing { engine.resumeQueuedPlayback() }
                        segment += 1
                    }
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), context.accepts(engine),
                      self.generationRunState.accepts(.failure(sessionID: session.id)) else { return }
                let issue = PlaybackIssue(documentID: document.id, runID: context.runID, segment: segment, stage: stage, error: error)
                self.issue = issue; self.lastError = issue.message
                PlaybackDiagnostics.shared.record("generation-failed run=\(context.runID) segment=\(segment) stage=\(stage) codes=\(issue.codes.joined(separator: ",")) id=\(issue.id)")
                engine.generationFailed = true
                engine.isWaitingForForeground = false
                termination = .failed
            }
        }
    }

    static func validate(_ chunk: AudioChunk) async throws -> AudioChunk {
        guard FileManager.default.fileExists(atPath: chunk.fileURL.path), chunk.duration.isFinite, chunk.duration > 0 else {
            throw NSError(domain: "Plume.AudioValidation", code: 1)
        }
        try Task.checkCancellation()
        let duration = try await AVURLAsset(url: chunk.fileURL).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NSError(domain: "Plume.AudioValidation", code: 2) }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: chunk.fileURL.path)
        return AudioChunk(identity: chunk.identity, fileURL: chunk.fileURL, duration: duration, timestamps: chunk.timestamps)
    }

    public func cancelCurrentGeneration(preservingPlaybackIntent: Bool = false) {
        cancelSpeculativePreparation()
        let cancelled = generationRunState.invalidateCurrent()
        generationTask?.cancel(); generationTask = nil
        generatingDocumentIDs.removeAll(); generationProgress = nil
        let engine = activePlaybackEngine; activePlaybackEngine = nil
        if let cancelled { engine?.finishGeneration(sessionID: cancelled, termination: preservingPlaybackIntent ? .retired : .cancelled) }
    }

    public func startSpeculativePreparation(document: Document, playbackEngine: AudioPlaybackEngine, startChunkIndex: Int) {
        guard let context = Context(document: document, engine: playbackEngine), startChunkIndex >= 0,
              playbackEngine.isFallbackActive, playbackEngine.applicationPhase == .active,
              playbackEngine.coordinator.desiredPlayIntent == .playing else { return }
        if isSpeculativeGenerating { return }
        if !generatingDocumentIDs.isEmpty { cancelCurrentGeneration(preservingPlaybackIntent: true) }
        let session = PlaybackGenerationSession(documentID: document.id, voice: context.voice)
        speculativeSessionID = session.id
        isSpeculativeGenerating = true; generationMode = .preparationOnly
        playbackEngine.coordinator.beginHandbackPreparation(session)
        speculativeGenerationTask = Task { @MainActor [weak self, weak playbackEngine] in
            guard let self, let engine = playbackEngine else { return }
            defer {
                if self.speculativeSessionID == session.id {
                    self.speculativeSessionID = nil; self.speculativeGenerationTask = nil
                    self.isSpeculativeGenerating = false; self.generationMode = .standard
                    engine.coordinator.finishHandbackPreparation(session.id)
                }
            }
            do {
                let writer = try AudioCacheStore.shared.beginWriting(documentID: document.id)
                defer { AudioCacheStore.shared.finishWriting(writer) }
                let stream = try await self.makeStream(document, session, startChunkIndex)
                while context.accepts(engine) && engine.isFallbackActive && engine.applicationPhase == .active {
                    try Task.checkCancellation()
                    let result = try await stream.nextResult()
                    try Task.checkCancellation()
                    guard self.speculativeSessionID == session.id, context.accepts(engine),
                          engine.isFallbackActive, engine.applicationPhase == .active else { return }
                    switch result {
                    case .endOfDocument: return
                    case .nonSpeech: continue
                    case .audio(let chunk):
                        let audio = try await Self.validate(chunk)
                        try Task.checkCancellation()
                        guard self.speculativeSessionID == session.id, context.accepts(engine),
                              engine.isFallbackActive, engine.applicationPhase == .active else { return }
                        engine.coordinator.stageHandbackChunk(audio, session: session)
                        if engine.coordinator.stagedHandbackChunks.count >= 2 || !engine.isFallbackActive { return }
                    }
                }
            } catch {
                guard !Task.isCancelled, context.accepts(engine), self.speculativeSessionID == session.id else { return }
                let issue = PlaybackIssue(documentID: document.id, runID: context.runID, segment: startChunkIndex,
                                          stage: "handback preparation", error: error)
                PlaybackDiagnostics.shared.record("handback-failed codes=\(issue.codes.joined(separator: ",")) id=\(issue.id)")
                if !engine.allowsAutomaticFallback {
                    // With fallback disabled there is no producer to keep
                    // flowing after the current Apple sentence. Expose Retry
                    // instead of leaving an active-foreground wait stranded.
                    self.reportPlaybackFailure(error, engine: engine, stage: "Kokoro restoration")
                    if !engine.coordinator.isAppleSpeaking { engine.pause() }
                }
            }
        }
    }

    public func cancelSpeculativePreparation() {
        speculativeGenerationTask?.cancel(); speculativeGenerationTask = nil
        speculativeSessionID = nil; isSpeculativeGenerating = false; generationMode = .standard
    }

    public func generateSpeculativeChunk(document: Document, chunkIndex: Int) async throws -> AudioChunk? {
        let engine = activePlaybackEngine ?? AudioPlaybackEngine.shared
        guard let context = Context(document: document, engine: engine) else { return nil }
        let session = PlaybackGenerationSession(documentID: document.id, voice: context.voice)
        let stream = try await makeStream(document, session, chunkIndex)
        while true {
            try Task.checkCancellation()
            guard context.accepts(engine) else { return nil }
            switch try await stream.nextResult() {
            case .endOfDocument: return nil
            case .nonSpeech: continue
            case .audio(let chunk): return try await Self.validate(chunk)
            }
        }
    }

    private func completeGeneration(sessionID: UUID, documentID: UUID, playbackEngine: AudioPlaybackEngine, termination: GenerationTermination) {
        guard generationRunState.finish(sessionID: sessionID) else { return }
        generationTask = nil; activePlaybackEngine = nil
        generatingDocumentIDs.remove(documentID); generationProgress = nil
        playbackEngine.finishGeneration(sessionID: sessionID, termination: termination)
    }
}
