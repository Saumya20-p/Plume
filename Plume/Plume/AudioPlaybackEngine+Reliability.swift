import SwiftData
import Foundation
import AVFoundation
import Combine

extension AudioPlaybackEngine {
    func reactivateCompletedRun(at offset: Int) {
        guard let current = coordinator.contract, current.lifecycle == .completed, let document = currentDocument else { return }
        let preferences = VoicePreferences(primary: current.primaryVoice, fallbackAppleVoiceIdentifier: current.fallbackAppleVoiceIdentifier)
        _ = coordinator.begin(document: document, snapshot: PlaybackSessionSnapshot(documentID: document.id, preferences: preferences),
            resumeCursor: PlaybackSourceCursor(segmentOrdinal: 0, globalUTF16Offset: min(max(0, offset), document.bodyText.utf16.count)),
            speechRateMultiplier: playbackRate)
        completedRunID = nil
        generationEOF = false
        deliveredWords.removeAll()
        recoveryBudget = PlaybackRecoveryBudget()
    }

    var resumeSourceOffset: Int {
        pendingSeek?.characterOffset ?? recoverySeekOffset ?? currentWord?.rangeLocation ?? coordinator.contract?.displayCursor?.globalUTF16Offset ?? currentDocument?.lastReadCharIndex ?? 0
    }

    var isPreparingCurrentPlayback: Bool {
        coordinator.desiredPlayIntent == .playing && !actualPlaybackActive && !generationFailed &&
        (pendingSeek != nil || isGenerationActive || audioPreparationID != nil || isWaitingForForeground)
    }

    var exactTotalDuration: TimeInterval? {
        guard !coordinator.isAppleActive else { return nil }
        if case .legacy? = chunks.first?.identity { return duration }
        guard generationEOF, virtualBaseOffset == 0,
              case .generated(let first)? = chunks.first?.identity, first.segmentID.ordinal == 0 else { return nil }
        return duration
    }

    var displayTotalDuration: TimeInterval { exactTotalDuration ?? max(duration, currentDocument?.estimatedDuration ?? 0) }

    func prepareAudioSession(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if let prepareAudioOverride { prepareAudioOverride(completion) }
        else { AppAudioSession.shared.prepare(owner: audioSessionOwner, reason: "playback-reconcile", completion: completion) }
    }

    func handleLifecycle(_ phase: PlaybackAppPhase) {
        applicationPhase = phase
        if phase != .active {
            recordListeningSession()
            saveDocumentProgress()
            cancelSpeculativeHandback()
            // Existing audio stays in its queue; only GPU work is suspended.
            return
        }
        guard coordinator.contract?.lifecycle != .completed else { return }
        if coordinator.desiredPlayIntent == .paused {
            coordinator.restorePausedPrimary(at: resumeSourceOffset)
            return
        }
        reconcilePlayback(explicit: false)
    }

