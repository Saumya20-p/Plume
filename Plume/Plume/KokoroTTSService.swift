public struct AudioChunk {
    public let fileURL: URL
    public let duration: TimeInterval
    public let timestamps: [WordTimestamp]
}

import AVFoundation
import MLX
import MLXNN
import MLXRandom
import KokoroSwift
import Combine
import SwiftUI
import MLXUtilsLibrary
import os

import NaturalLanguage

final class EngineBackgroundState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var paused = false
    nonisolated(unsafe) private var executing = false
    nonisolated init() {}
    
    nonisolated var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }
    
    nonisolated var isExecuting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return executing }
    }
    
    nonisolated func tryStartExecuting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if paused {
            return false
        }
        executing = true
        return true
    }
    
    nonisolated func stopExecuting() {
        lock.lock()
        executing = false
        lock.unlock()
    }
}

actor KokoroEngineActor {
    private let tts: KokoroTTS
    private let voiceEmbedding: MLXArray
    private let language: KokoroSwift.Language
    
    // Semaphore is no longer needed since actor isolation guarantees serial execution
    
    nonisolated let backgroundState = EngineBackgroundState()
    
    var isGenerating: Bool = false
    
    var isCancelled: Bool = false
    
    func waitForIdle() {
        // Explicitly synchronize the GPU stream to ensure no Metal command buffers
        // are left in-flight when transitioning to the background. This prevents
        // OS SIGABRT kills if the app is suspended mid-GPU-work.
        MLX.Stream.defaultStream(.gpu).synchronize()
    }
    
    func pauseForBackground() {
        backgroundState.isPaused = true
        // Wait for any currently executing GPU work to finish and drain command buffers
        waitForIdle()
    }
    
    func resumeFromBackground() {
        backgroundState.isPaused = false
    }
    
    func setCancelled(_ cancelled: Bool) {
        self.isCancelled = cancelled
    }
    
    init(modelPath: URL, voicesPath: URL, language: KokoroSwift.Language) throws {
        self.tts = KokoroTTS(modelPath: modelPath, g2p: .misaki)
        let voicesArrays = try MLX.loadArrays(url: voicesPath)
        guard let heartVoice = voicesArrays["af_heart.npy"] ?? voicesArrays["af_heart"] else {
            throw NSError(domain: "KokoroTTS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not find af_heart voice in voices.npz"])
        }
        self.voiceEmbedding = heartVoice
        self.language = language
        


    }
    
    func generateAudio(text: String) throws -> [Float] {
        let result = try tts.generateAudio(voice: voiceEmbedding, language: language, text: text)
        return result.0
    }
    

    func generateSingleChunk(
        chunkText: String,
        chunkRange: Range<String.Index>,
        fullText: String,
        currentTimeOffset: TimeInterval,
        format: AVAudioFormat,
        settings: [String: Any]
    ) async throws -> AudioChunk {
        
        let trimmedText = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        
        if trimmedText.isEmpty {
            return AudioChunk(fileURL: tempURL, duration: 0, timestamps: [])
        }
        
        let trimmedRange = chunkText.range(of: trimmedText)!
        let distanceStartOffset = chunkText.distance(from: chunkText.startIndex, to: trimmedRange.lowerBound)
        
        let normalizedText = trimmedText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        
        // Wait atomically before dispatching to Metal to avoid background SIGABRT
        while true {
            if self.isCancelled { break }
            if backgroundState.tryStartExecuting() {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        defer {
            backgroundState.stopExecuting()
        }
        
        if self.isCancelled {
            throw NSError(domain: "KokoroTTS", code: 6, userInfo: [NSLocalizedDescriptionKey: "Audio generation cancelled."])
        }
        
        var chunkDuration: TimeInterval = 0
        var chunkTimestamps: [WordTimestamp] = []
        
        let ttsEngine = self.tts
        let voice = self.voiceEmbedding
        let lang = self.language
        
        try autoreleasepool {
            var result: ([Float], [MToken]?)?
            var attempt = 0
            while attempt < 3 {
                do {
                    result = try ttsEngine.generateAudio(voice: voice, language: lang, text: normalizedText)
                    break
                } catch {
                    attempt += 1
                    if attempt >= 3 {
                        throw error
                    }
                }
            }
            guard let finalResult = result else { 
                throw NSError(domain: "KokoroTTS", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to generate audio"])
            }
            let audioFloats = finalResult.0
            
            if let tokens = finalResult.1 {
                for token in tokens {
                    if let start = token.start_ts, let end = token.end_ts, !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let tokenDistanceStart = normalizedText.distance(from: normalizedText.startIndex, to: token.tokenRange.lowerBound)
                        let tokenDistanceEnd = normalizedText.distance(from: normalizedText.startIndex, to: token.tokenRange.upperBound)
                        
                        let globalStart = fullText.index(chunkRange.lowerBound, offsetBy: distanceStartOffset + tokenDistanceStart, limitedBy: fullText.endIndex) ?? chunkRange.lowerBound
                        let globalEnd = fullText.index(globalStart, offsetBy: tokenDistanceEnd - tokenDistanceStart, limitedBy: fullText.endIndex) ?? globalStart
                        let nsRange = NSRange(globalStart..<globalEnd, in: fullText)
                        
                        chunkTimestamps.append(WordTimestamp(
                            word: token.text,
                            startTime: currentTimeOffset + start,
                            endTime: currentTimeOffset + end,
                            rangeLocation: nsRange.location,
                            rangeLength: nsRange.length
                        ))
                    }
                }
            }
            
            var startIndex = 0
            var endIndex = audioFloats.count
            let threshold: Float = 0.005 // Aggressive trim threshold
            
            // Trim leading silence
            while startIndex < endIndex && abs(audioFloats[startIndex]) < threshold {
                startIndex += 1
            }
            // keep 10ms (240 samples) safety padding at start
            startIndex = max(0, startIndex - 240)
            
            // Trim trailing silence
            while endIndex > startIndex && abs(audioFloats[endIndex - 1]) < threshold {
                endIndex -= 1
            }
            // keep 10ms (240 samples) safety padding at end
            endIndex = min(audioFloats.count, endIndex + 240)
            
            let trimmedFloats = Array(audioFloats[startIndex..<endIndex])
            
            // Adjust word timestamps within the chunk based on leading trim
            let trimOffset = Double(startIndex) / 24000.0
            for i in 0..<chunkTimestamps.count {
                chunkTimestamps[i].startTime = max(0, chunkTimestamps[i].startTime - trimOffset)
                chunkTimestamps[i].endTime = max(0, chunkTimestamps[i].endTime - trimOffset)
            }
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimmedFloats.count)) else { 
                throw NSError(domain: "KokoroTTS", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
            }
            buffer.frameLength = buffer.frameCapacity
            let channels = buffer.floatChannelData!
            
            trimmedFloats.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                UnsafeMutableRawPointer(channels[0]).copyMemory(from: UnsafeRawPointer(baseAddress), byteCount: ptr.count * MemoryLayout<Float>.stride)
            }
            
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try audioFile.write(from: buffer)
            
            let sampleRate = Double(KokoroTTS.Constants.samplingRate)
            chunkDuration = TimeInterval(trimmedFloats.count) / sampleRate
            
            MLX.Memory.clearCache()
        }
        
        return AudioChunk(fileURL: tempURL, duration: chunkDuration, timestamps: chunkTimestamps)
    }
    func synthesizeToFile(text: String, fileURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> [WordTimestamp] {
        isCancelled = false
        isGenerating = true
        defer { isGenerating = false }
        
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        var sentences: [(String, Range<String.Index>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            sentences.append((String(text[tokenRange]), tokenRange))
            return true
        }
        
        if sentences.isEmpty {
            sentences = [(text, text.startIndex..<text.endIndex)]
        }
        
        var chunks: [(text: String, range: Range<String.Index>)] = []
        var currentChunkStart: String.Index?
        var currentChunkEnd: String.Index?
        var currentChunkLength = 0
        
        func appendCurrentChunk() {
            if let start = currentChunkStart, let end = currentChunkEnd, start < end {
                let range = start..<end
                chunks.append((String(text[range]), range))
            }
            currentChunkStart = nil
            currentChunkEnd = nil
            currentChunkLength = 0
        }
        
        for (sentenceText, sentenceRange) in sentences {
            if sentenceText.count > 350 {
                appendCurrentChunk()
                
                var scanStart = sentenceRange.lowerBound
                while scanStart < sentenceRange.upperBound {
                    let remaining = text.distance(from: scanStart, to: sentenceRange.upperBound)
                    let chunkLen = min(remaining, 350)
                    let idealEnd = text.index(scanStart, offsetBy: chunkLen)
                    
                    var splitEnd = idealEnd
                    if chunkLen == 350 {
                        var tempEnd = idealEnd
                        while tempEnd > scanStart, text[tempEnd] != " ", text[tempEnd] != "\n" {
                            tempEnd = text.index(before: tempEnd)
                        }
                        if tempEnd > scanStart {
                            splitEnd = tempEnd
                        }
                    }
                    
                    let range = scanStart..<splitEnd
                    chunks.append((String(text[range]), range))
                    scanStart = splitEnd
                    if scanStart < sentenceRange.upperBound, text[scanStart] == " " || text[scanStart] == "\n" {
                        scanStart = text.index(after: scanStart)
                    }
                }
                continue
            }
            
            if currentChunkLength + sentenceText.count > 350 && currentChunkLength > 0 {
                appendCurrentChunk()
            }
            
            if currentChunkStart == nil { currentChunkStart = sentenceRange.lowerBound }
            currentChunkEnd = sentenceRange.upperBound
            currentChunkLength += sentenceText.count
        }
        appendCurrentChunk()
        
        var allTimestamps: [WordTimestamp] = []
        var currentTimeOffset: TimeInterval = 0
        
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "KokoroTTS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        var audioFile: AVAudioFile? = try AVAudioFile(forWriting: tempURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)        
        for (index, chunk) in chunks.enumerated() {
            Log.tts.info("Generating chunk \(index + 1)/\(chunks.count)...")
            progress(index + 1, chunks.count)
            if isCancelled || Task.isCancelled {
                audioFile = nil
                throw NSError(domain: "KokoroTTS", code: 6, userInfo: [NSLocalizedDescriptionKey: "Audio generation cancelled."])
            }
            guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            
            try autoreleasepool {
                let result = try tts.generateAudio(voice: voiceEmbedding, language: language, text: chunk.text)
                let audioFloats = result.0
                
                if let tokens = result.1 {
                    for token in tokens {
                        if let start = token.start_ts, let end = token.end_ts, !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            
                            // Calculate range relative to the entire document
                            // token.tokenRange is relative to `chunk.text`.
                            let distanceStart = chunk.text.distance(from: chunk.text.startIndex, to: token.tokenRange.lowerBound)
                            let distanceEnd = chunk.text.distance(from: chunk.text.startIndex, to: token.tokenRange.upperBound)
                            
                            let globalStart = text.index(chunk.range.lowerBound, offsetBy: distanceStart, limitedBy: text.endIndex) ?? chunk.range.lowerBound
                            let globalEnd = text.index(globalStart, offsetBy: distanceEnd - distanceStart, limitedBy: text.endIndex) ?? globalStart
                            
                            // Convert to NSRange logic (UTF-16 offset) for easy NSAttributedString highlighting later
                            let nsRange = NSRange(globalStart..<globalEnd, in: text)
                            
                            allTimestamps.append(WordTimestamp(
                                word: token.text,
                                startTime: currentTimeOffset + start,
                                endTime: currentTimeOffset + end,
                                rangeLocation: nsRange.location,
                                rangeLength: nsRange.length
                            ))
                        }
                    }
                }
                
                var startIndex = 0
                var endIndex = audioFloats.count
                let threshold: Float = 0.005 // Aggressive trim threshold
                
                // Trim leading silence
                while startIndex < endIndex && abs(audioFloats[startIndex]) < threshold {
                    startIndex += 1
                }
                startIndex = max(0, startIndex - 240) // keep 10ms safety padding
                
                // Trim trailing silence
                while endIndex > startIndex && abs(audioFloats[endIndex - 1]) < threshold {
                    endIndex -= 1
                }
                endIndex = min(audioFloats.count, endIndex + 240) // keep 10ms safety padding
                
                let trimmedFloats = Array(audioFloats[startIndex..<endIndex])
                
                // Adjust timestamps for the words in THIS chunk only
                let trimOffset = Double(startIndex) / 24000.0
                for i in (0..<allTimestamps.count).reversed() {
                    if allTimestamps[i].startTime >= currentTimeOffset {
                        allTimestamps[i].startTime = max(currentTimeOffset, allTimestamps[i].startTime - trimOffset)
                        allTimestamps[i].endTime = max(currentTimeOffset, allTimestamps[i].endTime - trimOffset)
                    } else {
                        break // We've reached the previous chunk's timestamps
                    }
                }
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimmedFloats.count)) else { return }
                buffer.frameLength = buffer.frameCapacity
                let channels = buffer.floatChannelData!
                
                trimmedFloats.withUnsafeBufferPointer { ptr in
                    guard let baseAddress = ptr.baseAddress else { return }
                    UnsafeMutableRawPointer(channels[0]).copyMemory(from: UnsafeRawPointer(baseAddress), byteCount: ptr.count * MemoryLayout<Float>.stride)
                }
                
                try audioFile?.write(from: buffer)
                currentTimeOffset += TimeInterval(trimmedFloats.count) / sampleRate
                
                // Aggressively clear cache after each chunk to prevent Metal OOM
                MLX.Memory.clearCache()
            }
            
            // Yield to the Swift Concurrency scheduler to prevent thread starvation and reduce thermal throttling
            await Task.yield()
        }
        
        // Force the file to close so AVFoundation writes the MP4 header (duration/size) BEFORE moving it
        audioFile = nil
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        
        return allTimestamps
    }
}

