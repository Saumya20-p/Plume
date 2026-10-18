import AVFoundation
import Foundation

extension AudioPlaybackEngine {
    struct AudioPreferencesSnapshot: Equatable {
        let speed: Double
        let voice: VoicePreferences
        static func current() -> Self {
            Self(speed: UserDefaults.standard.double(forKey: "defaultPlaybackSpeed"),
                 voice: VoicePreferencesStore().load())
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
                self.coordinator.updateVoicePreferences(VoicePreferencesStore().load())
            }
        }
    }

    func prepareReaderAudioSession(reason: String) {
        guard let documentID = currentDocument?.id else { return }
        let sessionID = coordinator.contract?.sessionID
        let seekRevision = self.seekRevision
        let requestID = UUID()
        audioPreparationID = requestID
        AppAudioSession.shared.prepare(owner: audioSessionOwner, reason: reason) { [weak self] result in
            guard let self, self.audioPreparationID == requestID,
                  self.currentDocument?.id == documentID,
                  self.coordinator.contract?.sessionID == sessionID else { return }
            self.audioPreparationID = nil
            switch result {
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                self.pause()
                self.coordinator.reportAudioSessionFailure(error)
            case .success:
                if !self.hasPrewarmedSpeech && !self.isPlaying {
                    self.hasPrewarmedSpeech = true
                    self.prewarmSynthesizer.usesApplicationAudioSession = true
                    let utterance = AVSpeechUtterance(string: " ")
                    utterance.volume = 0
                    self.prewarmSynthesizer.speak(utterance)
                }
                guard self.seekRevision == seekRevision else { return }
                self.startPreparedPlayback()
            }
        }
    }

    func startPreparedPlayback() {
        guard AppAudioSession.shared.isReady(owner: audioSessionOwner), pendingSeek == nil,
              isPlaying, coordinator.desiredPlayIntent == .playing else { return }
        guard coordinator.play() else { isPlaying = false; return }
        if !coordinator.isAppleActive {
            isRecoveringFromUnderrun = false
            queuePlayer?.play()
            queuePlayer?.rate = playbackRate
        }
        wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        updateNowPlayingPlaybackInfo()
    }

    func resumeQueuedPlayback() {
        guard isPlaying, pendingSeek == nil, !coordinator.isAppleActive else { return }
        guard AppAudioSession.shared.isReady(owner: audioSessionOwner) else {
            if audioPreparationID == nil { prepareReaderAudioSession(reason: "queue-resume") }
            return
        }
        queuePlayer?.play()
        queuePlayer?.rate = playbackRate
    }
}
