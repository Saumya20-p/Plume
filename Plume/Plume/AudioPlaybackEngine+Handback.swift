import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
    func checkKokoroBufferUnderrun() {
        guard pendingSeek == nil, coordinator.desiredPlayIntent == .playing,
              !coordinator.isAppleActive, currentDocument != nil else { return }
        // End notifications own completion. Do not race them at the final item.
        guard activeQueueItems.isEmpty else { return }
        if generationEOF { completeLogicalPlayback() }
        else { reconcilePlayback(explicit: false) }
    }

    func triggerSpeculativeHandbackPreparation(for doc: Document) {
        guard pendingSeek == nil, coordinator.isFallbackActive, applicationPhase == .active, coordinator.desiredPlayIntent == .playing else { return }
        
        let targetSegmentIndex = coordinator.currentOrUpcomingSegmentIndex
        guard targetSegmentIndex < coordinator.segmentsCount else {
            Log.audio.info("Speculative handback: already at or past the end of document segments.")
            return
        }

        Log.audio.info("Starting speculative preparation for document \(doc.id) from segment \(targetSegmentIndex).")
        generationManager.startSpeculativePreparation(
            document: doc,
            playbackEngine: self,
            startChunkIndex: targetSegmentIndex
        )
    }

    func resumeFromHandback(chunks: [AudioChunk], session: PlaybackGenerationSession?) {
        guard pendingSeek == nil, let doc = currentDocument, !chunks.isEmpty else { return }
        Log.audio.info("AudioPlaybackEngine resuming Kokoro playback from handback with \(chunks.count) chunk(s).")

        // 1. Activate session gate if provided
        if let session {
            generationGate.activate(session)
        }

        // 2. Tear down any residual Apple Speech playback and clear old Kokoro items
        queuePlayer?.pause()
        removeQueuedItems()
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
            insertQueuedItem(AVPlayerItem(url: chunk.fileURL))
        }

        self.chunks = playedChunks
        self.duration = runningOffset

        // 5. Resume playback if desired
        let shouldPlay = self.coordinator.desiredPlayIntent == .playing
        generationEOF = false
        isGenerationActive = true
        if shouldPlay {
            isPlaying = true
            resumeQueuedPlayback()
            wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        } else {
            queuePlayer?.pause()
            isPlaying = false
        }
        updateNowPlayingPlaybackInfo()

        // 6. Resume continuous Kokoro generation for remaining chunks
        let nextChunkIndex = (chunks.last?.identity.segmentID.ordinal ?? 0) + 1
        Log.audio.info("Resuming continuous Kokoro generation from segment \(nextChunkIndex).")
        generationManager.generate(
            document: doc,
            playbackEngine: self,
            startChunkIndex: nextChunkIndex, preservingPlaybackSession: true
        )
    }

}
