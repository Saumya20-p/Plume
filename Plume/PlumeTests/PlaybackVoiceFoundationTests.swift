import XCTest
@testable import Plume

@MainActor
final class PlaybackVoiceFoundationTests: XCTestCase {
    func testPlaybackVoiceIDCodableRoundTrip() throws {
        let voices: [PlaybackVoiceID] = [
            .kokoro(identifier: "af_heart"),
            .apple(identifier: "com.apple.voice.premium")
        ]

        let encoded = try JSONEncoder().encode(voices)
        let decoded = try JSONDecoder().decode([PlaybackVoiceID].self, from: encoded)

        XCTAssertEqual(decoded, voices)
    }

    func testCatalogKeepsOnlyEnglishEnhancedAndPremiumRegularVoices() {
        let provider = TestAppleSpeechVoiceProvider(candidates: [
            candidate("default", language: "en-US", quality: .default),
            candidate("french", language: "fr-FR", quality: .premium),
            candidate("novelty", language: "en-GB", quality: .premium, isNovelty: true),
            candidate("personal", language: "en-US", quality: .enhanced, isPersonal: true),
            candidate("enhanced", name: "Zoe", language: "en-AU", quality: .enhanced),
            candidate("premium", name: "Ava", language: "en-US", quality: .premium)
        ])
        let changeObserver = TestAppleSpeechVoiceChangeObserver()

        let catalog = AppleSpeechVoiceCatalog(provider: provider, changeObserver: changeObserver)

        XCTAssertEqual(catalog.voices.map(\.id), ["premium", "enhanced"])
        XCTAssertEqual(catalog.voices.map(\.quality), [.premium, .enhanced])
    }

    func testCatalogRefreshesWhenObserverSignalsAChange() {
        let provider = TestAppleSpeechVoiceProvider(candidates: [
            candidate("first", name: "First", quality: .enhanced)
        ])
        let changeObserver = TestAppleSpeechVoiceChangeObserver()
        let catalog = AppleSpeechVoiceCatalog(provider: provider, changeObserver: changeObserver)

        provider.candidates = [
            candidate("second", name: "Second", quality: .premium)
        ]
        changeObserver.sendChange()

        XCTAssertEqual(catalog.voices.map(\.id), ["second"])
    }

    func testCatalogSortsByQualityThenLocalizedNameThenIdentifier() {
        let provider = TestAppleSpeechVoiceProvider(candidates: [
            candidate("premium-z", name: "Zoe", language: "en-AU", quality: .premium),
            candidate("enhanced-a", name: "Ava", language: "en-US", quality: .enhanced),
            candidate("premium-b", name: "Ava", language: "en-GB", quality: .premium),
            candidate("premium-a", name: "Ava", language: "en-US", quality: .premium)
        ])

        let catalog = AppleSpeechVoiceCatalog(
            provider: provider,
            changeObserver: TestAppleSpeechVoiceChangeObserver()
        )

        XCTAssertEqual(
            catalog.voices.map(\.id),
            ["premium-a", "premium-b", "premium-z", "enhanced-a"]
        )
    }

    func testCatalogCanBeEmpty() {
        let catalog = AppleSpeechVoiceCatalog(
            provider: TestAppleSpeechVoiceProvider(candidates: []),
            changeObserver: TestAppleSpeechVoiceChangeObserver()
        )

        XCTAssertTrue(catalog.voices.isEmpty)
    }

    func testCatalogCancelsObservationWhenReleased() {
        let changeObserver = TestAppleSpeechVoiceChangeObserver()
        weak var catalog: AppleSpeechVoiceCatalog?

        autoreleasepool {
            let instance = AppleSpeechVoiceCatalog(
                provider: TestAppleSpeechVoiceProvider(candidates: []),
                changeObserver: changeObserver
            )
            catalog = instance
            XCTAssertFalse(changeObserver.observation.isCancelled)
        }

        XCTAssertNil(catalog)
        XCTAssertTrue(changeObserver.observation.isCancelled)
    }

    func testLegacyKokoroMigrationIsIdempotent() throws {
        try withDefaults { defaults in
            defaults.set("bm_george", forKey: "kokoroVoice")
            let store = VoicePreferencesStore(defaults: defaults)

            XCTAssertEqual(store.load().primary, .kokoro(identifier: "bm_george"))

            store.save(VoicePreferences(
                primary: .apple(identifier: "com.apple.voice.enhanced"),
                fallbackAppleVoiceIdentifier: "com.apple.voice.fallback"
            ))
            defaults.set("af_heart", forKey: "kokoroVoice")

            let reloadedStore = VoicePreferencesStore(defaults: defaults)
            let preferences = reloadedStore.load()
            XCTAssertEqual(preferences.primary, .apple(identifier: "com.apple.voice.enhanced"))
            XCTAssertEqual(preferences.fallbackAppleVoiceIdentifier, "com.apple.voice.fallback")
        }
    }

