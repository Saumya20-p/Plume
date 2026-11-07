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
    
    init() {}
}

@MainActor
public class AudioPlaybackEngine: ObservableObject {
    public static let shared = AudioPlaybackEngine()
    public let progress: PlaybackProgress

    let coordinator: PlaybackRoutingCoordinator
    private let managerOverride: AudioGenerationManager?
    var generationManager: AudioGenerationManager { managerOverride ?? .shared }
    var applicationPhase: PlaybackAppPhase = .active
    var lifecycleObservation: AnyCancellable?
    var generationEOF = false
    @Published var generationFailed = false
    var completedRunID: UUID?
    var recoveryBudget = PlaybackRecoveryBudget()
    var automaticFallbackOverride: (() -> Bool)?
    var allowsAutomaticFallback: Bool { automaticFallbackOverride?() ?? PlaybackPreferences.automaticFallback }
    var lastActualSample: TimeInterval?
    var itemFailureObserverToken: Any?
    var itemStatusSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    var fallbackTransitionID: UUID?
    var advanceQueue: () -> Void = { PlaybackCoordinator.shared.advanceNext() }
    var audioReadyOverride: (() -> Bool)?
    var prepareAudioOverride: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    var listeningAccumulator = ListeningAccumulator()
    var listeningWordRanges: [UTF16TextRange] = []
    var deliveredWords: Set<Int> = []
    var listeningItems: [ObjectIdentifier: KokoroListeningTraversal] = [:]
    var listeningClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @Published var isWaitingForForeground = false
    @Published var actualPlaybackActive = false
    var isAudioReady: Bool { audioReadyOverride?() ?? AppAudioSession.shared.isReady(owner: audioSessionOwner) }
    
    public var isAppleActive: Bool {
        coordinator.isAppleActive
    }
    
    var currentSnapshot: PlaybackSessionSnapshot? {
        coordinator.contract?.snapshot
    }
    
    let prewarmSynthesizer = AVSpeechSynthesizer()
    var queuePlayer: AVQueuePlayer?
    var playerTimeControlCancellable: AnyCancellable?
    var playerCurrentItemCancellable: AnyCancellable?
    let audioSessionOwner = UUID()
    var audioPreparationID: UUID?
    var interruptionRevision = 0
    var systemInterruptionActive = false
    var recoverySeekOffset: Int?
    var deferredSeekTarget: DeferredSeekTarget?
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
    @Published var pendingSeek: PendingSeek?
    var activeQueueItems: Set<ObjectIdentifier> = []
    var queueItemFailures: [ObjectIdentifier: Error] = [:]
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
    @Published public var isGenerationActive: Bool = false
    var isRecoveringFromUnderrun: Bool = false
    
    func finishGeneration(sessionID: UUID, termination: GenerationTermination) {
        guard generationGate.isActive(sessionID: sessionID) else {
            return
        }

        isGenerationActive = false
        if chunks.isEmpty && !coordinator.isAppleActive && (termination == .failed || termination == .cancelled) {
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
    
    init(observeSystem: Bool = true, manager: AudioGenerationManager? = nil,
         routing: PlaybackRoutingCoordinator? = nil) {
        let trace = StabilityTrace.begin("StartupPlaybackEngine")
        defer { StabilityTrace.end("StartupPlaybackEngine", trace) }
        self.progress = observeSystem ? .shared : PlaybackProgress()
        self.coordinator = routing ?? PlaybackRoutingCoordinator()
        self.managerOverride = manager
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        self.basePlaybackSpeed = savedSpeed == 0 ? 1.0 : Float(savedSpeed)
        self.playbackRate = self.basePlaybackSpeed
        
        queuePlayer = AVQueuePlayer()
        queuePlayer?.automaticallyWaitsToMinimizeStalling = false
        setupPlayerObservers()
        
        coordinator.playbackEngine = self
        if observeSystem {
            applicationPhase = PlaybackLifecycle.shared.phase
            lifecycleObservation = PlaybackLifecycle.shared.$phase.dropFirst().sink { [weak self] in self?.handleLifecycle($0) }
            setupRemoteCommandCenter()
            setupAudioSessionObservers()
        } else { advanceQueue = {} }
        setupCoordinatorCallbacks()
        
        audioPreferencesSnapshot = AudioPreferencesSnapshot.current()
        if observeSystem { userDefaultsObserverToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAudioPreferencesChange() }
        } }

    }

    deinit {
        playerTimeControlCancellable?.cancel()
        if let token = itemFailureObserverToken { NotificationCenter.default.removeObserver(token) }
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
                
            self.saveDocumentProgressIfNeeded()
            self.updateNowPlayingPlaybackInfo()
        }

