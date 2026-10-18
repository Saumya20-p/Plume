import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
    /// Retire a session before dismissing or deleting its backing chapter.
    public func stopAndRelease() {
        cancelPendingSeek()
        AudioGenerationManager.shared.cancelCurrentGeneration()
        pause()
        clearMemory()
        coordinator.releaseSession()
        removeTimeObserver()
        removeEndObserver()
        playerTimeControlCancellable?.cancel()
        playerTimeControlCancellable = nil
        queuePlayer = nil
        isGenerationActive = false
        currentDocument = nil
        presentedPlayerDocument = nil
        isPlayerViewPresented = false
        currentWord = nil
        currentTime = 0
        duration = 0
        virtualBaseOffset = 0
        PlaybackProgress.shared.currentWord = nil
        PlaybackProgress.shared.currentTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setRemoteCommandsEnabled(false)
        evaluateAudioSession()
    }

    func setRemoteCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
    }

    func recordListeningSession() {
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

    func saveDocumentProgress() {
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

    func updateNowPlayingPlaybackInfo() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        
        let isFullyGenerated = currentDocument?.audioFileURL != nil
        let displayDuration = isFullyGenerated ? duration : max(duration, currentDocument?.estimatedDuration ?? duration)
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = displayDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in if self?.currentDocument != nil { self?.play() } }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in if self?.currentDocument != nil { self?.pause() } }
            return .success
        }
        
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in if self?.currentDocument != nil { self?.skipForward() } }
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor [weak self] in if self?.currentDocument != nil { self?.skipBackward() } }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in if self?.currentDocument != nil { self?.seek(to: positionEvent.positionTime) } }
            return .success
        }
    }

}
