import Foundation
import AVFoundation
import UIKit
import os

extension AudioPlaybackEngine {
    struct PendingSeek {
        enum Phase { case debouncing, generating, positioning }
        let revision: Int
        let documentID: UUID
        var shouldPlay: Bool
        var characterOffset: Int?
        var phase: Phase = .debouncing
    }

    /// Silence the old destination immediately, without losing the user's intent.
    @discardableResult
    func beginSeek(playAfterSeek: Bool = false, characterOffset: Int? = nil) -> PendingSeek? {
        let shouldPlay = playAfterSeek || pendingSeek?.shouldPlay == true || coordinator.desiredPlayIntent == .playing
        cancelPendingSeek()
        cancelSpeculativeHandback()
        guard let document = currentDocument else { return nil }
        let request = PendingSeek(revision: seekRevision, documentID: document.id,
                                  shouldPlay: shouldPlay, characterOffset: characterOffset)
        pendingSeek = request
        recordListeningSession()
        saveDocumentProgress()
        queuePlayer?.pause()
        // Stop Apple speech before the debounce; do not restart its old cursor.
        if coordinator.isAppleActive { coordinator.pause() }
        isPlaying = shouldPlay
        currentWord = nil
        traceSeek("requested")
        return request
    }

    func isCurrentSeek(_ request: PendingSeek) -> Bool {
        pendingSeek?.revision == request.revision && seekRevision == request.revision &&
            currentDocument?.id == request.documentID
    }

    func performSeek(to targetTime: TimeInterval, request: PendingSeek? = nil) {
        guard targetTime.isFinite, let request = request ?? beginSeek(),
              isCurrentSeek(request), let doc = currentDocument else { return }
        let total = PlaybackSeekBounds.duration(completed: doc.audioFileURL != nil && !coordinator.isAppleActive,
                                                generated: duration, estimated: doc.estimatedDuration)
        let target = max(0, min(targetTime, total))
        if coordinator.isAppleActive {
            coordinator.seek(to: target)
            completeAppleSeek(request)
            return
        }
        if let index = chunks.firstIndex(where: { target >= $0.globalStartTime && target < $0.globalStartTime + $0.duration }) ??
            (target == chunks.last.map({ $0.globalStartTime + $0.duration }) ? chunks.indices.last : nil) {
            positionBufferedSeek(request, chunkIndex: index, localTime: target - chunks[index].globalStartTime)
            return
        }
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        guard !segments.isEmpty else { failSeek(request); return }
        let index = min(segments.count - 1, Int(target / max(1, total) * Double(segments.count)))
        coordinator.syncCursor(toUTF16Offset: segments[index].nsRange.location)
        regenerateForSeek(request, segmentIndex: index, estimatedTime: target)
    }

    func performSeek(toCharIndex charIndex: Int, request: PendingSeek? = nil) {
        guard let request = request ?? beginSeek(characterOffset: charIndex),
              isCurrentSeek(request), let doc = currentDocument else { return }
        let offset = min(max(0, charIndex), max(0, doc.bodyText.utf16.count - 1))
        pendingSeek?.characterOffset = offset
        coordinator.syncCursor(toUTF16Offset: offset)
        if coordinator.isAppleActive {
            coordinator.seek(toUTF16Offset: offset)
            completeAppleSeek(request)
            return
        }
        for (index, chunk) in chunks.enumerated() {
            if let timestamp = chunk.timestamps.first(where: {
                guard let start = $0.rangeLocation, let length = $0.rangeLength else { return false }
                return offset >= start && offset < start + length
            }) {
                positionBufferedSeek(request, chunkIndex: index, localTime: timestamp.startTime)
                return
            }
        }
        let segments = TextSegmenter.segment(documentID: doc.id, text: doc.bodyText)
        guard let index = segments.firstIndex(where: { NSMaxRange($0.nsRange) > offset }) else {
            failSeek(request); return
        }
        if let buffered = chunks.firstIndex(where: {
            if case .generated(let identity) = $0.identity { return identity.segmentID.ordinal == index }
            return false
        }) {
            positionBufferedSeek(request, chunkIndex: buffered, localTime: 0)
            return
        }
        let total = doc.estimatedDuration > 0 ? doc.estimatedDuration : max(duration, 1)
        regenerateForSeek(request, segmentIndex: index, estimatedTime: total * Double(index) / Double(segments.count))
    }

    private func completeAppleSeek(_ request: PendingSeek) {
        guard isCurrentSeek(request) else { return }
        let shouldPlay = pendingSeek?.shouldPlay == true
        currentTime = coordinator.estimatedCurrentTime
        traceSeek("positioned-apple")
        pendingSeek = nil
        if shouldPlay {
            play()
            if UIApplication.shared.applicationState != .background, let doc = currentDocument {
                triggerSpeculativeHandbackPreparation(for: doc)
            }
        } else { isPlaying = false }
        updateNowPlayingPlaybackInfo()
    }

