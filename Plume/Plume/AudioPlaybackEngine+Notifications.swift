import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
    func setupPlayerObservers() {
        removePlayerObservers()
        guard let player = queuePlayer else { return }
        
        playerTimeControlCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self, weak player] _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player else { return }
                    self.handlePlayerStatus(player)
                }
            }
    }

    func handlePlayerStatus(_ player: AVQueuePlayer) {
        guard queuePlayer === player, pendingSeek == nil, !coordinator.isAppleActive,
              AppAudioSession.shared.isReady(owner: audioSessionOwner) else { return }
        // Read current status rather than replaying queued KVO values from before a seek.
        let playing = player.timeControlStatus != .paused && coordinator.desiredPlayIntent == .playing
        if isPlaying != playing {
            isPlaying = playing
            if playing {
                if wallClockSessionStartTime == nil { wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate }
            } else { recordListeningSession() }
            updateNowPlayingPlaybackInfo()
        }
    }


    func setupAudioSessionObservers() {
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
                    AppAudioSession.shared.invalidate(reason: "interruption")
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
                AppAudioSession.shared.invalidate(reason: "media-services-lost")
                self.wasPlayingBeforeMediaServicesLoss = self.isPlaying || (self.coordinator.contract?.desiredPlayIntent == .playing)
                self.pause()
            }
        }
        
        mediaServicesResetObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                AppAudioSession.shared.invalidate(reason: "media-services-reset")

                let wasPlaying = self.wasPlayingBeforeMediaServicesLoss
                self.wasPlayingBeforeMediaServicesLoss = false
                
                if !self.coordinator.isAppleActive {
                    self.cancelPendingSeek()
                    self.removeTimeObserver()
                    self.removeQueuedItems()
                    self.queuePlayer = AVQueuePlayer()
                    self.queuePlayer?.automaticallyWaitsToMinimizeStalling = false
                    self.setupTimeObserver()
                    self.setupEndObserver()
                    self.setupPlayerObservers()
                    
                    for chunk in self.chunks {
                        self.insertQueuedItem(AVPlayerItem(url: chunk.url))
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

        didEnterBackgroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let app = UIApplication.shared
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = app.beginBackgroundTask(withName: "GPUBackgroundDrain") {
                if bgTaskID != .invalid {
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            
            // 1. CRITICAL: Drain GPU synchronously BEFORE returning to iOS!
            KokoroTTSService.shared.waitForGPUIdleSync()
            
            if bgTaskID != .invalid {
                app.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cancelSpeculativeHandback()
                guard self.currentDocument != nil else { return }
                if self.coordinator.isAppleActive {
                    if self.coordinator.desiredPlayIntent == .playing {
                        _ = self.coordinator.play()
                    }
                    return
                }
                Log.audio.info("Application entered background; triggering fallback from Kokoro to Apple Speech.")
                self.triggerFallbackToAppleSpeech(reason: "Application entered background")
            }
        }

        willEnterForegroundObserverToken = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            KokoroTTSService.shared.getEngineActorSync()?.backgroundState.isPaused = false
            MainActor.assumeIsolated {
                self?.handleWillEnterForeground()
            }
        }
    }

}
