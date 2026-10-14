import Foundation
import SwiftUI
import Combine
import os
import AVFoundation
import CoreMedia

public enum GenerationMode: Sendable {
    case standard
    case preparationOnly
}

@MainActor
public class AudioGenerationManager: ObservableObject {
    public static let shared = AudioGenerationManager()
    
    @Published public var generatingDocumentIDs: Set<UUID> = []
    @Published public var lastError: String?
    @Published public var generationProgress: String?
    @Published public private(set) var generationMode: GenerationMode = .standard
    @Published public private(set) var isSpeculativeGenerating: Bool = false
    
    private let highWatermarkSeconds: TimeInterval = 120.0  // ~2 min buffer ahead
    private let lowWatermarkSeconds: TimeInterval = 90.0    // resume threshold
    
    /// The in-flight generation Task, stored so it can be cancelled.
    private var generationTask: Task<Void, Never>?
    private var speculativeGenerationTask: Task<Void, Never>?
    private var speculativeSessionID: UUID?
    internal var cancellationTask: Task<Void, Never>?
    private var generationRunState = PlaybackGenerationRunState()
    private weak var activePlaybackEngine: AudioPlaybackEngine?
    
    public var isGeneratingAny: Bool {
        !generatingDocumentIDs.isEmpty || isSpeculativeGenerating
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Pause Metal GPU work when going to background to prevent SIGABRT
        // from iOS revoking GPU access on backgrounded apps.
        // CRITICAL: This MUST be synchronous. Using Task { await ... } is too late —
        // by the time the async Task reaches the actor, iOS has already revoked GPU
        // access and in-flight Metal command buffers cause SIGABRT.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                guard self != nil else { return }
                MainActor.assumeIsolated {
                    // Immediately prevent new GPU work from starting.
                    // Instantaneous (~1 microsecond) — zero gesture lag.
                    KokoroTTSService.shared.getEngineActorSync()?.backgroundState.isPaused = true
                }
            }
            .store(in: &cancellables)
        
