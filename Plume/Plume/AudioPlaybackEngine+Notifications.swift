import Foundation
import AVFoundation
import Combine
import UIKit

extension AudioPlaybackEngine {
    func setupPlayerObservers() {
        removePlayerObservers()
        guard let player = queuePlayer else { return }
        playerTimeControlCancellable = player.publisher(for: \.timeControlStatus).sink { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                self.handlePlayerStatus(player)
            }
        }
        playerCurrentItemCancellable = player.publisher(for: \.currentItem).sink { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                self.handlePlayerStatus(player)
            }
        }
    }
    func handlePlayerStatus(_ player: AVQueuePlayer) {
        guard queuePlayer === player, pendingSeek == nil, !coordinator.isAppleActive else { return }
        if let item = player.currentItem,
           item.status == .failed || queueItemFailures[ObjectIdentifier(item)] != nil {
            handlePlaybackItemFailure(item, error: item.error ?? queueItemFailures[ObjectIdentifier(item)])
            return
        }
        sampleActualPlayback()
        isPlaying = coordinator.desiredPlayIntent == .playing
        updateNowPlayingPlaybackInfo()
    }
    func setupAudioSessionObservers() {
        itemFailureObserverToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let item = notification.object as? AVPlayerItem,
                      self.activeQueueItems.contains(ObjectIdentifier(item)), !self.coordinator.isAppleActive else { return }
                self.handlePlaybackItemFailure(item, error: item.error)
            }
        }
        interruptionObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
                self.handleInterruption(interruption, shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
            }
        }
        mediaServicesLostObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                AppAudioSession.shared.invalidate(reason: "media-services-lost")
                self?.pause()
            }
        }
        mediaServicesResetObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
        }
        routeChangeObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                MainActor.assumeIsolated { self?.pause() }
            }
        }
    }
    func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            guard !systemInterruptionActive else { return }
            systemInterruptionActive = true
            interruptionRevision &+= 1
            audioPreparationID = nil
            AppAudioSession.shared.invalidate(reason: "interruption")
            guard coordinator.contract?.lifecycle == .active else { return }
            wasPlayingBeforeInterruption = pendingSeek?.shouldPlay ?? (coordinator.desiredPlayIntent == .playing)
            if wasPlayingBeforeInterruption { coordinator.requestPlayIntent() }
            let offset = resumeSourceOffset
            if let request = pendingSeek {
                let target = deferredSeekTarget ?? .character(offset)
                cancelPendingSeek()
                pendingSeek = PendingSeek(revision: seekRevision, documentID: request.documentID,
                    shouldPlay: request.shouldPlay, characterOffset: request.characterOffset)
                deferredSeekTarget = target
                coordinator.syncCursor(toUTF16Offset: offset)
            }
            queuePlayer?.pause()
            setActualPlayback(false)
            cancelSpeculativeHandback()
            fallbackTransitionID = nil
            _ = coordinator.beginInterruption()
            generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
            saveDocumentProgress()
        case .ended:
            guard systemInterruptionActive else { return }
            systemInterruptionActive = false
            interruptionRevision &+= 1
            guard coordinator.contract?.lifecycle == .suspended else { return }
            let resume = shouldResume && wasPlayingBeforeInterruption && coordinator.desiredPlayIntent == .playing
            wasPlayingBeforeInterruption = false
            _ = coordinator.endInterruption(shouldResume: false)
            // The audio session must be prepared again before either producer starts.
            if deferredSeekTarget != nil { resumeDeferredSeek(shouldPlay: resume) }
            else if resume { play() }
        @unknown default: break
        }
    }
    func rebuildAfterMediaReset() {
        let offset = resumeSourceOffset
        audioPreparationID = nil
        interruptionRevision &+= 1
        systemInterruptionActive = false
        generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        generationGate.invalidate()
        isGenerationActive = false
        pause()
        AppAudioSession.shared.invalidate(reason: "media-services-reset")
        cancelPendingSeek()
        deferredSeekTarget = nil
        removeTimeObserver(); removeEndObserver(); removePlayerObservers()
        removeQueuedItems()
        queuePlayer = AVQueuePlayer()
        queuePlayer?.automaticallyWaitsToMinimizeStalling = false
        coordinator.appleProducer.rebuildAfterMediaReset()
        setupTimeObserver(); setupEndObserver(); setupPlayerObservers()
        // Explicit user Play performs positioning/regeneration. No auto-resume.
        chunks.removeAll()
        generationEOF = false
        recoverySeekOffset = offset
        currentWord = nil
        if coordinator.contract?.lifecycle == .suspended { _ = coordinator.endInterruption(shouldResume: false) }
        coordinator.syncCursor(toUTF16Offset: offset)
    }

    func handlePlaybackItemFailure(_ item: AVPlayerItem, error: Error?) {
        guard pendingSeek == nil, activeQueueItems.contains(ObjectIdentifier(item)), !coordinator.isAppleActive,
              coordinator.desiredPlayIntent == .playing else { return }
        queueItemFailures[ObjectIdentifier(item)] = error ?? NSError(domain: "Plume.QueueItem", code: 1)
        guard queuePlayer?.currentItem === item else { return }
        let offset = resumeSourceOffset
        PlaybackDiagnostics.shared.record("item-failed code=\((error as NSError?)?.code ?? 0)")
        audioPreparationID = nil
        fallbackTransitionID = nil
        generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        queuePlayer?.pause()
        setActualPlayback(false)
        removeQueuedItems()
        chunks.removeAll()
        generationEOF = false
        virtualBaseOffset = currentTime
        duration = currentTime
        currentWord = nil
        coordinator.syncCursor(toUTF16Offset: offset)
        reconcilePlayback(explicit: false)
    }
}
