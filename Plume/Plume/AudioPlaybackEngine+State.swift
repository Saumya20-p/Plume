import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
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
