import AVFoundation
import Foundation
import NaturalLanguage
import UIKit

nonisolated struct ListeningAccumulator {
    private(set) var seconds: TimeInterval = 0
    private(set) var words = 0
    private var activeSince: TimeInterval?
    mutating func activity(_ active: Bool, at now: TimeInterval) {
        sample(at: now)
        activeSince = active ? now : nil
    }
    mutating func sample(at now: TimeInterval) {
        if let start = activeSince { seconds += max(0, now - start); activeSince = now }
    }
    mutating func addWord() { words += 1 }
    mutating func take(at now: TimeInterval) -> (seconds: TimeInterval, words: Int) {
        sample(at: now)
        let result = (seconds, words)
        seconds = 0; words = 0
        return result
    }
}

nonisolated enum ListeningMetrics {
    static func wpm(words: Int, seconds: TimeInterval) -> Double? {
        guard seconds > 0, seconds.isFinite, words >= 0 else { return nil }
        return 60 * Double(words) / seconds
    }
}

/// Media-time bounds belong to one queue item in one listening traversal.
/// A seek creates a fresh item with a nonzero floor; pauses retain this cursor.
nonisolated struct KokoroListeningTraversal {
    let start: TimeInterval
    var sampledThrough: TimeInterval
    init(start: TimeInterval = 0) { self.start = start; sampledThrough = start }
    mutating func completedWords(_ timestamps: [WordTimestamp], through time: TimeInterval) -> [WordTimestamp] {
        guard time.isFinite, time >= sampledThrough else { return [] }
        let previous = sampledThrough
        sampledThrough = time
        return timestamps.filter { $0.startTime >= start && $0.endTime > previous && $0.endTime <= time }
    }
}

nonisolated struct ReaderAwakeContext: Equatable {
    var enabled: Bool
    var visible: Bool
    var active: Bool
    var intended: Bool
    var advancing: Bool
    var preparing: Bool
    var blocked: Bool
    var shouldHold: Bool { enabled && visible && active && intended && !blocked && (advancing || preparing) }
}

@MainActor final class ReaderIdleTimer {
    static let shared = ReaderIdleTimer()
    private var held = false
    private let apply: @MainActor (Bool) -> Void
    init(apply: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) { self.apply = apply }
    func update(_ context: ReaderAwakeContext) { set(context.shouldHold) }
    func release() { set(false) }
    private func set(_ value: Bool) {
        guard value != held else { return }
        held = value
        apply(value)
    }
}

extension AudioPlaybackEngine {
    func resetWordAccounting(_ text: String) {
        recordListeningSession()
        deliveredWords.removeAll()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [UTF16TextRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if PlaybackSourceProgress.hasSpeech(String(text[range])) { ranges.append(UTF16TextRange(NSRange(range, in: text))) }
            return true
        }
        listeningWordRanges = ranges
    }
    func countDeliveredWords(_ range: UTF16TextRange) {
        guard coordinator.desiredPlayIntent == .playing, range.length > 0 else { return }
        // Binary search limits work to the delivered token, rather than scanning
        // an entire chapter on each word callback.
        var lo = 0, hi = listeningWordRanges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if listeningWordRanges[mid].upperBound <= range.location { lo = mid + 1 } else { hi = mid }
        }
        while lo < listeningWordRanges.count && listeningWordRanges[lo].location < range.upperBound {
            if deliveredWords.insert(lo).inserted { listeningAccumulator.addWord() }
            lo += 1
        }
    }
    func observeDeliveredKokoroWords(in chunk: PlayedChunk, item: AVPlayerItem, time: TimeInterval, finishing: Bool = false) {
        guard actualPlaybackActive || finishing,
              var traversal = listeningItems[ObjectIdentifier(item)] else { return }
        let words = traversal.completedWords(chunk.timestamps, through: time)
        listeningItems[ObjectIdentifier(item)] = traversal
        for word in words {
            if let location = word.rangeLocation, let length = word.rangeLength {
                countDeliveredWords(UTF16TextRange(location: location, length: length))
            }
        }
    }
    func setActualPlayback(_ active: Bool) {
        let active = active && coordinator.desiredPlayIntent == .playing && coordinator.contract?.lifecycle == .active
        let now = listeningClock()
        if active, let lastActualSample { recoveryBudget.verifiedPlayback(seconds: now - lastActualSample) }
        if !active { recoveryBudget.stoppedPlayback() }
        lastActualSample = active ? now : nil
        listeningAccumulator.activity(active, at: now)
        if actualPlaybackActive != active {
            actualPlaybackActive = active
            if !active { recordListeningSession() }
        }
    }
    func sampleActualPlayback() {
        if !coordinator.isAppleActive {
            setActualPlayback(pendingSeek == nil && isAudioReady && queuePlayer?.timeControlStatus == .playing)
        }
        listeningAccumulator.sample(at: listeningClock())
        if listeningAccumulator.seconds >= 15 { recordListeningSession() }
    }
}
