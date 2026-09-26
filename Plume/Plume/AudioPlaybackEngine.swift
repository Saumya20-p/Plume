import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

public struct PlayedChunk {
    let identity: PlaybackQueueItemIdentity
    public let url: URL
    public let duration: TimeInterval
    public let globalStartTime: TimeInterval
    public let timestamps: [WordTimestamp]

    init(chunk: AudioChunk, globalStartTime: TimeInterval) {
        self.identity = .generated(chunk.identity)
        self.url = chunk.fileURL
        self.duration = chunk.duration
        self.globalStartTime = globalStartTime
        self.timestamps = chunk.timestamps
    }

    init(
        legacyDocumentID: UUID,
        url: URL,
        duration: TimeInterval,
        globalStartTime: TimeInterval,
        timestamps: [WordTimestamp]
    ) {
        self.identity = .legacy(documentID: legacyDocumentID)
        self.url = url
        self.duration = duration
        self.globalStartTime = globalStartTime
        self.timestamps = timestamps
    }
}

@MainActor
public class PlaybackProgress: ObservableObject {
    public static let shared = PlaybackProgress()
    
    @Published public var currentTime: TimeInterval = 0
    @Published public var currentWord: WordTimestamp? = nil
    
    private init() {}
}

@MainActor
public class AudioPlaybackEngine: ObservableObject {
    public static let shared = AudioPlaybackEngine()
    public let progress = PlaybackProgress.shared
    
    let coordinator = PlaybackRoutingCoordinator()
    
    public var isAppleActive: Bool {
        coordinator.isAppleActive
    }
    
    var currentSnapshot: PlaybackSessionSnapshot? {
        coordinator.snapshot
    }
    
    private let prewarmSynthesizer = AVSpeechSynthesizer()
    private var queuePlayer: AVQueuePlayer?
    private var playerTimeControlCancellable: AnyCancellable?
    
    public var chunks: [PlayedChunk] = []
    public var virtualBaseOffset: TimeInterval = 0
    private var seekDebounceTimer: Timer?
    private var timeObserverToken: Any?
    private var endObserverToken: Any?
    private var interruptionObserverToken: Any?
    private var routeChangeObserverToken: Any?
    private var didEnterBackgroundObserverToken: Any?
    private var willEnterForegroundObserverToken: Any?
    private var userDefaultsObserverToken: Any?
    private var mediaServicesLostObserverToken: Any?
    private var mediaServicesResetObserverToken: Any?
    private var userDefaultsDebounceTimer: Timer?
    private var wasPlayingBeforeInterruption: Bool = false
    private var wasSuspendedBeforeInterruption: Bool = false
    private var wasPlayingBeforeMediaServicesLoss: Bool = false
    private var lastProgressSaveTime: TimeInterval = 0
    private var wallClockSessionStartTime: TimeInterval?
    private var currentSeekTask: Task<Void, Never>? = nil
    private var generationGate = PlaybackGenerationGate()
    
    @Published public var basePlaybackSpeed: Float {
        didSet {
            UserDefaults.standard.set(Double(basePlaybackSpeed), forKey: "defaultPlaybackSpeed")
            Task { @MainActor [weak self] in self?.updateEffectivePlaybackRate() }
        }
    }
    