    func reconcilePlayback(explicit: Bool) {
        guard pendingSeek == nil, let document = currentDocument,
              coordinator.contract?.lifecycle != .completed,
              coordinator.desiredPlayIntent == .playing else { return }
        if coordinator.contract?.lifecycle == .suspended {
            return
        }
        if coordinator.isAppleActive {
            if isAudioReady { _ = coordinator.play() }
            else { prepareReaderAudioSession(reason: "apple-resume") }
            if applicationPhase == .active, coordinator.isFallbackActive { triggerSpeculativeHandbackPreparation(for: document) }
            return
        }
        if generationEOF && activeQueueItems.isEmpty { completeLogicalPlayback(); return }
        if let item = queuePlayer?.currentItem, item.status != .failed, !activeQueueItems.isEmpty {
            if isAudioReady { startPreparedPlayback() }
            else { prepareReaderAudioSession(reason: "buffered-resume") }
            if applicationPhase == .active, !generationEOF, !generationFailed,
               !generationManager.generatingDocumentIDs.contains(document.id),
               case .generated(let identity)? = chunks.last?.identity {
                generationManager.generate(document: document, playbackEngine: self,
                    startChunkIndex: identity.segmentID.ordinal + 1, preservingPlaybackSession: true)
            }
            return
        }
        if queuePlayer?.currentItem?.status == .failed {
            if let item = queuePlayer?.currentItem { handlePlaybackItemFailure(item, error: item.error) }
            return
        }
        if generationFailed && !explicit { pause(); return }
        if applicationPhase != .active {
            if applicationPhase == .background && allowsAutomaticFallback {
                triggerFallbackToAppleSpeech(reason: "background-buffer-exhausted")
            } else { waitForSafeGeneration() }
            return
        }
        isWaitingForForeground = false
        if generationManager.generatingDocumentIDs.contains(document.id) { return }
        let segments = TextSegmenter.segment(documentID: document.id, text: document.bodyText)
        let offset = resumeSourceOffset
        let index = segments.firstIndex { NSMaxRange($0.nsRange) > offset } ?? segments.count
        if !explicit && !recoveryBudget.allow(segment: index, now: listeningClock()) {
            pause()
            generationManager.reportPlaybackFailure(NSError(domain: "Plume.PlaybackRecovery", code: 1),
                engine: self, stage: "buffer recovery")
            return
        }
        PlaybackDiagnostics.shared.record("recover run=\(coordinator.contract!.sessionID) segment=\(index) explicit=\(explicit)")
        // The standard seek pipeline keeps source position and prevents stale
        // audio from starting before the destination has been positioned.
        generationFailed = false
        seek(toCharIndex: offset, playAfterSeek: true)
    }

    func waitForSafeGeneration() {
        if generationFailed { pause(); return }
        audioPreparationID = nil
        queuePlayer?.pause()
        setActualPlayback(false)
        isWaitingForForeground = true
        isPlaying = coordinator.desiredPlayIntent == .playing
        AppAudioSession.shared.release(owner: audioSessionOwner, reason: "waiting-for-primary")
    }

    func reconcileFallbackPreference() {
        coordinator.automaticFallbackAllowed = allowsAutomaticFallback
        if !allowsAutomaticFallback { fallbackTransitionID = nil }
        guard coordinator.isFallbackActive else {
            if isWaitingForForeground { reconcilePlayback(explicit: false) }
            return
        }
        if applicationPhase == .active, let document = currentDocument { triggerSpeculativeHandbackPreparation(for: document) }
    }

    func generationReachedEOF(sessionID: UUID) {
        guard generationGate.isActive(sessionID: sessionID) else { return }
        generationEOF = true
        if activeQueueItems.isEmpty { completeLogicalPlayback() }
    }

    func completeLogicalPlayback() {
        guard pendingSeek == nil, let document = currentDocument, let run = coordinator.contract?.sessionID,
              completedRunID != run else { return }
        guard coordinator.completeAtEOF() else { return }
        completedRunID = run
        currentTime = displayTotalDuration
        currentWord = nil
        document.lastReadCharIndex = document.bodyText.utf16.count
        document.progress = document.readingProgress
        try? document.modelContext?.save()
        generationManager.cancelCurrentGeneration(preservingPlaybackIntent: true)
        cancelSpeculativeHandback()
        fallbackTransitionID = nil
        queuePlayer?.pause()
        isPlaying = false; isGenerationActive = false; isWaitingForForeground = false
        setActualPlayback(false)
        recordListeningSession()
        updateNowPlayingPlaybackInfo()
        evaluateAudioSession()
        PlaybackDiagnostics.shared.record("completed run=\(run)")
        let revision = seekRevision
        Task { @MainActor [weak self] in
            guard let self, self.completedRunID == run, self.coordinator.contract?.sessionID == run,
                  self.seekRevision == revision, self.coordinator.contract?.lifecycle == .completed else { return }
            self.advanceQueue()
        }
    }

    func saveDocumentProgressIfNeeded() {
        if abs(currentTime - lastProgressSaveTime) >= 5 { saveDocumentProgress() }
    }
}
