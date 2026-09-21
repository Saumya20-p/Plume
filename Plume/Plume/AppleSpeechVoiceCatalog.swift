import AVFoundation
import Foundation
import Observation

nonisolated enum AppleSpeechVoiceQuality: Int, Codable, Comparable, Sendable {
    case enhanced
    case premium

    static func < (lhs: AppleSpeechVoiceQuality, rhs: AppleSpeechVoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct AppleSpeechVoiceDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: AppleSpeechVoiceQuality
}

nonisolated enum AppleSpeechVoiceCandidateQuality: Sendable {
    case `default`
    case enhanced
    case premium
}

nonisolated struct AppleSpeechVoiceCandidate: Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: AppleSpeechVoiceCandidateQuality
    let isNoveltyVoice: Bool
    let isPersonalVoice: Bool
}

@MainActor
protocol AppleSpeechVoiceProviding: AnyObject {
    func availableVoices() -> [AppleSpeechVoiceCandidate]
}

@MainActor
protocol AppleSpeechVoiceChangeObservation: AnyObject {
    func cancel()
}

@MainActor
protocol AppleSpeechVoiceChangeObserving: AnyObject {
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleSpeechVoiceChangeObservation
}

@MainActor
final class AVFoundationSpeechVoiceProvider: AppleSpeechVoiceProviding {
    func availableVoices() -> [AppleSpeechVoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            AppleSpeechVoiceCandidate(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: candidateQuality(for: voice.quality),
                isNoveltyVoice: voice.voiceTraits.contains(.isNoveltyVoice),
                isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
            )
        }
    }

    private func candidateQuality(for quality: AVSpeechSynthesisVoiceQuality) -> AppleSpeechVoiceCandidateQuality {
        switch quality {
        case .enhanced:
            return .enhanced
        case .premium:
            return .premium
        default:
            return .default
        }
    }
}

@MainActor
final class AVFoundationSpeechVoiceChangeObserver: AppleSpeechVoiceChangeObserving {
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleSpeechVoiceChangeObservation {
        NotificationSpeechVoiceChangeObservation(center: center, handler: handler)
    }
}

@MainActor
private final class NotificationSpeechVoiceChangeObservation: AppleSpeechVoiceChangeObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    func cancel() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    isolated deinit {
        cancel()
    }
}

@Observable
@MainActor
final class AppleSpeechVoiceCatalog {
    private(set) var voices: [AppleSpeechVoiceDescriptor]

    @ObservationIgnored private let provider: any AppleSpeechVoiceProviding
    @ObservationIgnored private var changeObservation: (any AppleSpeechVoiceChangeObservation)?

    init(
        provider: (any AppleSpeechVoiceProviding)? = nil,
        changeObserver: (any AppleSpeechVoiceChangeObserving)? = nil
    ) {
        let provider = provider ?? AVFoundationSpeechVoiceProvider()
        let changeObserver = changeObserver ?? AVFoundationSpeechVoiceChangeObserver()
        self.provider = provider
        self.voices = Self.filteredAndSorted(provider.availableVoices())
        self.changeObservation = changeObserver.observeChanges { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        voices = Self.filteredAndSorted(provider.availableVoices())
    }

    isolated deinit {
        changeObservation?.cancel()
    }

    private static func filteredAndSorted(
        _ candidates: [AppleSpeechVoiceCandidate]
    ) -> [AppleSpeechVoiceDescriptor] {
        candidates.compactMap { candidate in
            guard
                isEnglish(candidate.language),
                !candidate.isNoveltyVoice,
                !candidate.isPersonalVoice
            else {
                return nil
            }

            let quality: AppleSpeechVoiceQuality
            switch candidate.quality {
            case .default:
                return nil
            case .enhanced:
                quality = .enhanced
            case .premium:
                quality = .premium
            }

            return AppleSpeechVoiceDescriptor(
                id: candidate.identifier,
                name: candidate.name,
                language: candidate.language,
                quality: quality
            )
        }
        .sorted { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality
            }
            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func isEnglish(_ language: String) -> Bool {
        Locale.Language(identifier: language).languageCode?.identifier == "en"
    }
}
