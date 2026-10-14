import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftData
import os
import UIKit

extension AudioPlaybackEngine {
    func performSeek(to targetTime: TimeInterval) {
        cancelSpeculativeHandback()
        recordListeningSession()
        saveDocumentProgress()
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        
        let totalDuration = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        let safeTargetTime = max(0, min(targetTime, totalDuration))
        
        if coordinator.isAppleActive {
            coordinator.seek(to: safeTargetTime)
            self.currentTime = safeTargetTime
            if isPlaying {
                wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                if UIApplication.shared.applicationState != .background {
                    triggerSpeculativeHandbackPreparation(for: doc)
                }
            }
            updateNowPlayingPlaybackInfo()
            return
        }
        
        let currentVirtualStartTime = chunks.first?.globalStartTime ?? virtualBaseOffset
        let currentVirtualEndTime = chunks.last.map { $0.globalStartTime + $0.duration } ?? virtualBaseOffset
        if safeTargetTime >= currentVirtualStartTime && safeTargetTime <= currentVirtualEndTime, !chunks.isEmpty {
            let wasPlaying = isPlaying
            queuePlayer?.pause()
            queuePlayer?.removeAllItems()
            var localSeekTime: TimeInterval = 0
            var foundStartChunk = false
            for chunk in chunks {
                if !foundStartChunk && safeTargetTime >= chunk.globalStartTime && safeTargetTime <= chunk.globalStartTime + chunk.duration {
                    foundStartChunk = true
                    localSeekTime = safeTargetTime - chunk.globalStartTime
                }
                if foundStartChunk {
                    queuePlayer?.insert(AVPlayerItem(url: chunk.url), after: nil)
                }
            }
            if let firstItem = queuePlayer?.items().first {
                currentSeekTask?.cancel()
                currentSeekTask = Task { @MainActor [weak self, weak firstItem] in
                    guard let self = self, let firstItem = firstItem else { return }
                    
                    // Wait for the item to load (local files load almost instantly)
                    while firstItem.status == .unknown {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    }
                    
                    if Task.isCancelled { return }
                    if firstItem.status == .readyToPlay {
                        firstItem.seek(to: CMTime(seconds: localSeekTime, preferredTimescale: 600), completionHandler: nil)
                        if self.isPlaying {
                            self.queuePlayer?.play()
                            self.queuePlayer?.rate = self.playbackRate
                            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                        }
                    }
                }
            } else {
                if wasPlaying {
                    queuePlayer?.play()
                    queuePlayer?.rate = playbackRate
                    self.isPlaying = true
                    self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                }
            }
            self.currentTime = safeTargetTime
            updateNowPlayingPlaybackInfo()
            return
        }
        
        let wasPlaying = isPlaying
        queuePlayer?.pause()
        
        // 1. Coordinate with AudioGenerationManager
        AudioGenerationManager.shared.cancelCurrentGeneration()
        
        // 2. Clear items and chunks
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        
        // 3. Set virtualBaseOffset
        virtualBaseOffset = safeTargetTime
        self.currentTime = safeTargetTime
        self.duration = safeTargetTime
        
        // 4. Calculate chunk index
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        var targetChunkIndex = 0
        if !segments.isEmpty {
            let progress = safeTargetTime / totalDuration
            targetChunkIndex = Int(progress * Double(segments.count))
            targetChunkIndex = max(0, min(targetChunkIndex, segments.count - 1))
        }
        
        // 5. Generate
        isGenerationActive = true
        AudioGenerationManager.shared.generate(document: doc, playbackEngine: self, startChunkIndex: targetChunkIndex)
        
        updateNowPlayingPlaybackInfo()
        
        if wasPlaying {
            // It will resume automatically when enqueue is called in AudioGenerationManager if isFirst is handled correctly.
            // But we can also set isPlaying to true so UI knows it's playing
            self.isPlaying = true
            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        }
    }

    func performSeek(toCharIndex charIndex: Int) {
        cancelSpeculativeHandback()
        recordListeningSession()
        saveDocumentProgress()
        PlaybackProgress.shared.currentWord = nil
        guard let doc = currentDocument else { return }
        coordinator.syncCursor(toUTF16Offset: charIndex)
        
        if coordinator.isAppleActive {
            coordinator.seek(toUTF16Offset: charIndex)
            self.currentTime = coordinator.estimatedCurrentTime
            if isPlaying {
                wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
                if UIApplication.shared.applicationState != .background {
                    triggerSpeculativeHandbackPreparation(for: doc)
                }
            }
            updateNowPlayingPlaybackInfo()
            return
        }
        
        var matchedChunkTime: TimeInterval? = nil
        for chunk in chunks {
            for ts in chunk.timestamps {
                if let loc = ts.rangeLocation, let len = ts.rangeLength {
                    if charIndex >= loc && charIndex <= (loc + len) {
                        matchedChunkTime = chunk.globalStartTime + ts.startTime
                        break
                    }
                }
            }
            if matchedChunkTime != nil { break }
        }
        if let time = matchedChunkTime {
            performSeek(to: time)
            return
        }
        
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        guard !segments.isEmpty else { return }
        
        var targetChunkIndex = segments.count - 1
        for (index, chunk) in segments.enumerated() {
            let start = chunk.range.lowerBound.utf16Offset(in: doc.bodyText)
            let end = chunk.range.upperBound.utf16Offset(in: doc.bodyText)
            if charIndex < start {
                targetChunkIndex = max(0, index - 1)
                break
            }
            if charIndex >= start && charIndex <= end {
                targetChunkIndex = index
                break
            }
        }
        
        for chunk in chunks {
            if case .generated(let identity) = chunk.identity,
               identity.segmentID.ordinal == targetChunkIndex {
                performSeek(to: chunk.globalStartTime)
                return
            }
        }
        
        let totalDuration = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        let safeTargetTime = totalDuration * (Double(targetChunkIndex) / Double(segments.count))
        
        let wasPlaying = isPlaying
        queuePlayer?.pause()
        
        AudioGenerationManager.shared.cancelCurrentGeneration()
        queuePlayer?.removeAllItems()
        chunks.removeAll()
        
        virtualBaseOffset = safeTargetTime
        self.currentTime = safeTargetTime
        self.duration = safeTargetTime
        isRecoveringFromUnderrun = false
        
        isGenerationActive = true
        AudioGenerationManager.shared.generate(document: doc, playbackEngine: self, startChunkIndex: targetChunkIndex)
        
        updateNowPlayingPlaybackInfo()
        
        if wasPlaying {
            self.isPlaying = true
            self.wallClockSessionStartTime = Date().timeIntervalSinceReferenceDate
        }
    }

}