public class AudioChunkGenerator {
    private let text: String
    private let engineActor: KokoroEngineActor
    private var chunks: [(text: String, range: Range<String.Index>)] = []
    private var currentIndex: Int = 0
    private var currentTimeOffset: TimeInterval = 0
    private let format: AVAudioFormat
    private let settings: [String: Any]
    
    init(text: String, engineActor: KokoroEngineActor) throws {
        self.text = text
        self.engineActor = engineActor
        
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        var sentences: [(String, Range<String.Index>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            sentences.append((String(text[tokenRange]), tokenRange))
            return true
        }
        
        if sentences.isEmpty {
            sentences = [(text, text.startIndex..<text.endIndex)]
        }
        
        var localChunks: [(text: String, range: Range<String.Index>)] = []
        var currentChunkStart: String.Index?
        var currentChunkEnd: String.Index?
        var currentChunkLength = 0
        
        func appendCurrentChunk() {
            if let start = currentChunkStart, let end = currentChunkEnd, start < end {
                let range = start..<end
                localChunks.append((String(text[range]), range))
            }
            currentChunkStart = nil
            currentChunkEnd = nil
            currentChunkLength = 0
        }
        
        var isFirstChunk = true
        
        for (sentenceText, sentenceRange) in sentences {
            let currentLimit = isFirstChunk ? 100 : 350
            
            if sentenceText.count > currentLimit {
                appendCurrentChunk()
                
                var scanStart = sentenceRange.lowerBound
                while scanStart < sentenceRange.upperBound {
                    let activeLimit = isFirstChunk ? 100 : 350
                    let remaining = text.distance(from: scanStart, to: sentenceRange.upperBound)
                    let chunkLen = min(remaining, activeLimit)
                    let idealEnd = text.index(scanStart, offsetBy: chunkLen)
                    
                    var splitEnd = idealEnd
                    if chunkLen == activeLimit {
                        var tempEnd = idealEnd
                        while tempEnd > scanStart, text[tempEnd] != " ", text[tempEnd] != "\n" {
                            tempEnd = text.index(before: tempEnd)
                        }
                        if tempEnd > scanStart {
                            splitEnd = tempEnd
                        }
                    }
                    
                    let range = scanStart..<splitEnd
                    localChunks.append((String(text[range]), range))
                    isFirstChunk = false
                    
                    scanStart = splitEnd
                    if scanStart < sentenceRange.upperBound, text[scanStart] == " " || text[scanStart] == "\n" {
                        scanStart = text.index(after: scanStart)
                    }
                }
                continue
            }
            
            if currentChunkLength + sentenceText.count > currentLimit && currentChunkLength > 0 {
                appendCurrentChunk()
                isFirstChunk = false
            }
            
            if currentChunkStart == nil { currentChunkStart = sentenceRange.lowerBound }
            currentChunkEnd = sentenceRange.upperBound
            currentChunkLength += sentenceText.count
        }
        appendCurrentChunk()
        self.chunks = localChunks
        
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "KokoroTTS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        self.format = format
        self.settings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
    
    public func nextChunk() async throws -> AudioChunk? {
        if currentIndex >= chunks.count { return nil }
        let chunk = chunks[currentIndex]
        currentIndex += 1
        
        guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await nextChunk() // skip empty and recurse
        }
        
        let resultChunk = try await engineActor.generateSingleChunk(
            chunkText: chunk.text,
            chunkRange: chunk.range,
            fullText: self.text,
            currentTimeOffset: self.currentTimeOffset,
            format: self.format,
            settings: self.settings
        )
        
        self.currentTimeOffset += resultChunk.duration
        return resultChunk
    }

}

@MainActor
class KokoroTTSService: ObservableObject {
    static let shared = KokoroTTSService()
    
