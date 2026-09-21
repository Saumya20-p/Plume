import Foundation

nonisolated enum PlaybackVoiceID: Codable, Hashable, Sendable {
    case kokoro(identifier: String)
    case apple(identifier: String)

    var identifier: String {
        switch self {
        case .kokoro(let identifier), .apple(let identifier):
            identifier
        }
    }
}

nonisolated struct VoicePreferences: Equatable, Sendable {
    var primary: PlaybackVoiceID
    var fallbackAppleVoiceIdentifier: String?
}

@MainActor
final class VoicePreferencesStore {
    private enum Key {
        static let schemaVersion = "voicePreferences.schemaVersion"
        static let primaryKind = "voicePreferences.primary.kind"
        static let primaryIdentifier = "voicePreferences.primary.identifier"
        static let fallbackAppleIdentifier = "voicePreferences.fallback.appleIdentifier"
        static let legacyKokoroIdentifier = "kokoroVoice"
    }

    private enum VoiceKind: String {
        case kokoro
        case apple
    }

    private static let currentSchemaVersion = 1
    private static let defaultKokoroIdentifier = "af_heart"
    private static let currentKokoroIdentifiers: Set<String> = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis"
    ]

    private let defaults: UserDefaults
    private let knownKokoroIdentifiers: Set<String>

    init(
        defaults: UserDefaults = .standard,
        knownKokoroIdentifiers: Set<String>? = nil
    ) {
        self.defaults = defaults
        self.knownKokoroIdentifiers = knownKokoroIdentifiers ?? Self.currentKokoroIdentifiers
    }

    func load() -> VoicePreferences {
        migrateIfNeeded()

        let primary = storedPrimaryVoice()
            ?? .kokoro(identifier: Self.defaultKokoroIdentifier)
        let fallbackIdentifier = normalizedIdentifier(
            defaults.string(forKey: Key.fallbackAppleIdentifier)
        )

        return VoicePreferences(
            primary: primary,
            fallbackAppleVoiceIdentifier: fallbackIdentifier
        )
    }

    func save(_ preferences: VoicePreferences) {
        guard let primary = normalizedPrimary(preferences.primary) else { return }

        writePrimary(primary)

        if let fallbackIdentifier = normalizedIdentifier(preferences.fallbackAppleVoiceIdentifier) {
            defaults.set(fallbackIdentifier, forKey: Key.fallbackAppleIdentifier)
        } else {
            defaults.removeObject(forKey: Key.fallbackAppleIdentifier)
        }

        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    private func migrateIfNeeded() {
        let storedVersion = defaults.integer(forKey: Key.schemaVersion)
        if storedVersion >= Self.currentSchemaVersion, storedPrimaryVoice() != nil {
            return
        }

        if storedPrimaryVoice() == nil {
            let legacyIdentifier = normalizedIdentifier(
                defaults.string(forKey: Key.legacyKokoroIdentifier)
            ).flatMap { knownKokoroIdentifiers.contains($0) ? $0 : nil }
                ?? Self.defaultKokoroIdentifier
            writePrimary(.kokoro(identifier: legacyIdentifier))
        }

        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    private func storedPrimaryVoice() -> PlaybackVoiceID? {
        guard
            let rawKind = defaults.string(forKey: Key.primaryKind),
            let kind = VoiceKind(rawValue: rawKind),
            let identifier = normalizedIdentifier(defaults.string(forKey: Key.primaryIdentifier))
        else {
            return nil
        }

        switch kind {
        case .kokoro:
            guard knownKokoroIdentifiers.contains(identifier) else { return nil }
            return .kokoro(identifier: identifier)
        case .apple:
            return .apple(identifier: identifier)
        }
    }

    private func writePrimary(_ voice: PlaybackVoiceID) {
        switch voice {
        case .kokoro(let identifier):
            defaults.set(VoiceKind.kokoro.rawValue, forKey: Key.primaryKind)
            defaults.set(normalizedIdentifier(identifier) ?? Self.defaultKokoroIdentifier, forKey: Key.primaryIdentifier)
        case .apple(let identifier):
            defaults.set(VoiceKind.apple.rawValue, forKey: Key.primaryKind)
            defaults.set(identifier, forKey: Key.primaryIdentifier)
        }
    }

    private func normalizedPrimary(_ voice: PlaybackVoiceID) -> PlaybackVoiceID? {
        switch voice {
        case .kokoro(let identifier):
            guard
                let identifier = normalizedIdentifier(identifier),
                knownKokoroIdentifiers.contains(identifier)
            else {
                return nil
            }
            return .kokoro(identifier: identifier)
        case .apple(let identifier):
            guard let identifier = normalizedIdentifier(identifier) else { return nil }
            return .apple(identifier: identifier)
        }
    }

    private func normalizedIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
