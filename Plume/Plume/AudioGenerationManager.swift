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
    private var cancellationTask: Task<Void, Never>?
    
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
        
        generationTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if !self.isGeneratingAny {
                        UIApplication.shared.isIdleTimerDisabled = false
                        playbackEngine.finishGeneration()
                    }
                }
            }
            
            if let cancelTask = self?.cancellationTask {
                await cancelTask.value
            }
            
            if Task.isCancelled { return }
            
            // Prevent the device from sleeping while generating in the foreground
            UIApplication.shared.isIdleTimerDisabled = true
            
            do {
                if startChunkIndex == 0 {
                    playbackEngine.load(document: document)
                }
                
                let generator = try await KokoroTTSService.shared.synthesizeGenerator(document: document, startChunkIndex: startChunkIndex)
                
                var isFirst = true
                var totalChunks = startChunkIndex
                var accumulatedDuration: TimeInterval = 0.0
                
                var isThrottled = false
                
                while true {
                    if Task.isCancelled { break }
                    
                    // Ensure we don't spam generation loops if it's completely unchecked,
                    // but since nextChunk() is blocking and tied to TTS progress, we can just await it.
                    // Throttle only if buffer is very large so we don't use all RAM.
                    while true {
                        if Task.isCancelled { break }
                        let (bufferedDuration, currentPlayTime) = await MainActor.run {
                            (playbackEngine.duration, playbackEngine.currentTime)
                        }
                        
                        let bufferAhead = bufferedDuration - currentPlayTime
                        
                        // High Watermark throttling only
                        if !isThrottled && bufferAhead > (self?.highWatermarkSeconds ?? 120.0) {
                            isThrottled = true
                        }
                        if isThrottled && bufferAhead <= (self?.lowWatermarkSeconds ?? 90.0) {
                            isThrottled = false
                        }
                        
                        if !isThrottled {
                            break
                        }
                        
                        Task { @MainActor [weak self] in
                            self?.generationProgress = "Buffering... (\(Int(bufferAhead))s ahead)"
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    
                    if Task.isCancelled { break }
                    
                    // Background Metal safety is handled by the engine actor's
                    // tryStartExecuting() gate, which blocks when isPaused is true
                    // (set by willResignActiveNotification handler).
                    
                    // 2. Safely generate the chunk (guaranteed to not hit background Metal revocation)
                    guard let chunk = try await generator.nextChunk() else {
                        break // End of chapter
                    }
                    if Task.isCancelled { break }
                    
                    let exactDuration = try await AVURLAsset(url: chunk.fileURL).load(.duration).seconds
                    
                    // 3. Process the chunk
                    totalChunks += 1
                    
                    let updatedChunk = AudioChunk(fileURL: chunk.fileURL, duration: exactDuration, timestamps: chunk.timestamps)
                    accumulatedDuration += exactDuration
                    
                    let currentChunkCount = totalChunks
                    Task { @MainActor in
                        self?.generationProgress = "Streaming chunk \(currentChunkCount)..."
                    }
                    
                    await MainActor.run {
                        playbackEngine.enqueue(chunk: updatedChunk)
                        if isFirst {
                            playbackEngine.play()
                            isFirst = false
                        }
                    }
                }
                
                Task { @MainActor [weak self] in
                    self?.generationProgress = nil
                    self?.generatingDocumentIDs.remove(documentID)
                }
            } catch {
                Task { @MainActor in
                    self?.generationProgress = nil
                    self?.generatingDocumentIDs.remove(documentID)
                    if !(error is CancellationError) {
                        Log.tts.error("Failed to synthesize: \(error.localizedDescription, privacy: .public)")
                        self?.lastError = "Failed to generate audio: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    public func cancelCurrentGeneration() {
        generationTask?.cancel()
        generationTask = nil
        
        // Also tell the TTS engine to stop
        cancellationTask = Task {
            await KokoroTTSService.shared.cancelGeneration()
        }
        
        if let docID = generatingDocumentIDs.first {
            generatingDocumentIDs.remove(docID)
        }
        generationProgress = nil
    }
}