    private var engineActor: KokoroEngineActor?
    
    // Used safely from main thread to bypass MainActor isolation for detached tasks
    func getEngineActorSync() -> KokoroEngineActor? {
        return self.engineActor
    }
    
    /// Synchronously waits for any active chunk generation to finish, then drains GPU buffers.
    /// Call from willResignActiveNotification to ensure no Metal work is pending
    /// before iOS revokes background GPU access. Safe to call from main thread.
    func waitForGPUIdleSync() {
        guard let state = getEngineActorSync()?.backgroundState else { return }
        
        // Wait until the current chunk finishes generating (with a 3.5s timeout to prevent iOS watchdog kill)
        let timeout = Date().addingTimeInterval(3.5)
        while state.isExecuting {
            if Date() > timeout {
                Log.tts.error("Warning: MLX evaluation did not finish in time for background transition.")
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        // Now that no new commands are being submitted, drain all in-flight Metal command buffers
        MLX.Stream.defaultStream(.gpu).synchronize()
    }
    
    private lazy var audioEngine: AVAudioEngine = {
        let engine = AVAudioEngine()
        engine.attach(playerNode)
        return engine
    }()
    private lazy var playerNode = AVAudioPlayerNode()
    
    private var modelLoadingTask: Task<Void, Error>?
    
    @Published var isModelLoaded = false
    @Published var isPlaying = false
    
    // Hardcoded to English for now
    let language: KokoroSwift.Language = .enUS
    
    private init() {
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            Log.tts.error("Failed to set up AVAudioSession: \(error.localizedDescription, privacy: .public)")
        }
        
        // Background handling is centralized in AudioGenerationManager, which
        // pauses generation (isPausedForBackground) on willResignActive and
        // resumes on didBecomeActive. We do NOT cancel here — cancelling would
        // set isCancelled on the engine actor with no corresponding reset,
        // making generation unresumable after a background round-trip.
        // Explicit user-initiated cancellation goes through
        // AudioGenerationManager.cancelCurrentGeneration() instead.
    }
    
    func cancelGeneration() async {
        await engineActor?.setCancelled(true)
    }
    
    func waitForGPUIdle() async {
        await engineActor?.waitForIdle()
    }
    
    func pauseEngine() async {
        await engineActor?.pauseForBackground()
    }
    
    func resumeEngine() async {
        await engineActor?.resumeFromBackground()
    }
    
    func resetCancellation() async {
        await engineActor?.setCancelled(false)
    }
    
    func loadModel() async throws {
        if isModelLoaded { return }
        
        if let existingTask = modelLoadingTask {
            try await existingTask.value
            return
        }
        
        let loadingTask = Task { @MainActor in
            // Enforce a strict 64MB GPU cache limit. Without this, iOS will kill the app (OOM)
            MLX.Memory.cacheLimit = 64 * 1024 * 1024
            
            let bundle = Bundle.main
            
            guard let modelPath = bundle.url(forResource: "kokoro-v1_0", withExtension: "safetensors") else {
                throw NSError(domain: "KokoroTTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find kokoro-v1_0.safetensors in app bundle"])
            }
            
            guard let voicesPath = bundle.url(forResource: "voices", withExtension: "safetensors") else {
                throw NSError(domain: "KokoroTTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find voices.safetensors in app bundle"])
            }
            
            // Initialize everything inside a detached background task to prevent freezing the Main Thread
            self.engineActor = try await Task.detached { [language = self.language] in
                try KokoroEngineActor(modelPath: modelPath, voicesPath: voicesPath, language: language)
            }.value
            
            self.isModelLoaded = true
        }
        