        // Resume Metal GPU work immediately when returning to foreground
        // (willEnterForeground rather than waiting for didBecomeActive to eliminate 400ms cold start latency)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard self != nil else { return }
                MainActor.assumeIsolated {
                    KokoroTTSService.shared.getEngineActorSync()?.backgroundState.isPaused = false
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard self != nil else { return }
                MainActor.assumeIsolated {
                    KokoroTTSService.shared.getEngineActorSync()?.backgroundState.isPaused = false
                }
            }
            .store(in: &cancellables)
    }
    
    
    public func generate(document: Document, playbackEngine: AudioPlaybackEngine, startChunkIndex: Int = 0) {
        cancelSpeculativePreparation()

        // Guard against duplicate taps
        guard !generatingDocumentIDs.contains(document.id) else { return }
        
        // Guard against concurrent generations
        guard !isGeneratingAny else {
            lastError = "Another chapter is currently generating."
            return
        }
        
        lastError = nil
        generationProgress = "Preparing..."
        generatingDocumentIDs.insert(document.id)
        
        let documentID = document.id
        let session = KokoroGenerationSessionFactory.make(
            documentID: documentID,
            defaults: .standard
        )
        generationRunState.activate(sessionID: session.id)
        activePlaybackEngine = playbackEngine
        playbackEngine.beginGenerationSession(session)
        
        if startChunkIndex == 0 {
            playbackEngine.load(document: document, generationSession: session)
        }
        
        guard let writer = try? AudioCacheStore.shared.beginWriting(documentID: documentID) else {
            completeGeneration(sessionID: session.id, documentID: documentID, playbackEngine: playbackEngine)
            return
        }
        generationTask = Task { @MainActor [weak self, weak playbackEngine] in
            defer { AudioCacheStore.shared.finishWriting(writer) }
            guard let self, let playbackEngine else { return }

            defer {
                self.completeGeneration(
                    sessionID: session.id,
                    documentID: documentID,
                    playbackEngine: playbackEngine
                )
            }
            
            if let cancelTask = self.cancellationTask {
                await cancelTask.value
            }
            
            guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { return }
            await KokoroTTSService.shared.resetCancellation()
            
            // Prevent the device from sleeping while generating in the foreground
            UIApplication.shared.isIdleTimerDisabled = true
            
            do {
                
                let generator = try await KokoroTTSService.shared.synthesizeGenerator(
                    document: document,
                    session: session,
                    startChunkIndex: startChunkIndex
                )
                
                var isFirst = true
                var totalChunks = startChunkIndex
                
                var isThrottled = false
                
                while true {
                    guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { break }
                    
                    // Ensure we don't spam generation loops if it's completely unchecked,
                    // but since nextChunk() is blocking and tied to TTS progress, we can just await it.
                    // Throttle only if buffer is very large so we don't use all RAM.
                    while true {
                        guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { break }
                        let bufferedDuration = playbackEngine.bufferedTime
                        let currentPlayTime = playbackEngine.currentTime
                        
                        let bufferAhead = bufferedDuration - currentPlayTime
                        
                        // High Watermark throttling only
                        if !isThrottled && bufferAhead > self.highWatermarkSeconds {
                            isThrottled = true
                        }
                        if isThrottled && bufferAhead <= self.lowWatermarkSeconds {
                            isThrottled = false
                        }
                        
                        if !isThrottled {
                            break
                        }
                        
                        self.generationProgress = "Buffering... (\(Int(bufferAhead))s ahead)"
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    
                    guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { break }
                    
                    // Background Metal safety is handled by the engine actor's
                    // tryStartExecuting() gate, which blocks when isPaused is true
                    // (set by willResignActiveNotification handler).
                    
                    // 2. Safely generate the chunk (guaranteed to not hit background Metal revocation)
                    guard let chunk = try await generator.nextChunk() else {
                        break // End of chapter
                    }
                    
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: chunk.fileURL.path)

                    guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { break }
                    
                    let exactDuration = try await AVURLAsset(url: chunk.fileURL).load(.duration).seconds
                    guard self.generationRunState.accepts(.work(sessionID: session.id)), !Task.isCancelled else { break }
                    
                    // 3. Process the chunk
                    totalChunks += 1
                    
                    let updatedChunk = AudioChunk(
                        identity: chunk.identity,
                        fileURL: chunk.fileURL,
                        duration: exactDuration,
                        timestamps: chunk.timestamps
                    )
                    
                    let currentChunkCount = totalChunks
                    self.generationProgress = "Streaming chunk \(currentChunkCount)..."
                    
                    guard self.generationRunState.accepts(.enqueue(sessionID: session.id)), !Task.isCancelled else { break }
                    
                    guard playbackEngine.enqueue(chunk: updatedChunk) else { break }
                    if isFirst {
                        if playbackEngine.coordinator.contract?.desiredPlayIntent != .paused {
                            playbackEngine.play()
                        }
                        isFirst = false
                    }
                }
            } catch {
                guard self.generationRunState.accepts(.failure(sessionID: session.id)) else { return }
                if !(error is CancellationError) {
                    Log.tts.error("Failed to synthesize: \(error.localizedDescription, privacy: .public)")
                    self.lastError = "Failed to generate audio: \(error.localizedDescription)"
                }
            }
        }
    }

    public func cancelCurrentGeneration() {
        cancelSpeculativePreparation()

        let cancelledSessionID = generationRunState.invalidateCurrent()
        let cancelledDocumentID = generatingDocumentIDs.first
        let playbackEngine = activePlaybackEngine

        activePlaybackEngine = nil
        generationTask?.cancel()
        generationTask = nil
        
        // Also tell the TTS engine to stop
        let previousCancel = cancellationTask
        cancellationTask = Task {
            if let previousCancel {
                await previousCancel.value
            }
            await KokoroTTSService.shared.cancelGeneration()
        }
        
        if let cancelledDocumentID {
            generatingDocumentIDs.remove(cancelledDocumentID)
        }
        generationProgress = nil
        UIApplication.shared.isIdleTimerDisabled = false

        if let cancelledSessionID {
            playbackEngine?.finishGeneration(sessionID: cancelledSessionID)
        }
    }

    // MARK: - Speculative Preparation (Phase 6 Handback)

    /// Starts speculative generation of audio chunks for upcoming sentences without playing them.
    /// Chunks are staged into `PlaybackRoutingCoordinator` to allow an atomic handback swap
    /// once Apple Speech finishes its current sentence.
    public func startSpeculativePreparation(
        document: Document,
        playbackEngine: AudioPlaybackEngine,
        startChunkIndex: Int
    ) {
        guard startChunkIndex >= 0 else { return }

        // If already generating, cancel the existing generation and restart with new startChunkIndex
        if !generatingDocumentIDs.isEmpty {
            cancelCurrentGeneration()
        }
        cancelSpeculativePreparation()

        isSpeculativeGenerating = true
        generationMode = .preparationOnly
        generationProgress = "Speculatively preparing Kokoro..."
        activePlaybackEngine = playbackEngine

        let documentID = document.id
        let session = KokoroGenerationSessionFactory.make(
            documentID: documentID,
            defaults: .standard
        )
        speculativeSessionID = session.id

        guard let writer = try? AudioCacheStore.shared.beginWriting(documentID: documentID) else {
            cancelSpeculativePreparation()
            return
        }
        speculativeGenerationTask = Task { @MainActor [weak self, weak playbackEngine] in
            defer { AudioCacheStore.shared.finishWriting(writer) }
            guard let self = self, let playbackEngine = playbackEngine else { return }
            defer {
                if self.speculativeSessionID == session.id {
                    self.isSpeculativeGenerating = false
                    self.speculativeGenerationTask = nil
                    self.generationMode = .standard
                    self.generationProgress = nil
                }
            }

            if let cancelTask = self.cancellationTask {
                await cancelTask.value
            }
            guard !Task.isCancelled, playbackEngine.isFallbackActive else { return }
            await KokoroTTSService.shared.resetCancellation()

            do {
                let generator = try await KokoroTTSService.shared.synthesizeGenerator(
                    document: document,
                    session: session,
                    startChunkIndex: startChunkIndex
                )

                var currentChunkIndex = startChunkIndex
                while !Task.isCancelled && playbackEngine.isFallbackActive {
                    guard let chunk = try await generator.nextChunk() else {
                        break
                    }
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: chunk.fileURL.path)

                    guard !Task.isCancelled, playbackEngine.isFallbackActive else { break }

                    let exactDuration = try await AVURLAsset(url: chunk.fileURL).load(.duration).seconds
                    guard !Task.isCancelled, playbackEngine.isFallbackActive else { break }

                    let updatedChunk = AudioChunk(
                        identity: chunk.identity,
                        fileURL: chunk.fileURL,
                        duration: exactDuration,
                        timestamps: chunk.timestamps
                    )

                    playbackEngine.coordinator.stageHandbackChunk(updatedChunk, session: session)
                    currentChunkIndex += 1

                    // If Apple Speech is not speaking right now, trigger handback immediately
                    if !playbackEngine.coordinator.isAppleSpeaking {
                        playbackEngine.coordinator.triggerHandback()
                        break
                    }

                    // Buffer at most 2 speculative chunks ahead
                    if playbackEngine.coordinator.stagedHandbackChunks.count >= 2 {
                        break
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    Log.tts.error("Failed speculative synthesis: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Fetches a single audio chunk speculatively without streaming or enqueuing it.
    public func generateSpeculativeChunk(
        document: Document,
        chunkIndex: Int
    ) async throws -> AudioChunk? {
        let writer = try AudioCacheStore.shared.beginWriting(documentID: document.id)
        defer { AudioCacheStore.shared.finishWriting(writer) }
        if let cancelTask = cancellationTask {
            await cancelTask.value
        }
        try Task.checkCancellation()
        await KokoroTTSService.shared.resetCancellation()

        let session = KokoroGenerationSessionFactory.make(
            documentID: document.id,
            defaults: .standard
        )
        let generator = try await KokoroTTSService.shared.synthesizeGenerator(
            document: document,
            session: session,
            startChunkIndex: chunkIndex
        )
        guard let chunk = try await generator.nextChunk() else {
            return nil
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: chunk.fileURL.path)

        let exactDuration = try await AVURLAsset(url: chunk.fileURL).load(.duration).seconds
        return AudioChunk(
            identity: chunk.identity,
            fileURL: chunk.fileURL,
            duration: exactDuration,
            timestamps: chunk.timestamps
        )
    }

    /// Cancels any in-flight speculative preparation and resets preparation state.
    public func cancelSpeculativePreparation() {
        guard isSpeculativeGenerating || speculativeGenerationTask != nil else { return }
        Log.tts.info("Canceling speculative Kokoro generation.")
        speculativeGenerationTask?.cancel()
        speculativeGenerationTask = nil
        isSpeculativeGenerating = false
        generationMode = .standard
        speculativeSessionID = nil
        generationProgress = nil
        let previousCancel = cancellationTask
        cancellationTask = Task {
            if let previousCancel {
                await previousCancel.value
            }
            await KokoroTTSService.shared.cancelGeneration()
        }
    }

    private func completeGeneration(
        sessionID: UUID,
        documentID: UUID,
        playbackEngine: AudioPlaybackEngine
    ) {
        guard generationRunState.finish(sessionID: sessionID) else { return }

        generationTask = nil
        activePlaybackEngine = nil
        generatingDocumentIDs.remove(documentID)
        generationProgress = nil
        UIApplication.shared.isIdleTimerDisabled = false
        playbackEngine.finishGeneration(sessionID: sessionID)
    }
}
