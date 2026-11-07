import AVFoundation
import Foundation

extension AudioPlaybackEngine {
    struct AudioPreferencesSnapshot: Equatable {
        let speed: Double
        let voice: VoicePreferences
        let automaticFallback: Bool
        static func current() -> Self {
            Self(speed: UserDefaults.standard.double(forKey: "defaultPlaybackSpeed"),
                 voice: VoicePreferencesStore().load(), automaticFallback: PlaybackPreferences.automaticFallback)
        }
    }

    func handleAudioPreferencesChange() {
        let snapshot = AudioPreferencesSnapshot.current()
        guard snapshot != audioPreferencesSnapshot else { return }
        audioPreferencesSnapshot = snapshot
        userDefaultsDebounceTimer?.invalidate()
        userDefaultsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateEffectivePlaybackRate()
                self.reconcileFallbackPreference() // Voice choices remain snapshotted for this run.
            }
        }
    }

    func prepareReaderAudioSession(reason: String) {
        guard !systemInterruptionActive, let documentID = currentDocument?.id else { return }
        let sessionID = coordinator.contract?.sessionID
        let seekRevision = self.seekRevision
        let interruptionRevision = self.interruptionRevision
        let requestID = UUID()
        audioPreparationID = requestID
        prepareAudioSession { [weak self] result in
            guard let self, self.audioPreparationID == requestID,
                  self.currentDocument?.id == documentID,
                  self.coordinator.contract?.sessionID == sessionID,
                  self.seekRevision == seekRevision,
                  self.interruptionRevision == interruptionRevision,
                  !self.systemInterruptionActive else { return }
            self.audioPreparationID = nil
            switch result {
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                self.pause()
                self.coordinator.reportAudioSessionFailure(error)
                self.generationManager.reportPlaybackFailure(error, engine: self, stage: "audio session preparation")
            case .success:
                if !self.hasPrewarmedSpeech && !self.isPlaying {
                    self.hasPrewarmedSpeech = true
                    self.prewarmSynthesizer.usesApplicationAudioSession = true
                    let utterance = AVSpeechUtterance(string: " ")
                    utterance.volume = 0
                    self.prewarmSynthesizer.speak(utterance)
                }
                self.startPreparedPlayback()
            }
        }
    }

    func startPreparedPlayback() {
        guard !systemInterruptionActive, isAudioReady, pendingSeek == nil,
              isPlaying, coordinator.desiredPlayIntent == .playing else { return }
        guard coordinator.play() else { isPlaying = false; return }
        if !coordinator.isAppleActive {
            isRecoveringFromUnderrun = false
            queuePlayer?.play()
            queuePlayer?.rate = playbackRate
        }
        sampleActualPlayback()
        updateNowPlayingPlaybackInfo()
    }

    func resumeQueuedPlayback() {
        guard !systemInterruptionActive, isPlaying, pendingSeek == nil, !coordinator.isAppleActive else { return }
        guard isAudioReady else {
            if audioPreparationID == nil { prepareReaderAudioSession(reason: "queue-resume") }
            return
        }
        queuePlayer?.play()
        queuePlayer?.rate = playbackRate
    }
}