    private func regenerateForSeek(_ request: PendingSeek, segmentIndex: Int, estimatedTime: TimeInterval) {
        guard isCurrentSeek(request), let doc = currentDocument else { return }
        pendingSeek?.phase = .generating
        traceSeek("cancel-generation")
        AudioGenerationManager.shared.cancelCurrentGeneration(preservingPlaybackIntent: true)
        removeQueuedItems()
        chunks.removeAll()
        virtualBaseOffset = estimatedTime
        currentTime = estimatedTime
        duration = estimatedTime
        isRecoveringFromUnderrun = false
        if pendingSeek?.shouldPlay == true { _ = coordinator.play() }
        traceSeek("generate", destination: Double(segmentIndex))
        AudioGenerationManager.shared.generate(document: doc, playbackEngine: self,
                                                startChunkIndex: segmentIndex, preservingPlaybackSession: true)
        updateNowPlayingPlaybackInfo()
    }

    /// Called before enqueue is allowed to start replacement audio.
    func positionGeneratedSeekIfNeeded() {
        guard let request = pendingSeek, request.phase == .generating, !chunks.isEmpty else { return }
        let offset = request.characterOffset
        let timestamp = offset.flatMap { target in
            chunks[0].timestamps.first { ($0.rangeLocation ?? -1) + ($0.rangeLength ?? 0) > target }
        }
        positionBufferedSeek(request, chunkIndex: 0, localTime: timestamp?.startTime ?? 0)
    }

    private func positionBufferedSeek(_ request: PendingSeek, chunkIndex: Int, localTime: TimeInterval) {
        guard isCurrentSeek(request), let player = queuePlayer else { failSeek(request); return }
        pendingSeek?.phase = .positioning
        player.pause()
        removeQueuedItems()
        for chunk in chunks[chunkIndex...] { insertQueuedItem(AVPlayerItem(url: chunk.url)) }
        guard let item = player.currentItem else { failSeek(request); return }
        let target = chunks[chunkIndex].globalStartTime + localTime
        currentTime = target
        traceSeek("positioning", destination: target, item: item)
        let operation = seekItemOperation
        currentSeekTask = Task { @MainActor [weak self, weak player, weak item] in
            guard let player, let item else { return }
            let finished = await operation(item, CMTime(seconds: localTime, preferredTimescale: 600))
            guard !Task.isCancelled, let self, self.isCurrentSeek(request),
                  self.queuePlayer === player, player.currentItem === item else { return }
            guard finished else { self.failSeek(request); return }
            self.traceSeek("positioned", destination: target)
            let shouldPlay = self.pendingSeek?.shouldPlay == true
            self.pendingSeek = nil
            self.currentSeekTask = nil
            self.currentTime = target
            if shouldPlay { self.play() }
            else { self.isPlaying = false }
            self.updateNowPlayingPlaybackInfo()
        }
        updateNowPlayingPlaybackInfo()
    }

    static func seekReadyItem(_ item: AVPlayerItem, to time: CMTime) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while item.status == .unknown {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        guard !Task.isCancelled, item.status == .readyToPlay else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--playback-seek-diagnostics") {
            Log.audio.debug("seek event=item-ready item=\(String(describing: ObjectIdentifier(item)), privacy: .public)")
        }
        #endif
        return await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func failSeek(_ request: PendingSeek) {
        guard isCurrentSeek(request) else { return }
        traceSeek("failed")
        pendingSeek = nil
        currentSeekTask = nil
        pause()
    }

    func insertQueuedItem(_ item: AVPlayerItem) {
        activeQueueItems.insert(ObjectIdentifier(item))
        queuePlayer?.insert(item, after: nil)
    }

    func removeQueuedItems() {
        activeQueueItems.removeAll()
        queuePlayer?.removeAllItems()
    }

    func traceSeek(_ event: String, destination: Double? = nil, item: AVPlayerItem? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--playback-seek-diagnostics") else { return }
        let route = coordinator.isAppleActive ? (coordinator.isFallbackActive ? "apple-fallback" : "apple") : "kokoro"
        let documentID = currentDocument?.id.uuidString ?? "none"
        let itemID = item.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        Log.audio.debug("seek document=\(documentID, privacy: .public) item=\(itemID, privacy: .public) event=\(event, privacy: .public) revision=\(self.seekRevision) route=\(route, privacy: .public) play=\(self.pendingSeek?.shouldPlay ?? (self.coordinator.desiredPlayIntent == .playing)) destination=\(destination ?? -1) generation=\(self.isGenerationActive)")
        #endif
    }
}