        self.modelLoadingTask = loadingTask
        
        do {
            try await loadingTask.value
            self.modelLoadingTask = nil
        } catch {
            self.modelLoadingTask = nil
            throw error
        }
    }
    
    func synthesize(document: Document, progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }) async throws {
        if !isModelLoaded {
            try await loadModel()
        }
        
        guard let engineActor = engineActor else {
            throw NSError(domain: "KokoroTTS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        let fileURL = StorageManager.shared.audioCacheURL.appendingPathComponent("\(document.id.uuidString).m4a")
        
        // Return if it's already generated
        if document.audioFileURL != nil {
            return
        }
        
        let timestamps = try await engineActor.synthesizeToFile(text: document.bodyText, fileURL: fileURL, progress: progress)
        
        document.decodedWordTimestamps = timestamps
    }
    

    func synthesizeGenerator(document: Document) async throws -> AudioChunkGenerator {
        if !self.isModelLoaded {
            try await self.loadModel()
        }
        
        guard let engineActor = self.engineActor else {
            throw NSError(domain: "KokoroTTS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        // Reset cancellation state from any previous session before starting
        await engineActor.setCancelled(false)
        
        return try AudioChunkGenerator(text: document.bodyText, engineActor: engineActor)
    }

    func playText(_ text: String) async throws {
        if !isModelLoaded {
            try await loadModel()
        }
        
        guard let engineActor = engineActor else {
            throw NSError(domain: "KokoroTTS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        isPlaying = true
        
        // Generate audio on the background actor
        let audioFloatArray = try await engineActor.generateAudio(text: text)

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFloatArray.count)) else {
            self.isPlaying = false
            return
        }
        
        buffer.frameLength = buffer.frameCapacity
        let channels = buffer.floatChannelData!
        
        audioFloatArray.withUnsafeBufferPointer { buf in
            guard let baseAddress = buf.baseAddress else { return }
            let byteCount = buf.count * MemoryLayout<Float>.stride
            UnsafeMutableRawPointer(channels[0]).copyMemory(from: UnsafeRawPointer(baseAddress), byteCount: byteCount)
        }
        
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
        
        playerNode.play()
    }
}
