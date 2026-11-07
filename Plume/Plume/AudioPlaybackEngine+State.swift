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
        generationManager.cancelCurrentGeneration()
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
        currentWord = nil
        currentTime = 0
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
        let values = listeningAccumulator.take(at: listeningClock())
        // A final word may finish just after the producer's stop notification.
        // Preserve it in a zero-time row; aggregate WPM uses the earlier time row.
        guard values.seconds > 0 || values.words > 0,
              let document = currentDocument, let context = document.modelContext else { return }
        let session = ListeningSession(documentId: document.id, secondsListened: values.seconds,
                                       wordsListened: values.words, playbackSpeed: Double(playbackRate), measurementVersion: 2)
        context.insert(session)
        do { try context.save() } catch {
            PlaybackDiagnostics.shared.record("listening-save-failed code=\((error as NSError).code)")
        }
    }

    func saveDocumentProgress() {
        guard let document = currentDocument else { return }
        if coordinator.contract?.lifecycle == .completed { document.lastReadCharIndex = document.bodyText.utf16.count }
        else { document.lastReadCharIndex = min(document.bodyText.utf16.count, max(0, resumeSourceOffset)) }
        document.progress = document.readingProgress
        lastProgressSaveTime = currentTime
        do { try document.modelContext?.save() } catch {
            PlaybackDiagnostics.shared.record("progress-save-failed code=\((error as NSError).code)")
        }
    }

    func updateNowPlayingPlaybackInfo() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        
        let displayDuration = displayTotalDuration
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = displayDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = actualPlaybackActive ? playbackRate : 0.0
        
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
