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
    
    private var queuePlayer: AVQueuePlayer?
    
    public var chunks: [PlayedChunk] = []
    public var virtualBaseOffset: TimeInterval = 0
    private var seekDebounceTimer: Timer?
    private var timeObserverToken: Any?
    private var endObserverToken: Any?
    private var interruptionObserverToken: Any?
    private var routeChangeObserverToken: Any?
    private var wasPlayingBeforeInterruption: Bool = false
    private var lastProgressSaveTime: TimeInterval = 0
    private var currentSessionStartTime: TimeInterval?
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
        if chunks.isEmpty {
            self.pause()
        }
        if isRecoveringFromUnderrun && isPlaying {
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
        
        setupRemoteCommandCenter()
        setupAudioSessionObservers()
        
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in self?.updateEffectivePlaybackRate() }
        }
    }
    
    @MainActor
    public func updateEffectivePlaybackRate() {
        let newRate = min(3.0, basePlaybackSpeed)
        if abs(playbackRate - newRate) > 0.01 {
            playbackRate = newRate
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
        
        chunks = []
        currentTime = 0
        duration = 0
        virtualBaseOffset = 0
        currentWord = nil
        
        self.currentDocument = document
        
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
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.audio.error("Failed to activate audio session: \(error.localizedDescription, privacy: .public)")
        }
        isRecoveringFromUnderrun = false
        queuePlayer?.play()
        queuePlayer?.rate = playbackRate
        isPlaying = true
        currentSessionStartTime = currentTime
        updateNowPlayingPlaybackInfo()
    }
    
    public func pause() {
        queuePlayer?.pause()
        isRecoveringFromUnderrun = false
        isPlaying = false
        updateNowPlayingPlaybackInfo()
        
        if let startTime = currentSessionStartTime {
            let sessionDuration = currentTime - startTime
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
            currentSessionStartTime = nil
        }
        
        if let doc = currentDocument, duration > 0 {
            doc.progress = currentTime / duration
            doc.lastReadCharIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? doc.lastReadCharIndex
            lastProgressSaveTime = currentTime
        }
        
        evaluateAudioSession()
    }
    
    public func clearMemory() {
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
        guard let doc = currentDocument else { return }
        
        
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
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        
        let totalDuration = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        let safeTargetTime = max(0, min(targetTime, totalDuration))
        
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
                        }
                    }
                }
            } else {
                if wasPlaying {
                    queuePlayer?.play()
                    queuePlayer?.rate = playbackRate
                    self.isPlaying = true
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
        }
    }

    public func seek(toCharIndex charIndex: Int) {
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
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        
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
        }
    }

    public func skipForward() {
        seek(to: currentTime + defaultSkipInterval)
    }
    
    public func skipBackward() {
        seek(to: max(0, currentTime - defaultSkipInterval))
    }
    
    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = queuePlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
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
    
    private func setupEndObserver() {
        removeEndObserver()
        endObserverToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // If there are no more items in the queue and generation is finished, we're done
                if (self.queuePlayer?.items().isEmpty ?? true) && !self.isGenerationActive {
                    self.pause()
                    
                    // Trigger auto-advance to next chapter in queue
                    Task {
                        PlaybackCoordinator.shared.advanceNext()
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
                    self.pause()
                case .ended:
                    if let optionsValue = optionsValue {
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                            self.play()
                        }
                    }
                @unknown default:
                    break
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

}
