import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
    func checkKokoroBufferUnderrun() {
        guard (isPlaying || coordinator.contract?.desiredPlayIntent == .playing), !coordinator.isAppleActive, currentDocument != nil else { return }
        
        let runway = bufferedTime - currentTime
        let itemsCount = queuePlayer?.items().count ?? 0
        let isStalled = queuePlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let hasDepletedRunway = !chunks.isEmpty && (itemsCount == 0 || (runway <= 0.1 && isStalled))
        
        if hasDepletedRunway && !hasReachedDocumentEnd {
            Log.audio.warning("Kokoro buffer underrun detected (runway: \(runway, privacy: .public)s, items: \(itemsCount)). Triggering fallback to Apple Speech.")
            triggerFallbackToAppleSpeech(reason: "Kokoro audio buffer underrun (runway: \(runway)s)")
        }
    }

    func triggerSpeculativeHandbackPreparation(for doc: Document) {
        guard coordinator.isFallbackActive else { return }
        
        let targetSegmentIndex = coordinator.currentOrUpcomingSegmentIndex
        guard targetSegmentIndex < coordinator.segmentsCount else {
            Log.audio.info("Speculative handback: already at or past the end of document segments.")
            return
        }

        Log.audio.info("Starting speculative preparation for document \(doc.id) from segment \(targetSegmentIndex).")
        AudioGenerationManager.shared.startSpeculativePreparation(
            document: doc,
            playbackEngine: self,
            startChunkIndex: targetSegmentIndex
        )
    }

    func resumeFromHandback(chunks: [AudioChunk], session: PlaybackGenerationSession?) {
        guard let doc = currentDocument, !chunks.isEmpty else { return }
        Log.audio.info("AudioPlaybackEngine resuming Kokoro playback from handback with \(chunks.count) chunk(s).")

        // 1. Activate session gate if provided
        if let session {
            generationGate.activate(session)
        }

        // 2. Tear down any residual Apple Speech playback and clear old Kokoro items
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        self.chunks.removeAll()

        // 3. Set the virtualBaseOffset to current progress or the start of the first chunk
        let currentEstimated = coordinator.estimatedCurrentTime
        self.virtualBaseOffset = currentEstimated
        self.currentTime = currentEstimated

        // 4. Transform AudioChunks into PlayedChunks and insert into queuePlayer
        var playedChunks: [PlayedChunk] = []
        var runningOffset = currentEstimated

        for chunk in chunks {
            let playedChunk = PlayedChunk(
                chunk: chunk,
                globalStartTime: runningOffset
            )
            playedChunks.append(playedChunk)
            runningOffset += chunk.duration
            queuePlayer?.insert(AVPlayerItem(url: chunk.fileURL), after: nil)
        }

        self.chunks = playedChunks
        self.duration = runningOffset

        // 5. Resume playback if desired
        let shouldPlay = self.isPlaying || (self.coordinator.contract?.desiredPlayIntent == .playing)
        isGenerationActive = true
        if shouldPlay {
            queuePlayer?.play()
            queuePlayer?.rate = playbackRate
            isPlaying = true
            wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        } else {
            queuePlayer?.pause()
            isPlaying = false
        }
        updateNowPlayingPlaybackInfo()

        // 6. Resume continuous Kokoro generation for remaining chunks
        let nextChunkIndex = (chunks.last?.identity.segmentID.ordinal ?? 0) + 1
        Log.audio.info("Resuming continuous Kokoro generation from segment \(nextChunkIndex).")
        AudioGenerationManager.shared.generate(
            document: doc,
            playbackEngine: self,
            startChunkIndex: nextChunkIndex
        )
    }

}