        coordinator.onActualPlayingChanged = { [weak self] active in
            guard let self, self.coordinator.isAppleActive else { return }
            self.isPlaying = self.coordinator.desiredPlayIntent == .playing
            self.setActualPlayback(active)
            self.updateNowPlayingPlaybackInfo()
        }
        coordinator.onWaitingForPrimary = { [weak self] in self?.waitForSafeGeneration() }
        coordinator.onSpokenWordCompleted = { [weak self] range in self?.countDeliveredWords(range) }
        coordinator.onCompleted = { [weak self] in self?.completeLogicalPlayback() }

        coordinator.onPerformHandback = { [weak self] chunks, _ in
            guard let self, self.pendingSeek == nil else { return }
            self.resumeFromHandback(chunks: chunks, session: nil)
        }
    }
    
    @MainActor
    public func updateEffectivePlaybackRate() {
        let newRate = min(3.0, basePlaybackSpeed)
        if abs(playbackRate - newRate) > 0.01 {
            recordListeningSession()
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
        
        duration = globalStart + exactDuration
        if pendingSeek != nil {
            positionGeneratedSeekIfNeeded()
            updateNowPlayingPlaybackInfo()
            return true
        }
        if coordinator.desiredPlayIntent == .playing {
            isPlaying = true
            if queuePlayer?.timeControlStatus != .playing {
                isRecoveringFromUnderrun = true
            }
            
            isRecoveringFromUnderrun = false
            resumeQueuedPlayback()
        }
        
        updateNowPlayingPlaybackInfo()
        return true
    }
    
    public func load(document: Document) {
        load(document: document, generationSession: nil)
    }

    func beginGenerationSession(_ session: PlaybackGenerationSession) {
        generationGate.activate(session)
        generationFailed = false
        isGenerationActive = true
    }

    func load(document: Document, generationSession: PlaybackGenerationSession?) {
        setActualPlayback(false)
        recordListeningSession()
        isPlaying = false
        if currentDocument?.id != document.id { generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true) }
        cancelPendingSeek()
        cancelSpeculativeHandback()
        generationManager.clearIssue()
        generationEOF = false; generationFailed = false; completedRunID = nil
        isWaitingForForeground = false; fallbackTransitionID = nil
        recoveryBudget = PlaybackRecoveryBudget()
        if let generationSession {
            generationGate.activate(generationSession)
        } else {
            generationGate.invalidate()
        }
        isGenerationActive = generationSession != nil
        audioPreparationID = nil
        recoverySeekOffset = nil
        deferredSeekTarget = nil
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
        resetWordAccounting(document.bodyText)
        lastProgressSaveTime = -10
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

        if document.readingProgress == 1, !document.bodyText.isEmpty, generationSession == nil {
            _ = coordinator.completeAtEOF()
            isGenerationActive = false
            currentTime = document.estimatedDuration
            setupNowPlaying()
            evaluateAudioSession()
            return
        }
        if systemInterruptionActive {
            _ = coordinator.beginInterruption()
            setupNowPlaying()
            return
        }
        
        if coordinator.isAppleActive {
            self.duration = document.estimatedDuration
            self.currentTime = coordinator.estimatedCurrentTime
            self.isGenerationActive = false
            setupNowPlaying()
            prepareReaderAudioSession(reason: "load-apple")
            return
        }
        
        // Legacy whole-document files lack voice metadata; preserve them on disk
        // but do not silently substitute them for the selected voice.
        if let legacyURL = document.audioFileURL,
           UserDefaults.standard.string(forKey: "audioCache.voice.\(document.id)") == preferences.primary.identifier {
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
            self.generationEOF = true
            self.insertQueuedItem(AVPlayerItem(url: legacyURL))
        }
        
        setupNowPlaying()
        prepareReaderAudioSession(reason: "load")
    }

    public func play() {
        guard let document = currentDocument else { return }
        if coordinator.contract?.lifecycle == .completed {
            document.lastReadCharIndex = 0
            document.progress = 0
            reactivateCompletedRun(at: 0)
        }
        pendingSeek?.shouldPlay = true
        coordinator.requestPlayIntent()
        isPlaying = true
        generationFailed = false
        generationManager.clearIssue()
        if systemInterruptionActive {
            wasPlayingBeforeInterruption = true
            return
        }
        if pendingSeek == nil, let offset = recoverySeekOffset {
            recoverySeekOffset = nil
            seek(toCharIndex: offset, playAfterSeek: true)
            return
        }
        reconcilePlayback(explicit: true)
        updateNowPlayingPlaybackInfo()
    }

    public func pause(file: String = #file, line: Int = #line, function: String = #function) {
        audioPreparationID = nil
        fallbackTransitionID = nil
        isWaitingForForeground = false
        setActualPlayback(false)
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
        if coordinator.desiredPlayIntent == .playing { pause() } else { play() }
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
        deferredSeekTarget = nil
        seekRevision &+= 1
        seekDebounceTimer?.invalidate()
        seekDebounceTimer = nil
        currentSeekTask?.cancel()
        currentSeekTask = nil
    }

    public func seek(to targetTime: TimeInterval) {
        guard targetTime.isFinite else { return }
        scheduleSeek(target: .time(targetTime)) { engine, request in engine.performSeek(to: targetTime, request: request) }
    }

    public func seek(toCharIndex charIndex: Int, playAfterSeek: Bool = false) {
        scheduleSeek(playAfterSeek: playAfterSeek, characterOffset: charIndex, target: .character(charIndex)) { engine, request in
            engine.performSeek(toCharIndex: charIndex, request: request)
        }
    }

    private func scheduleSeek(playAfterSeek: Bool = false, characterOffset: Int? = nil, target: DeferredSeekTarget,
                              _ action: @escaping @MainActor (AudioPlaybackEngine, PendingSeek) -> Void) {
        guard let request = beginSeek(playAfterSeek: playAfterSeek, characterOffset: characterOffset) else { return }
        deferredSeekTarget = target
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

                guard !self.coordinator.isAppleActive else { return }
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
                            self.currentWord = word
                            if let loc = word.rangeLocation {
                                self.coordinator.advanceDisplay(toUTF16Offset: loc)
                            }
                        }
                    }
                }
                
                self.observeDeliveredKokoroWords(in: playingChunk, item: currentItem, time: localPlayTime)
                self.sampleActualPlayback()
                self.saveDocumentProgressIfNeeded()
                self.updateEffectivePlaybackRate()
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
        playerCurrentItemCancellable?.cancel()
        playerCurrentItemCancellable = nil
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
        itemStatusSubscriptions.removeValue(forKey: ObjectIdentifier(item))
        if let url = (item.asset as? AVURLAsset)?.url,
           let chunk = chunks.first(where: { $0.url == url }) {
            observeDeliveredKokoroWords(in: chunk, item: item, time: chunk.duration, finishing: true)
            coordinator.commitChunkBoundary(chunk)
        }
        listeningItems.removeValue(forKey: ObjectIdentifier(item))
        if activeQueueItems.isEmpty {
            setActualPlayback(false)
            if generationEOF { completeLogicalPlayback() }
            else if coordinator.desiredPlayIntent == .playing { reconcilePlayback(explicit: false) }
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

    var hasReachedDocumentEnd: Bool { coordinator.contract?.lifecycle == .completed || generationEOF && activeQueueItems.isEmpty }

    public func triggerFallbackToAppleSpeech(reason: String) {
        guard fallbackTransitionID == nil, pendingSeek == nil, coordinator.contract?.lifecycle == .active,
              coordinator.desiredPlayIntent == .playing, !coordinator.isAppleActive,
              !hasReachedDocumentEnd, let document = currentDocument else { return }
        guard allowsAutomaticFallback else { waitForSafeGeneration(); return }
        cancelSpeculativeHandback()
        let request = UUID()
        fallbackTransitionID = request
        let run = coordinator.contract?.sessionID
        let revision = seekRevision
        prepareAudioSession { [weak self] result in
            guard let self, self.fallbackTransitionID == request, self.seekRevision == revision,
                  self.currentDocument?.id == document.id, self.coordinator.contract?.sessionID == run,
                  self.coordinator.contract?.lifecycle == .active, self.coordinator.desiredPlayIntent == .playing,
                  self.allowsAutomaticFallback, !self.hasReachedDocumentEnd else { return }
            self.fallbackTransitionID = nil
            if case .failure(let error) = result {
                if !(error is CancellationError) {
                    self.pause()
                    self.generationManager.reportPlaybackFailure(error, engine: self, stage: "fallback audio session")
                }
                return
            }
            guard self.activeQueueItems.isEmpty else { return }
            self.queuePlayer?.pause()
            self.setActualPlayback(false)
            self.generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
            guard self.coordinator.triggerFallback(reason: reason) else { return }
            self.removeQueuedItems(); self.chunks.removeAll()
            self.duration = document.estimatedDuration
            self.currentTime = self.coordinator.estimatedCurrentTime
            self.isPlaying = true
            self.isWaitingForForeground = false
            PlaybackDiagnostics.shared.record("route=apple-fallback run=\(run?.uuidString ?? "none")")
            self.updateNowPlayingPlaybackInfo()
            if self.applicationPhase == .active { self.triggerSpeculativeHandbackPreparation(for: document) }
        }
    }

    func handleWillEnterForeground() {
        // Foreground entry alone does not grant GPU permission or start playback.
    }

    func cancelSpeculativeHandback() {
        generationManager.cancelSpeculativePreparation()
        coordinator.cancelPendingHandback()
    }


}
