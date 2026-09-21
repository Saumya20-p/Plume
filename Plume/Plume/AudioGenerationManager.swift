import Foundation
import SwiftUI
import Combine
import os
import AVFoundation
import CoreMedia

@MainActor
public class AudioGenerationManager: ObservableObject {
    public static let shared = AudioGenerationManager()
    
    @Published public var generatingDocumentIDs: Set<UUID> = []
    @Published public var lastError: String?
    @Published public var generationProgress: String?
    
    private let highWatermarkSeconds: TimeInterval = 120.0  // ~2 min buffer ahead
    private let lowWatermarkSeconds: TimeInterval = 90.0    // resume threshold
    
    /// The in-flight generation Task, stored so it can be cancelled.
    private var generationTask: Task<Void, Never>?
    internal var cancellationTask: Task<Void, Never>?
    private var generationRunState = PlaybackGenerationRunState()
    private weak var activePlaybackEngine: AudioPlaybackEngine?
    
    public var isGeneratingAny: Bool {
        !generatingDocumentIDs.isEmpty
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
                    // 1. Immediately prevent new GPU work from starting.
                    //    backgroundState is nonisolated with NSLock — safe to set directly.
                    KokoroTTSService.shared.getEngineActorSync()?.backgroundState.isPaused = true
                    
                    // 2. Wait for any currently generating chunk to finish, then drain all in-flight 
                    //    Metal command buffers while GPU access is still valid.
                    //    This blocks the main thread (with a 3.5s timeout) but is necessary
                    //    to prevent the SIGABRT when iOS revokes GPU access.
                    KokoroTTSService.shared.waitForGPUIdleSync()
                }
            }
            .store(in: &cancellables)
        
        // Resume Metal GPU work when returning to foreground
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
        
        generationTask = Task { @MainActor [weak self, weak playbackEngine] in
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
            
            // Prevent the device from sleeping while generating in the foreground
            UIApplication.shared.isIdleTimerDisabled = true
            
            do {
                if startChunkIndex == 0 {
                    playbackEngine.load(document: document, generationSession: session)
                }
                
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
                        playbackEngine.play()
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
        let cancelledSessionID = generationRunState.invalidateCurrent()
        let cancelledDocumentID = generatingDocumentIDs.first
        let playbackEngine = activePlaybackEngine

        activePlaybackEngine = nil
        generationTask?.cancel()
        generationTask = nil
        
        // Also tell the TTS engine to stop
        cancellationTask = Task {
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