    func testMissingLegacyVoiceMigratesToDefault() throws {
        try withDefaults { defaults in
            let store = VoicePreferencesStore(defaults: defaults)
            XCTAssertEqual(store.load().primary, .kokoro(identifier: "af_heart"))
        }
    }

    func testUnknownLegacyVoiceMigratesToDefaultAndRetainsLegacyValue() throws {
        try withDefaults { defaults in
            defaults.set("not_a_known_voice", forKey: "kokoroVoice")
            let store = VoicePreferencesStore(defaults: defaults)

            XCTAssertEqual(store.load().primary, .kokoro(identifier: "af_heart"))
            XCTAssertEqual(defaults.string(forKey: "kokoroVoice"), "not_a_known_voice")
        }
    }

    func testCorruptCurrentPreferenceRepairsFromValidLegacyVoice() throws {
        try withDefaults { defaults in
            defaults.set(1, forKey: "voicePreferences.schemaVersion")
            defaults.set("unsupported-kind", forKey: "voicePreferences.primary.kind")
            defaults.set("value", forKey: "voicePreferences.primary.identifier")
            defaults.set("bm_george", forKey: "kokoroVoice")

            let store = VoicePreferencesStore(defaults: defaults)
            XCTAssertEqual(store.load().primary, .kokoro(identifier: "bm_george"))
        }
    }

    func testAppleIdentifiersPreserveUnicodeAndPunctuation() throws {
        try withDefaults { defaults in
            let identifier = "com.apple.voice/Élan: premium (en-US)"
            let store = VoicePreferencesStore(defaults: defaults)
            store.save(VoicePreferences(
                primary: .apple(identifier: identifier),
                fallbackAppleVoiceIdentifier: "fallback/声:v1"
            ))

            XCTAssertEqual(store.load().primary, .apple(identifier: identifier))
            XCTAssertEqual(store.load().fallbackAppleVoiceIdentifier, "fallback/声:v1")
        }
    }

    func testBlankApplePrimaryDoesNotPartiallySave() throws {
        try withDefaults { defaults in
            let store = VoicePreferencesStore(defaults: defaults)
            store.save(VoicePreferences(
                primary: .kokoro(identifier: "af_bella"),
                fallbackAppleVoiceIdentifier: "original-fallback"
            ))

            store.save(VoicePreferences(
                primary: .apple(identifier: " \n "),
                fallbackAppleVoiceIdentifier: "replacement-fallback"
            ))

            let preferences = store.load()
            XCTAssertEqual(preferences.primary, .kokoro(identifier: "af_bella"))
            XCTAssertEqual(preferences.fallbackAppleVoiceIdentifier, "original-fallback")
        }
    }

    func testStoreNormalizesIdentifiersAndClearsEmptyFallback() throws {
        try withDefaults { defaults in
            let store = VoicePreferencesStore(defaults: defaults)
            store.save(VoicePreferences(
                primary: .kokoro(identifier: "  af_bella  "),
                fallbackAppleVoiceIdentifier: "   "
            ))

            let preferences = store.load()
            XCTAssertEqual(preferences.primary, .kokoro(identifier: "af_bella"))
            XCTAssertNil(preferences.fallbackAppleVoiceIdentifier)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PlaybackVoiceFoundationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func candidate(
        _ identifier: String,
        name: String? = nil,
        language: String = "en-US",
        quality: AppleSpeechVoiceCandidateQuality,
        isNovelty: Bool = false,
        isPersonal: Bool = false
    ) -> AppleSpeechVoiceCandidate {
        AppleSpeechVoiceCandidate(
            identifier: identifier,
            name: name ?? identifier,
            language: language,
            quality: quality,
            isNoveltyVoice: isNovelty,
            isPersonalVoice: isPersonal
        )
    }
}

@MainActor
private final class TestAppleSpeechVoiceProvider: AppleSpeechVoiceProviding {
    var candidates: [AppleSpeechVoiceCandidate]

    init(candidates: [AppleSpeechVoiceCandidate]) {
        self.candidates = candidates
    }

    func availableVoices() -> [AppleSpeechVoiceCandidate] {
        candidates
    }
}

@MainActor
private final class TestAppleSpeechVoiceChangeObserver: AppleSpeechVoiceChangeObserving {
    private var handler: (@MainActor () -> Void)?
    private(set) var observation = TestAppleSpeechVoiceChangeObservation()

    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleSpeechVoiceChangeObservation {
        self.handler = handler
        return observation
    }

    func sendChange() {
        guard !observation.isCancelled else { return }
        handler?()
    }
}

@MainActor
private final class TestAppleSpeechVoiceChangeObservation: AppleSpeechVoiceChangeObservation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
