import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

public struct PlayedChunk {
    public let url: URL
    public let duration: TimeInterval
    public let globalStartTime: TimeInterval
    public let timestamps: [WordTimestamp]
}

@MainActor
public class PlaybackProgress: ObservableObject {
    public static let shared = PlaybackProgress()
    
    @Published public var currentTime: TimeInterval = 0
    @Published public var currentWordIndex: Int? = nil
    
    private init() {}
}

@MainActor
public class AudioPlaybackEngine: ObservableObject {
    public static let shared = AudioPlaybackEngine()
    public let progress = PlaybackProgress.shared
    
    private var queuePlayer: AVQueuePlayer?
    
    public var chunks: [PlayedChunk] = []
    private var timeObserverToken: Any?
    private var endObserverToken: Any?
    private var interruptionObserverToken: Any?
    private var routeChangeObserverToken: Any?
    private var wasPlayingBeforeInterruption: Bool = false
    private var lastProgressSaveTime: TimeInterval = 0
    
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
    
    public var currentWordIndex: Int? {
        get { progress.currentWordIndex }
        set { progress.currentWordIndex = newValue }
    }
    
    @Published public var duration: TimeInterval = 0
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
    
    public func finishGeneration() {
        isGenerationActive = false
        if chunks.isEmpty {
            self.pause()
        }
    }
    
    private init() {
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        self.basePlaybackSpeed = savedSpeed == 0 ? 1.0 : Float(savedSpeed)
        self.playbackRate = self.basePlaybackSpeed
        
        setupRemoteCommandCenter()
        setupAudioSessionObservers()
        
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.updateEffectivePlaybackRate() }
        }
    }
    
    @MainActor
    public func updateEffectivePlaybackRate(currentWordIndex: Int? = nil) {
        var bump: Float = 0.0
        if autoIncreaseSpeedEnabled {
            let indexToUse = currentWordIndex ?? self.currentWordIndex
            if let index = indexToUse {
                bump = floor(Float(index) / 500.0) * 0.1
            }
        }
        
        let newRate = min(3.0, basePlaybackSpeed + bump)
        if abs(playbackRate - newRate) > 0.01 {
            playbackRate = newRate
        }
    }
    
    public func enqueue(chunk: AudioChunk) {
        let exactDuration = chunk.duration
        let globalStart = chunks.last.map { $0.globalStartTime + $0.duration } ?? 0.0
        let playedChunk = PlayedChunk(url: chunk.fileURL, duration: exactDuration, globalStartTime: globalStart, timestamps: chunk.timestamps)
        chunks.append(playedChunk)
        
        // Gapless enqueue using AVQueuePlayer
        let newItem = AVPlayerItem(url: chunk.fileURL)
        queuePlayer?.insert(newItem, after: nil)
        
        duration += exactDuration
        updateNowPlayingPlaybackInfo()
    }
    
    public func load(document: Document) {
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
        currentWordIndex = nil
        
        self.currentDocument = document
        setupNowPlaying()
    }

    public func play() {
        queuePlayer?.play()
        queuePlayer?.rate = playbackRate
        isPlaying = true
        updateNowPlayingPlaybackInfo()
    }
    
    public func pause() {
        queuePlayer?.pause()
        isPlaying = false
        updateNowPlayingPlaybackInfo()
        
        if let doc = currentDocument, duration > 0 {
            doc.progress = currentTime / duration
            lastProgressSaveTime = currentTime
        }
    }
    
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func seek(to targetTime: TimeInterval) {
        let targetTime = max(0, min(targetTime, duration))
        
        // Find which chunk this time falls into
        guard let chunkIndex = chunks.firstIndex(where: { targetTime >= $0.globalStartTime && targetTime < $0.globalStartTime + $0.duration }) ?? chunks.indices.last else { return }
        
        let targetChunk = chunks[chunkIndex]
        let localTime = targetTime - targetChunk.globalStartTime
        
        let wasPlaying = isPlaying
        queuePlayer?.pause()
        
        // Rebuild the queue starting from the target chunk
        queuePlayer?.removeAllItems()
        for i in chunkIndex..<chunks.count {
            let item = AVPlayerItem(url: chunks[i].url)
            queuePlayer?.insert(item, after: nil)
        }
        
        let cmTime = CMTime(seconds: localTime, preferredTimescale: 600)
        queuePlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentTime = targetTime
                self.updateNowPlayingPlaybackInfo()
                
                if wasPlaying {
                    self.queuePlayer?.play()
                    self.queuePlayer?.rate = self.playbackRate
                }
            }
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
            Task { @MainActor in
                // Determine global time by identifying the current playing chunk
                guard let currentItem = self.queuePlayer?.currentItem,
                      let currentURL = (currentItem.asset as? AVURLAsset)?.url,
                      let playingChunk = self.chunks.first(where: { $0.url.lastPathComponent == currentURL.lastPathComponent }) else {
                    return
                }
                
                let localPlayTime = time.seconds
                guard localPlayTime >= 0 else { return }
                
                let globalPlayTime = playingChunk.globalStartTime + localPlayTime
                self.currentTime = min(globalPlayTime, self.duration)
                
                // Word highlighting across the whole document
                if let doc = self.currentDocument {
                    let timestamps = doc.decodedWordTimestamps
                    if !timestamps.isEmpty {
                        var low = 0
                        var high = timestamps.count - 1
                        var ans: Int? = nil
                        while low <= high {
                            let mid = (low + high) / 2
                            if timestamps[mid].startTime <= globalPlayTime {
                                ans = mid
                                low = mid + 1
                            } else {
                                high = mid - 1
                            }
                        }
                        if let foundIndex = ans {
                            let word = timestamps[foundIndex]
                            if globalPlayTime <= word.endTime + 0.5 {
                                self.currentWordIndex = foundIndex
                            }
                        }
                    }
                }
                
                // Periodically save progress
                if let doc = self.currentDocument, doc.modelContext != nil {
                    if self.duration > 0 && abs(self.currentTime - self.lastProgressSaveTime) > 5.0 {
                        doc.progress = self.currentTime / self.duration
                        self.lastProgressSaveTime = self.currentTime
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
            Task { @MainActor in
                // If there are no more items in the queue and generation is finished, we're done
                if self.queuePlayer?.items().count ?? 0 <= 1 && !self.isGenerationActive {
                    self.isPlaying = false
                    self.updateNowPlayingPlaybackInfo()
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
            
            Task { @MainActor in
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
            Task { @MainActor in
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
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }
        
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in self.skipForward() }
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in self.skipBackward() }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(to: positionEvent.positionTime) }
            return .success
        }
    }
}
