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
    
    
    public func generate(document: Document, playbackEngine: AudioPlaybackEngine) {
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
                playbackEngine.load(document: document)
                
                let generator = try await KokoroTTSService.shared.synthesizeGenerator(document: document)
                
                var isFirst = true
                var allTimestamps: [WordTimestamp] = []
                var totalChunks = 0
                var urlsToConcatenate: [URL] = []
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
                    allTimestamps.append(contentsOf: chunk.timestamps)
                    totalChunks += 1
                    urlsToConcatenate.append(chunk.fileURL)
                    
                    let updatedChunk = AudioChunk(fileURL: chunk.fileURL, duration: exactDuration, timestamps: chunk.timestamps)
                    accumulatedDuration += exactDuration
                    
                    let currentChunkCount = totalChunks
                    Task { @MainActor in
                        self?.generationProgress = "Streaming chunk \(currentChunkCount)..."
                    }
                    
                    await MainActor.run {
                        playbackEngine.enqueue(chunk: updatedChunk)
                        document.decodedWordTimestamps = allTimestamps
                        if isFirst {
                            playbackEngine.play()
                            isFirst = false
                        }
                    }
                }
                
                // Final flush of timestamps
                await MainActor.run {
                    document.decodedWordTimestamps = allTimestamps
                }
                
                guard let self = self, !Task.isCancelled else { return }
                
                // Concatenate the chunks into the final audioFileURL
                let finalURL = StorageManager.shared.audioCacheURL.appendingPathComponent("\(document.id.uuidString).m4a")
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                
                if !urlsToConcatenate.isEmpty {
                    let composition = AVMutableComposition()
                    guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw NSError(domain: "GenerationManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
                    }
                    
                    var insertTime = CMTime.zero
                    for url in urlsToConcatenate {
                        let asset = AVURLAsset(url: url)
                        let duration = try await asset.load(.duration)
                        let track = try await asset.loadTracks(withMediaType: .audio).first
                        if let track = track {
                            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: insertTime)
                            insertTime = CMTimeAdd(insertTime, duration)
                        }
                    }
                    
                    do {
                        if let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) {
                            if #available(iOS 18.0, *) {
                                try await exportSession.export(to: finalURL, as: .m4a)
                            } else {
                                exportSession.outputURL = finalURL
                                exportSession.outputFileType = .m4a
                                await exportSession.export()
                                
                                if exportSession.status == .completed {
                                    // Timestamps already updated during streaming
                                } else if let error = exportSession.error {
                                    throw error
                                }
                            }
                        }
                    } catch {
                        Log.tts.error("Failed to export concatenated audio (likely in background): \(error.localizedDescription, privacy: .public)")
                        // We intentionally don't throw to the outer block to avoid showing an error
                        // to the user when the generation itself succeeded but the final save failed.
                    }
                }
                
                Task { @MainActor in
                    self.generationProgress = nil
                    self.generatingDocumentIDs.remove(documentID)
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