    private var autoIncreaseSpeedEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoIncreaseSpeedEnabled")
    }
    
    private var defaultSkipInterval: TimeInterval {
        let interval = UserDefaults.standard.integer(forKey: "defaultSkipInterval")
        return interval == 0 ? 15.0 : TimeInterval(interval)
    }
    
    @Published public var isPlaying: Bool = false
    
    public var currentTime: TimeInterval {
        get { progress.currentTime }
        set { progress.currentTime = newValue }
    }
    
    public var currentWord: WordTimestamp? {
        get { progress.currentWord }
        set { progress.currentWord = newValue }
    }
    
    @Published public var duration: TimeInterval = 0
    
    public var bufferedTime: TimeInterval {
        chunks.last.map { $0.globalStartTime + $0.duration } ?? virtualBaseOffset
    }
    
    @Published public var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying {
                queuePlayer?.rate = playbackRate
            }
            updateNowPlayingPlaybackInfo()
        }
    }
    
    @Published var currentDocument: Document?
    @Published var isPlayerViewPresented: Bool = false
    @Published public var presentedPlayerDocument: Document? = nil
    public var isGenerationActive: Bool = false
    private var isRecoveringFromUnderrun: Bool = false
    
    func finishGeneration(sessionID: UUID) {
        guard generationGate.isActive(sessionID: sessionID) else {
            return
        }

        isGenerationActive = false
        if chunks.isEmpty && !coordinator.isAppleActive {
            self.pause()
        }
        if isRecoveringFromUnderrun && isPlaying && !coordinator.isAppleActive {
            isRecoveringFromUnderrun = false
            queuePlayer?.play()
            queuePlayer?.rate = playbackRate
        }
        generationGate.invalidate()
        evaluateAudioSession()
    }
    
    private init() {
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        self.basePlaybackSpeed = savedSpeed == 0 ? 1.0 : Float(savedSpeed)
        self.playbackRate = self.basePlaybackSpeed
        
        queuePlayer = AVQueuePlayer()
        queuePlayer?.automaticallyWaitsToMinimizeStalling = false
        setupPlayerObservers()
        
        coordinator.playbackEngine = self
        setupRemoteCommandCenter()
        setupAudioSessionObservers()
        setupCoordinatorCallbacks()
        
        userDefaultsObserverToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.userDefaultsDebounceTimer?.invalidate()
            self.userDefaultsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in 
                    guard let self = self else { return }
                    self.updateEffectivePlaybackRate()
                    
                    let preferences = VoicePreferencesStore().load()
                    self.coordinator.updateVoicePreferences(preferences)
                }
            }
        }
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            let utterance = AVSpeechUtterance(string: " ")
            utterance.volume = 0
            self?.prewarmSynthesizer.speak(utterance)
        }
    }

    deinit {
        playerTimeControlCancellable?.cancel()
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = interruptionObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = routeChangeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = didEnterBackgroundObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = willEnterForegroundObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = userDefaultsObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = mediaServicesLostObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = mediaServicesResetObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    private func setupCoordinatorCallbacks() {
        coordinator.onProgress = { [weak self] time, word in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time
                self.currentWord = word
                
                if let doc = self.currentDocument, let context = doc.modelContext {
                    if self.duration > 0 && abs(self.currentTime - self.lastProgressSaveTime) > 5.0 {
                        if doc.progress < 1.0 {
                            doc.progress = self.currentTime / self.duration
                        }
                        doc.lastReadCharIndex = word?.rangeLocation ?? doc.lastReadCharIndex
                        self.lastProgressSaveTime = self.currentTime
                        try? context.save()
                    }
                }
                self.updateNowPlayingPlaybackInfo()
            }
        }

        coordinator.onCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let completedDuration = self.duration > 0 ? self.duration : (self.currentDocument?.estimatedDuration ?? self.currentTime)
                self.currentTime = completedDuration
                if let doc = self.currentDocument {
                    doc.progress = 1.0
                    doc.lastReadCharIndex = doc.bodyText.utf16.count
                    if let context = doc.modelContext {
                        try? context.save()
                    }
                }
                self.pause()
                Task {
                    PlaybackCoordinator.shared.advanceNext()
                }
            }
        }

        coordinator.onPerformHandback = { [weak self] chunks, _ in
            Task { @MainActor [weak self] in
                self?.resumeFromHandback(chunks: chunks, session: nil)
            }
        }
    }
    
    @MainActor
    public func updateEffectivePlaybackRate() {
        let newRate = min(3.0, basePlaybackSpeed)
        if abs(playbackRate - newRate) > 0.01 {
            playbackRate = newRate
            if coordinator.isAppleActive {
                coordinator.setSpeechRateMultiplier(newRate)
            }
        }
    }
    
    @discardableResult
    public func enqueue(chunk: AudioChunk) -> Bool {
        guard generationGate.accepts(
            chunk.identity,
            currentDocumentID: currentDocument?.id
        ) else {
            return false
        }

        let exactDuration = chunk.duration
        let globalStart = chunks.last.map { $0.globalStartTime + $0.duration } ?? virtualBaseOffset
        let playedChunk = PlayedChunk(chunk: chunk, globalStartTime: globalStart)
        chunks.append(playedChunk)
        
        let newItem = AVPlayerItem(url: chunk.fileURL)
        queuePlayer?.insert(newItem, after: nil)
        
        if isPlaying {
            if queuePlayer?.timeControlStatus != .playing {
                isRecoveringFromUnderrun = true
            }
            
            if isRecoveringFromUnderrun {
                if (queuePlayer?.items().count ?? 0) >= 2 {
                    isRecoveringFromUnderrun = false
                    queuePlayer?.play()
                    queuePlayer?.rate = playbackRate
                }
            } else {
                queuePlayer?.play()
                queuePlayer?.rate = playbackRate
            }
        }
        
        duration += exactDuration
        updateNowPlayingPlaybackInfo()
        return true
    }
    
    public func load(document: Document) {
        load(document: document, generationSession: nil)
    }

    func beginGenerationSession(_ session: PlaybackGenerationSession) {
        generationGate.activate(session)
        isGenerationActive = true
    }

    func load(document: Document, generationSession: PlaybackGenerationSession?) {
        cancelSpeculativeHandback()
        if let generationSession {
            generationGate.activate(generationSession)
        } else {
            generationGate.invalidate()
        }
        isGenerationActive = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Log.audio.error("Failed to set audio session category: \(error.localizedDescription, privacy: .public)")
        }
        
        removeTimeObserver()
        removeEndObserver()
        
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = AVQueuePlayer()
        queuePlayer?.automaticallyWaitsToMinimizeStalling = false
        
        setupTimeObserver()
        setupEndObserver()
        setupPlayerObservers()
        
        chunks = []
        currentTime = 0
        duration = 0
        virtualBaseOffset = 0
        currentWord = nil
        
        self.currentDocument = document
        
        // Initialize coordinator session
        let preferences = VoicePreferencesStore().load()
        let snapshot = PlaybackSessionSnapshot(documentID: document.id, preferences: preferences)
        let resumeCursor = document.lastReadCharIndex > 0 ? PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: document.lastReadCharIndex) : nil
        _ = coordinator.begin(
            document: document,
            snapshot: snapshot,
            resumeCursor: resumeCursor,
            speechRateMultiplier: playbackRate
        )
        
        if coordinator.isAppleActive {
            self.duration = document.estimatedDuration
            self.currentTime = coordinator.estimatedCurrentTime
            self.isGenerationActive = false
            setupNowPlaying()
            return
        }
        
        if let legacyURL = document.audioFileURL {
            let duration = (try? AVAudioPlayer(contentsOf: legacyURL).duration) ?? document.estimatedDuration
            let chunk = PlayedChunk(
                legacyDocumentID: document.id,
                url: legacyURL,
                duration: duration,
                globalStartTime: 0,
                timestamps: document.decodedWordTimestamps
            )
            self.chunks.append(chunk)
            self.duration = duration
            self.queuePlayer?.insert(AVPlayerItem(url: legacyURL), after: nil)
        }
        
        setupNowPlaying()
    }

    public func play() {
        if coordinator.isAppleActive {
            if coordinator.play() {
                wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                isPlaying = true
                updateNowPlayingPlaybackInfo()
            }
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.audio.error("Failed to activate audio session: \(error.localizedDescription, privacy: .public)")
        }
        _ = coordinator.play()
        isRecoveringFromUnderrun = false
        queuePlayer?.play()
        queuePlayer?.rate = playbackRate
        isPlaying = true
        wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        updateNowPlayingPlaybackInfo()
    }
    
    public func pause(file: String = #file, line: Int = #line, function: String = #function) {
        Log.audio.info("pause called from \(function):\(line)")
        cancelSpeculativeHandback()
        queuePlayer?.pause()
        coordinator.pause()
        isRecoveringFromUnderrun = false
        isPlaying = false
        updateNowPlayingPlaybackInfo()
        recordListeningSession()
        saveDocumentProgress()
        evaluateAudioSession()
    }
    
    private func recordListeningSession() {
        if let startTime = wallClockSessionStartTime {
            let sessionDuration = Date().timeIntervalSinceReferenceDate - startTime
            if sessionDuration > 2.0, let doc = currentDocument, let context = doc.modelContext {
                let words = Int((sessionDuration / 60.0) * 150.0 * Double(playbackRate))
                let session = ListeningSession(
                    documentId: doc.id,
                    secondsListened: sessionDuration,
                    wordsListened: words,
                    playbackSpeed: Double(playbackRate)
                )
                context.insert(session)
                try? context.save()
            }
            wallClockSessionStartTime = nil
        }
    }

    private func saveDocumentProgress() {
        if let doc = currentDocument, duration > 0 {
            if doc.progress < 1.0 {
                doc.progress = currentTime / duration
            }
            doc.lastReadCharIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? doc.lastReadCharIndex
            lastProgressSaveTime = currentTime
            if let context = doc.modelContext {
                try? context.save()
            }
        }
    }
    
    public func clearMemory() {
        recordListeningSession()
        saveDocumentProgress()
        coordinator.cancel()
        generationGate.invalidate()
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        evaluateAudioSession()
    }
    
    public func evaluateAudioSession() {
        if !isPlaying && !isGenerationActive {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Log.audio.error("Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func resetAndSeek(to targetTime: TimeInterval) {
        cancelSpeculativeHandback()
        guard currentDocument != nil else { return }
        
        if coordinator.isAppleActive {
            seekDebounceTimer?.invalidate()
            seekDebounceTimer = nil
            performSeek(to: targetTime)
            play()
            return
        }
        
        // Force the engine to discard existing loaded audio chunks so that
        // performSeek doesn't just re-queue the old files and return early.
        self.chunks.removeAll()
        self.queuePlayer?.removeAllItems()
        
        self.seek(to: targetTime)
        
        // Don't call play() here, because seek(to:) will automatically handle resuming 
        // if wasPlaying was true, or we can force it inside performSeek.
        // Actually, performSeek does `if wasPlaying { self.isPlaying = true }`.
        // But since we just removed all items, wasPlaying is true, and it sets isPlaying=true.
        // And when the first chunk finishes generating, `enqueueChunk` will start it automatically!
        // We just need to ensure the UI says playing.
        self.isPlaying = true
    }
    
    public func seek(to targetTime: TimeInterval) {
        cancelSpeculativeHandback()
        seekDebounceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performSeek(to: targetTime)
            }
        }
        timer.tolerance = 0.025
        seekDebounceTimer = timer
    }

    private func performSeek(to targetTime: TimeInterval) {
        cancelSpeculativeHandback()
        recordListeningSession()
        saveDocumentProgress()
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        
        let totalDuration = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        let safeTargetTime = max(0, min(targetTime, totalDuration))
        
        if coordinator.isAppleActive {
            coordinator.seek(to: safeTargetTime)
            self.currentTime = safeTargetTime
            if isPlaying {
                wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                if UIApplication.shared.applicationState != .background {
                    triggerSpeculativeHandbackPreparation(for: doc)
                }
            }
            updateNowPlayingPlaybackInfo()
            return
        }
        
        let currentVirtualStartTime = chunks.first?.globalStartTime ?? virtualBaseOffset
        let currentVirtualEndTime = chunks.last.map { $0.globalStartTime + $0.duration } ?? virtualBaseOffset
        if safeTargetTime >= currentVirtualStartTime && safeTargetTime <= currentVirtualEndTime, !chunks.isEmpty {
            let wasPlaying = isPlaying
            queuePlayer?.pause()
            queuePlayer?.removeAllItems()
            var localSeekTime: TimeInterval = 0
            var foundStartChunk = false
            for chunk in chunks {
                if !foundStartChunk && safeTargetTime >= chunk.globalStartTime && safeTargetTime <= chunk.globalStartTime + chunk.duration {
                    foundStartChunk = true
                    localSeekTime = safeTargetTime - chunk.globalStartTime
                }
                if foundStartChunk {
                    queuePlayer?.insert(AVPlayerItem(url: chunk.url), after: nil)
                }
            }
            if let firstItem = queuePlayer?.items().first {
                currentSeekTask?.cancel()
                currentSeekTask = Task { @MainActor [weak self, weak firstItem] in
                    guard let self = self, let firstItem = firstItem else { return }
                    
                    // Wait for the item to load (local files load almost instantly)
                    while firstItem.status == .unknown {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    }
                    
                    if Task.isCancelled { return }
                    if firstItem.status == .readyToPlay {
                        firstItem.seek(to: CMTime(seconds: localSeekTime, preferredTimescale: 600), completionHandler: nil)
                        if self.isPlaying {
                            self.queuePlayer?.play()
                            self.queuePlayer?.rate = self.playbackRate
                            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                        }
                    }
                }
            } else {
                if wasPlaying {
                    queuePlayer?.play()
                    queuePlayer?.rate = playbackRate
                    self.isPlaying = true
                    self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                }
            }
            self.currentTime = safeTargetTime
            updateNowPlayingPlaybackInfo()
            return
        }
        
        let wasPlaying = isPlaying
        queuePlayer?.pause()
        
        // 1. Coordinate with AudioGenerationManager
        AudioGenerationManager.shared.cancelCurrentGeneration()
        
        // 2. Clear items and chunks
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        
        // 3. Set virtualBaseOffset
        virtualBaseOffset = safeTargetTime
        self.currentTime = safeTargetTime
        self.duration = safeTargetTime
        
        // 4. Calculate chunk index
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        var targetChunkIndex = 0
        if !segments.isEmpty {
            let progress = safeTargetTime / totalDuration
            targetChunkIndex = Int(progress * Double(segments.count))
            targetChunkIndex = max(0, min(targetChunkIndex, segments.count - 1))
        }
        
        // 5. Generate
        isGenerationActive = true
        AudioGenerationManager.shared.generate(document: doc, playbackEngine: self, startChunkIndex: targetChunkIndex)
        
        updateNowPlayingPlaybackInfo()
        
        if wasPlaying {
            // It will resume automatically when enqueue is called in AudioGenerationManager if isFirst is handled correctly.
            // But we can also set isPlaying to true so UI knows it's playing
            self.isPlaying = true
            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        }
    }

    public func seek(toCharIndex charIndex: Int) {
        cancelSpeculativeHandback()
        seekDebounceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performSeek(toCharIndex: charIndex)
            }
        }
        timer.tolerance = 0.025
        seekDebounceTimer = timer
    }
    
    private func performSeek(toCharIndex charIndex: Int) {
        cancelSpeculativeHandback()
        recordListeningSession()
        saveDocumentProgress()
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        coordinator.syncCursor(toUTF16Offset: charIndex)
        
        if coordinator.isAppleActive {
            coordinator.seek(toUTF16Offset: charIndex)
            self.currentTime = coordinator.estimatedCurrentTime
            if isPlaying {
                wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                if UIApplication.shared.applicationState != .background {
                    triggerSpeculativeHandbackPreparation(for: doc)
                }
            }
            updateNowPlayingPlaybackInfo()
            return
        }
        
        var matchedChunkTime: TimeInterval? = nil
        for chunk in chunks {
            for ts in chunk.timestamps {
                if let loc = ts.rangeLocation, let len = ts.rangeLength {
                    if charIndex >= loc && charIndex <= (loc + len) {
                        matchedChunkTime = chunk.globalStartTime + ts.startTime
                        break
                    }
                }
            }
            if matchedChunkTime != nil { break }
        }
        if let time = matchedChunkTime {
            performSeek(to: time)
            return
        }
        
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        guard !segments.isEmpty else { return }
        
        var targetChunkIndex = segments.count - 1
        for (index, chunk) in segments.enumerated() {
            let start = chunk.range.lowerBound.utf16Offset(in: doc.bodyText)
            let end = chunk.range.upperBound.utf16Offset(in: doc.bodyText)
            if charIndex < start {
                targetChunkIndex = max(0, index - 1)
                break
            }
            if charIndex >= start && charIndex <= end {
                targetChunkIndex = index
                break
            }
        }
        
        for chunk in chunks {
            if case .generated(let identity) = chunk.identity,
               identity.segmentID.ordinal == targetChunkIndex {
                performSeek(to: chunk.globalStartTime)
                return
            }
        }
        
        let totalDuration = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        let safeTargetTime = totalDuration * (Double(targetChunkIndex) / Double(segments.count))
        
        let wasPlaying = isPlaying
        queuePlayer?.pause()
        
        AudioGenerationManager.shared.cancelCurrentGeneration()
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        
        virtualBaseOffset = safeTargetTime
        self.currentTime = safeTargetTime
        self.duration = safeTargetTime
        isRecoveringFromUnderrun = false
        
        isGenerationActive = true
        AudioGenerationManager.shared.generate(document: doc, playbackEngine: self, startChunkIndex: targetChunkIndex)
        
        updateNowPlayingPlaybackInfo()
        
        if wasPlaying {
            self.isPlaying = true
            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        }
    }

    public func skipForward() {
        seekDebounceTimer?.invalidate()
        seekDebounceTimer = nil
        performSeek(to: currentTime + defaultSkipInterval)
    }
    
    public func skipBackward() {
        seekDebounceTimer?.invalidate()
        seekDebounceTimer = nil
        performSeek(to: max(0, currentTime - defaultSkipInterval))
    }
    
    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = queuePlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Monitor Kokoro buffer runway for underrun
                if (self.isPlaying || self.coordinator.contract?.desiredPlayIntent == .playing) && !self.coordinator.isAppleActive {
                    self.checkKokoroBufferUnderrun()
                }

                // Determine global time by identifying the current playing chunk
                guard let currentItem = self.queuePlayer?.currentItem,
                      let currentURL = (currentItem.asset as? AVURLAsset)?.url,
                      let playingChunk = self.chunks.first(where: { $0.url.lastPathComponent == currentURL.lastPathComponent }) else {
                    return
                }
                
                let localPlayTime = time.seconds
                guard localPlayTime >= 0 else { return }
                
                let globalPlayTime = playingChunk.globalStartTime + localPlayTime
                self.currentTime = min(globalPlayTime, max(self.duration, self.currentDocument?.estimatedDuration ?? 0))
                
                let timestamps = playingChunk.timestamps
                if !timestamps.isEmpty {
                    var low = 0
                    var high = timestamps.count - 1
                    var ans: Int? = nil
                    
                    while low <= high {
                        let mid = (low + high) / 2
                        if timestamps[mid].startTime <= localPlayTime {
                            ans = mid
                            low = mid + 1
                        } else {
                            high = mid - 1
                        }
                    }
                    
                    if let foundIndex = ans {
                        let word = timestamps[foundIndex]
                        if localPlayTime <= word.endTime + 0.5 {
                            PlaybackProgress.shared.currentWord = word
                            if let loc = word.rangeLocation {
                                self.coordinator.advanceDisplay(toUTF16Offset: loc)
                            }
                        }
                    }
                }
                
                // Periodically save progress
                if let doc = self.currentDocument, let context = doc.modelContext {
                    if self.duration > 0 && abs(self.currentTime - self.lastProgressSaveTime) > 5.0 {
                        doc.progress = self.currentTime / self.duration
                        doc.lastReadCharIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? doc.lastReadCharIndex
                        self.lastProgressSaveTime = self.currentTime
                        try? context.save()
                    }
                    self.updateEffectivePlaybackRate()
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            queuePlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    private func removeEndObserver() {
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
    }
    
    private func removePlayerObservers() {
        playerTimeControlCancellable?.cancel()
        playerTimeControlCancellable = nil
    }

    private func setupPlayerObservers() {
        removePlayerObservers()
        guard let player = queuePlayer else { return }
        
        playerTimeControlCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard !self.coordinator.isAppleActive else { return }
                    
                    let playing = (status != .paused)
                    if self.isPlaying != playing {
                        self.isPlaying = playing
                        if playing {
                            if self.wallClockSessionStartTime == nil {
                                self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                            }
                        } else {
                            self.recordListeningSession()
                        }
                        self.updateNowPlayingPlaybackInfo()
                    }
                }
            }
    }
    
    private func setupEndObserver() {
        removeEndObserver()
        endObserverToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Identify the chunk that just finished and commit its boundary
                if let finishedItem = notification.object as? AVPlayerItem,
                   let finishedURL = (finishedItem.asset as? AVURLAsset)?.url,
                   let finishedChunk = self.chunks.first(where: { $0.url.lastPathComponent == finishedURL.lastPathComponent }) {
                    self.coordinator.commitChunkBoundary(finishedChunk)
                }

                // If there are no more items in the queue
                if (self.queuePlayer?.items().isEmpty ?? true) {
                    if self.hasReachedDocumentEnd {
                        self.pause()
                        
                        // Trigger auto-advance to next chapter in queue
                        Task {
                            PlaybackCoordinator.shared.advanceNext()
                        }
                    } else if (self.isPlaying || self.coordinator.contract?.desiredPlayIntent == .playing) && !self.coordinator.isAppleActive {
                        // Kokoro ran out of chunks before EOF: trigger fallback!
                        self.triggerFallbackToAppleSpeech(reason: "Kokoro audio buffer underrun (queue exhausted before EOF)")
                    }
                }
            }
        }
    }
    
    private func setupAudioSessionObservers() {
        interruptionObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    if #available(iOS 14.5, *) {
                        if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
                           let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
                            self.wasSuspendedBeforeInterruption = (reason == .appWasSuspended)
                        } else {
                            self.wasSuspendedBeforeInterruption = false
                        }
                    } else {
                        self.wasSuspendedBeforeInterruption = false
                    }
                    if self.coordinator.isAppleActive {
                        _ = self.coordinator.beginInterruption()
                        self.isPlaying = false
                        self.updateNowPlayingPlaybackInfo()
                        self.recordListeningSession()
                        self.saveDocumentProgress()
                    } else {
                        let wasPlaying = self.isPlaying
                        self.pause()
                        self.wasPlayingBeforeInterruption = wasPlaying
                    }
                case .ended:
                    var shouldResume: Bool = false
                    if let optionsValue = optionsValue {
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        shouldResume = options.contains(.shouldResume)
                    }
                    
                    if #available(iOS 14.5, *) {
                        if self.wasSuspendedBeforeInterruption {
                            shouldResume = true
                        }
                    }
                    
                    self.wasSuspendedBeforeInterruption = false
                    
                    shouldResume = shouldResume && self.wasPlayingBeforeInterruption
                    
                    if self.coordinator.isAppleActive {
                        if self.coordinator.endInterruption(shouldResume: shouldResume) {
                            self.isPlaying = shouldResume
                            if shouldResume {
                                self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                            }
                            self.updateNowPlayingPlaybackInfo()
                        }
                    } else {
                        if shouldResume {
                            self.play()
                        }
                    }
                    
                    if !shouldResume {
                        self.pause()
                    }
                @unknown default:
                    break
                }
            }
        }
        
        mediaServicesLostObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.wasPlayingBeforeMediaServicesLoss = self.isPlaying || (self.coordinator.contract?.desiredPlayIntent == .playing)
                self.pause()
            }
        }
        
        mediaServicesResetObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    Log.audio.error("Failed to reset audio session: \(error.localizedDescription, privacy: .public)")
                }
                
                let wasPlaying = self.wasPlayingBeforeMediaServicesLoss
                self.wasPlayingBeforeMediaServicesLoss = false
                
                if !self.coordinator.isAppleActive {
                    self.queuePlayer = AVQueuePlayer()
                    self.queuePlayer?.automaticallyWaitsToMinimizeStalling = false
                    self.setupTimeObserver()
                    self.setupEndObserver()
                    self.setupPlayerObservers()
                    
                    for chunk in self.chunks {
                        self.queuePlayer?.insert(AVPlayerItem(url: chunk.url), after: nil)
                    }
                    
                    if wasPlaying {
                        self.isPlaying = true
                        self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                    }
                    
                    self.seek(to: self.currentTime)
                } else {
                    self.coordinator.seek(to: self.currentTime)
                    if wasPlaying {
                        self.play()
                    }
                }
            }
        }
        
        routeChangeObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }
            
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if reason == .oldDeviceUnavailable {
                    self.pause()
                }
            }
        }

        didEnterBackgroundObserverToken = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cancelSpeculativeHandback()
                guard !self.coordinator.isAppleActive, self.currentDocument != nil else { return }
                Log.audio.info("Application entered background; triggering fallback from Kokoro to Apple Speech.")
                self.triggerFallbackToAppleSpeech(reason: "Application entered background")
            }
        }

        willEnterForegroundObserverToken = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await KokoroTTSService.shared.getEngineActorSync()?.setBackgroundPaused(false)
                self?.handleWillEnterForeground()
            }
        }
    }
    
    private func setupNowPlaying() {
        guard let doc = currentDocument else { return }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = doc.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Plume TTS"
        
        if let data = doc.coverImageData, let uiImage = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in return uiImage }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        updateNowPlayingPlaybackInfo()
    }
    
    private func updateNowPlayingPlaybackInfo() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        
        let isFullyGenerated = currentDocument?.audioFileURL != nil
        let displayDuration = isFullyGenerated ? duration : max(duration, currentDocument?.estimatedDuration ?? duration)
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = displayDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.play() }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.skipForward() }
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.skipBackward() }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    // MARK: - Fallback Routing

    public var isFallbackActive: Bool {
        coordinator.isFallbackActive
    }

    private var hasReachedDocumentEnd: Bool {
        guard let doc = currentDocument else { return true }
        if let committed = coordinator.contract?.committedCursor {
            return committed.globalUTF16Offset >= doc.bodyText.utf16.count
        }
        return currentTime >= (duration - 0.5) && !isGenerationActive
    }

    private func checkKokoroBufferUnderrun() {
        guard (isPlaying || coordinator.contract?.desiredPlayIntent == .playing), !coordinator.isAppleActive, currentDocument != nil else { return }
        
        let runway = bufferedTime - currentTime
        let itemsCount = queuePlayer?.items().count ?? 0
        let isStalled = queuePlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let hasDepletedRunway = !chunks.isEmpty && (itemsCount == 0 || (runway <= 0.1 && isStalled))
        
        if hasDepletedRunway && !hasReachedDocumentEnd {
            Log.audio.warning("Kokoro buffer underrun detected (runway: \(runway, privacy: .public)s, items: \(itemsCount)). Triggering fallback to Apple Speech.")
            triggerFallbackToAppleSpeech(reason: "Kokoro audio buffer underrun (runway: \(runway)s)")
        }
    }

    public func triggerFallbackToAppleSpeech(reason: String) {
        cancelSpeculativeHandback()
        guard !coordinator.isAppleActive, let doc = currentDocument else { return }
        
        Log.audio.warning("Triggering fallback to Apple Speech. Reason: \(reason, privacy: .public)")
        
        // 1. Synchronously check if the current playing chunk has reached or is near its end duration.
        // If so, commit its boundary immediately before canceling or clearing items to avoid repeating the chunk.
        if let currentItem = queuePlayer?.currentItem,
           let currentURL = (currentItem.asset as? AVURLAsset)?.url,
           let currentChunk = chunks.first(where: { $0.url.lastPathComponent == currentURL.lastPathComponent }) {
            let itemDuration = currentItem.duration.seconds
            let itemCurrentTime = currentItem.currentTime().seconds
            if !itemDuration.isNaN && itemDuration > 0 && itemCurrentTime >= (itemDuration - 0.25) {
                coordinator.commitChunkBoundary(currentChunk)
            }
        }

        // 2. Pause playback and cancel Kokoro generation tasks
        queuePlayer?.pause()
        AudioGenerationManager.shared.cancelCurrentGeneration()
        isGenerationActive = false
        isRecoveringFromUnderrun = false
        
        // 3. Adjust duration to full document duration if available
        if doc.estimatedDuration > 0 {
            self.duration = doc.estimatedDuration
        }
        
        // 4. Trigger handoff in coordinator while state and cursors are fully resolved
        let wasPlaying = self.isPlaying || (coordinator.contract?.desiredPlayIntent == .playing)
        let success = coordinator.triggerFallback(reason: reason)
        
        // 5. Defer removing Kokoro items and clearing chunks until after coordinator handoff
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        
        if success {
            self.currentTime = coordinator.estimatedCurrentTime
            if wasPlaying {
                self.isPlaying = true
                self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
            }
            updateNowPlayingPlaybackInfo()
        }
    }

    // MARK: - Speculative Foreground Handback (Phase 6)

    private func handleWillEnterForeground() {
        guard coordinator.isFallbackActive, let doc = currentDocument, (isPlaying || coordinator.contract?.desiredPlayIntent == .playing) else { return }
        Log.audio.info("Application returning to foreground during Apple Speech fallback; initiating speculative handback preparation.")
        triggerSpeculativeHandbackPreparation(for: doc)
    }

    func triggerSpeculativeHandbackPreparation(for doc: Document) {
        guard coordinator.isFallbackActive else { return }
        
        let targetSegmentIndex = coordinator.currentOrUpcomingSegmentIndex
        guard targetSegmentIndex < coordinator.segmentsCount else {
            Log.audio.info("Speculative handback: already at or past the end of document segments.")
            return
        }

        Log.audio.info("Starting speculative preparation for document \(doc.id) from segment \(targetSegmentIndex).")
        AudioGenerationManager.shared.startSpeculativePreparation(
            document: doc,
            playbackEngine: self,
            startChunkIndex: targetSegmentIndex
        )
    }

    func cancelSpeculativeHandback() {
        AudioGenerationManager.shared.cancelSpeculativePreparation()
        coordinator.cancelPendingHandback()
    }

    func resumeFromHandback(chunks: [AudioChunk], session: PlaybackGenerationSession?) {
        guard let doc = currentDocument, !chunks.isEmpty else { return }
        Log.audio.info("AudioPlaybackEngine resuming Kokoro playback from handback with \(chunks.count) chunk(s).")

        // 1. Activate session gate if provided
        if let session {
            generationGate.activate(session)
        }

        // 2. Tear down any residual Apple Speech playback and clear old Kokoro items
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        self.chunks.removeAll()

        // 3. Set the virtualBaseOffset to current progress or the start of the first chunk
        let currentEstimated = coordinator.estimatedCurrentTime
        self.virtualBaseOffset = currentEstimated
        self.currentTime = currentEstimated

        // 4. Transform AudioChunks into PlayedChunks and insert into queuePlayer
        var playedChunks: [PlayedChunk] = []
        var runningOffset = currentEstimated

        for chunk in chunks {
            let playedChunk = PlayedChunk(
                chunk: chunk,
                globalStartTime: runningOffset
            )
            playedChunks.append(playedChunk)
            runningOffset += chunk.duration
            queuePlayer?.insert(AVPlayerItem(url: chunk.fileURL), after: nil)
        }

        self.chunks = playedChunks
        self.duration = runningOffset

        // 5. Resume playback if desired
        let shouldPlay = self.isPlaying || (self.coordinator.contract?.desiredPlayIntent == .playing)
        isGenerationActive = true
        if shouldPlay {
            queuePlayer?.play()
            queuePlayer?.rate = playbackRate
            isPlaying = true
            wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        } else {
            queuePlayer?.pause()
            isPlaying = false
        }
        updateNowPlayingPlaybackInfo()

        // 6. Resume continuous Kokoro generation for remaining chunks
        let nextChunkIndex = (chunks.last?.identity.segmentID.ordinal ?? 0) + 1
        Log.audio.info("Resuming continuous Kokoro generation from segment \(nextChunkIndex).")
        AudioGenerationManager.shared.generate(
            document: doc,
            playbackEngine: self,
            startChunkIndex: nextChunkIndex
        )
    }

}
