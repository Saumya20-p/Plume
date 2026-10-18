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
        coordinator.contract?.snapshot
    }
    
    let prewarmSynthesizer = AVSpeechSynthesizer()
    var queuePlayer: AVQueuePlayer?
    var playerTimeControlCancellable: AnyCancellable?
    let audioSessionOwner = UUID()
    var audioPreparationID: UUID?
    var hasPrewarmedSpeech = false
    var audioPreferencesSnapshot: AudioPreferencesSnapshot?
    
    public var chunks: [PlayedChunk] = []
    public var virtualBaseOffset: TimeInterval = 0
    var seekDebounceTimer: Timer?
    var timeObserverToken: Any?
    var endObserverToken: Any?
    var interruptionObserverToken: Any?
    var routeChangeObserverToken: Any?
    var didEnterBackgroundObserverToken: Any?
    var willEnterForegroundObserverToken: Any?
    var userDefaultsObserverToken: Any?
    var mediaServicesLostObserverToken: Any?
    var mediaServicesResetObserverToken: Any?
    var userDefaultsDebounceTimer: Timer?
    var wasPlayingBeforeInterruption: Bool = false
    var wasSuspendedBeforeInterruption: Bool = false
    var wasPlayingBeforeMediaServicesLoss: Bool = false
    var lastProgressSaveTime: TimeInterval = 0
    var wallClockSessionStartTime: TimeInterval?
    var currentSeekTask: Task<Void, Never>? = nil
    var pendingSeek: PendingSeek?
    var activeQueueItems: Set<ObjectIdentifier> = []
    // Injectable completion boundary lets lifecycle tests hold a real seek in flight.
    var seekItemOperation: @MainActor (AVPlayerItem, CMTime) async -> Bool = { item, time in
        await AudioPlaybackEngine.seekReadyItem(item, to: time)
    }
    var seekRevision = 0
    var generationGate = PlaybackGenerationGate()
    
    @Published public var basePlaybackSpeed: Float {
        didSet {
            UserDefaults.standard.set(Double(basePlaybackSpeed), forKey: "defaultPlaybackSpeed")
            Task { @MainActor [weak self] in self?.updateEffectivePlaybackRate() }
        }
    }
    
    var autoIncreaseSpeedEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoIncreaseSpeedEnabled")
    }
    
    var defaultSkipInterval: TimeInterval {
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
            if isPlaying && pendingSeek == nil && AppAudioSession.shared.isReady(owner: audioSessionOwner) {
                queuePlayer?.rate = playbackRate
            }
            updateNowPlayingPlaybackInfo()
        }
    }
    
    @Published var currentDocument: Document?
    @Published var isPlayerViewPresented: Bool = false
    @Published public var presentedPlayerDocument: Document? = nil
    public var isGenerationActive: Bool = false
    var isRecoveringFromUnderrun: Bool = false
    
    func finishGeneration(sessionID: UUID, preservingPlaybackIntent: Bool = false) {
        guard generationGate.isActive(sessionID: sessionID) else {
            return
        }

        isGenerationActive = false
        if chunks.isEmpty && !coordinator.isAppleActive && !preservingPlaybackIntent {
            if let request = pendingSeek {
                if request.phase == .generating { failSeek(request) }
            } else { pause() }
        }
        if pendingSeek == nil && isRecoveringFromUnderrun && isPlaying && !coordinator.isAppleActive {
            isRecoveringFromUnderrun = false
            resumeQueuedPlayback()
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
        
        audioPreferencesSnapshot = AudioPreferencesSnapshot.current()
        userDefaultsObserverToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAudioPreferencesChange() }
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
    
    func setupCoordinatorCallbacks() {
        coordinator.onProgress = { [weak self] time, word in
            guard let self, self.pendingSeek == nil else { return }
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

        coordinator.onCompleted = { [weak self] in
            guard let self, self.pendingSeek == nil else { return }
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
            let revision = self.seekRevision
            let documentID = self.currentDocument?.id
            Task { @MainActor [weak self] in
                guard let self, self.pendingSeek == nil, self.seekRevision == revision,
                      self.currentDocument?.id == documentID else { return }
                PlaybackCoordinator.shared.advanceNext()
            }
        }

        coordinator.onPerformHandback = { [weak self] chunks, _ in
            guard let self, self.pendingSeek == nil else { return }
            self.resumeFromHandback(chunks: chunks, session: nil)
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
        insertQueuedItem(newItem)
        
        duration += exactDuration
        if pendingSeek != nil {
            positionGeneratedSeekIfNeeded()
            updateNowPlayingPlaybackInfo()
            return true
        }
        if isPlaying {
            if queuePlayer?.timeControlStatus != .playing {
                isRecoveringFromUnderrun = true
            }
            
            if isRecoveringFromUnderrun {
                if (queuePlayer?.items().count ?? 0) >= 2 {
                    isRecoveringFromUnderrun = false
                    resumeQueuedPlayback()
                }
            } else {
                resumeQueuedPlayback()
            }
        }
        
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
        cancelPendingSeek()
        cancelSpeculativeHandback()
        if let generationSession {
            generationGate.activate(generationSession)
        } else {
            generationGate.invalidate()
        }
        isGenerationActive = true
        audioPreparationID = nil
        removeTimeObserver()
        removeEndObserver()
        
        queuePlayer?.pause()
        removeQueuedItems()
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
            prepareReaderAudioSession(reason: "load-apple")
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
            self.insertQueuedItem(AVPlayerItem(url: legacyURL))
        }
        
        setupNowPlaying()
        prepareReaderAudioSession(reason: "load")
    }

    public func play() {
        guard currentDocument != nil else { return }
        pendingSeek?.shouldPlay = true
        coordinator.requestPlayIntent()
        isPlaying = true
        traceSeek("play-intent")
        updateNowPlayingPlaybackInfo()
        if AppAudioSession.shared.isReady(owner: audioSessionOwner) {
            startPreparedPlayback()
        } else {
            prepareReaderAudioSession(reason: "play")
        }
    }

    public func pause(file: String = #file, line: Int = #line, function: String = #function) {
        audioPreparationID = nil
        Log.audio.info("pause called from \(function):\(line)")
        pendingSeek?.shouldPlay = false
        traceSeek("pause-intent")
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
    

    
    public func clearMemory() {
        cancelPendingSeek()
        recordListeningSession()
        saveDocumentProgress()
        coordinator.cancel()
        generationGate.invalidate()
        queuePlayer?.pause()
        removeQueuedItems()
        chunks.removeAll()
        evaluateAudioSession()
    }
    
    public func evaluateAudioSession() {
        let isIntentPlaying = coordinator.contract?.desiredPlayIntent == .playing
        if !isPlaying && !isGenerationActive && !isIntentPlaying && !coordinator.isFallbackActive {
            audioPreparationID = nil
            AppAudioSession.shared.release(owner: audioSessionOwner, reason: "reader-idle")
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
        guard targetTime.isFinite,
              let request = beginSeek(playAfterSeek: true) else { return }
        if !coordinator.isAppleActive {
            chunks.removeAll()
            removeQueuedItems()
        }
        performSeek(to: targetTime, request: request)
    }
    
    func cancelPendingSeek() {
        pendingSeek = nil
        seekRevision &+= 1
        seekDebounceTimer?.invalidate()
        seekDebounceTimer = nil
        currentSeekTask?.cancel()
        currentSeekTask = nil
    }

    public func seek(to targetTime: TimeInterval) {
        guard targetTime.isFinite else { return }
        scheduleSeek { engine, request in engine.performSeek(to: targetTime, request: request) }
    }

    public func seek(toCharIndex charIndex: Int, playAfterSeek: Bool = false) {
        scheduleSeek(playAfterSeek: playAfterSeek, characterOffset: charIndex) { engine, request in
            engine.performSeek(toCharIndex: charIndex, request: request)
        }
    }

    private func scheduleSeek(playAfterSeek: Bool = false, characterOffset: Int? = nil,
                              _ action: @escaping @MainActor (AudioPlaybackEngine, PendingSeek) -> Void) {
        guard let request = beginSeek(playAfterSeek: playAfterSeek, characterOffset: characterOffset) else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentSeek(request) else { return }
                self.seekDebounceTimer = nil
                action(self, request)
            }
        }
        timer.tolerance = 0.025
        seekDebounceTimer = timer
    }

    public func skipForward() {
        performSeek(to: currentTime + defaultSkipInterval)
    }
    
    public func skipBackward() {
        seekDebounceTimer?.invalidate()
        seekDebounceTimer = nil
        performSeek(to: max(0, currentTime - defaultSkipInterval))
    }
    
    func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let player = queuePlayer else { return }
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.queuePlayer === player, self.pendingSeek == nil else { return }
                
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
                
                let localPlayTime = currentItem.currentTime().seconds
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

    func removeTimeObserver() {
        if let token = timeObserverToken {
            queuePlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    func removeEndObserver() {
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
    }
    
    func removePlayerObservers() {
        playerTimeControlCancellable?.cancel()
        playerTimeControlCancellable = nil
    }

    
    func setupEndObserver() {
        removeEndObserver()
        endObserverToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let item = notification.object as? AVPlayerItem else { return }
                let revision = self.seekRevision
                Task { @MainActor [weak self] in
                    guard let self, self.seekRevision == revision else { return }
                    self.handlePlaybackItemEnded(item)
                }
            }
        }
    }

    func handlePlaybackItemEnded(_ item: AVPlayerItem) {
        guard pendingSeek == nil, !coordinator.isAppleActive,
              activeQueueItems.remove(ObjectIdentifier(item)) != nil else { return }
        if let url = (item.asset as? AVURLAsset)?.url,
           let chunk = chunks.first(where: { $0.url == url }) {
            coordinator.commitChunkBoundary(chunk)
        }
        if queuePlayer?.items().isEmpty ?? true {
            if hasReachedDocumentEnd {
                pause()
                let revision = seekRevision
                let documentID = currentDocument?.id
                Task { @MainActor [weak self] in
                    guard let self, self.pendingSeek == nil, self.seekRevision == revision,
                          self.currentDocument?.id == documentID else { return }
                    PlaybackCoordinator.shared.advanceNext()
                }
            } else if isPlaying || coordinator.desiredPlayIntent == .playing {
                triggerFallbackToAppleSpeech(reason: "Kokoro audio buffer underrun (queue exhausted before EOF)")
            }
        }
    }
    
    
    func setupNowPlaying() {
        setRemoteCommandsEnabled(true)
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
    
    

    // MARK: - Fallback Routing

    public var isFallbackActive: Bool {
        coordinator.isFallbackActive
    }

    var hasReachedDocumentEnd: Bool {
        guard let doc = currentDocument else { return true }
        if let committed = coordinator.contract?.committedCursor {
            return committed.globalUTF16Offset >= doc.bodyText.utf16.count
        }
        return currentTime >= (duration - 0.5) && !isGenerationActive
    }


    public func triggerFallbackToAppleSpeech(reason: String) {
        cancelSpeculativeHandback()
        guard pendingSeek == nil, !coordinator.isAppleActive, let doc = currentDocument,
              let fallbackSessionID = coordinator.contract?.sessionID else { return }
        let fallbackDocumentID = doc.id
        let fallbackSeekRevision = seekRevision
        
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
        // 2. Cancel Kokoro generation tasks (but do NOT pause AVQueuePlayer yet so it overlaps)
        AudioGenerationManager.shared.cancelCurrentGeneration(preservingPlaybackIntent: true)
        isGenerationActive = false
        isRecoveringFromUnderrun = false
        
        // 3. Adjust duration to full document duration if available
        if doc.estimatedDuration > 0 {
            self.duration = doc.estimatedDuration
        }
        
        // 4. Trigger handoff in coordinator while state and cursors are fully resolved
        let wasPlaying = self.isPlaying || (coordinator.contract?.desiredPlayIntent == .playing)
        
        if wasPlaying {
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AppleSpeechFallback") {
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
            
            AppAudioSession.shared.prepare(owner: audioSessionOwner, reason: "fallback") { [weak self] result in
                defer {
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }
                }
                guard let self,
                      self.currentDocument?.id == fallbackDocumentID,
                      self.seekRevision == fallbackSeekRevision, self.pendingSeek == nil,
                      self.coordinator.contract?.sessionID == fallbackSessionID else { return }
                if case .failure(let error) = result {
                    if !(error is CancellationError) {
                        self.pause()
                        self.coordinator.reportAudioSessionFailure(error)
                    }
                    return
                }
                guard self.coordinator.desiredPlayIntent == .playing else { return }

                let success = self.coordinator.triggerFallback(reason: reason)
                self.removeQueuedItems()
                self.chunks.removeAll()

                if success {
                    self.currentTime = self.coordinator.estimatedCurrentTime
                    self.isPlaying = self.coordinator.desiredPlayIntent == .playing
                    self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                    self.updateNowPlayingPlaybackInfo()
                }


            }
        } else {
            let success = coordinator.triggerFallback(reason: reason)
            removeQueuedItems()
            chunks.removeAll()
            
            if success {
                self.currentTime = coordinator.estimatedCurrentTime
                self.updateNowPlayingPlaybackInfo()
            }
        }
    }

    // MARK: - Speculative Foreground Handback (Phase 6)

    func handleWillEnterForeground() {
        guard coordinator.isFallbackActive, let doc = currentDocument, (isPlaying || coordinator.contract?.desiredPlayIntent == .playing) else { return }
        Log.audio.info("Application returning to foreground during Apple Speech fallback; initiating speculative handback preparation.")
        // Keep speech flowing until a replacement chunk is actually ready.
        triggerSpeculativeHandbackPreparation(for: doc)
    }


    func cancelSpeculativeHandback() {
        AudioGenerationManager.shared.cancelSpeculativePreparation()
        coordinator.cancelPendingHandback()
    }


}
