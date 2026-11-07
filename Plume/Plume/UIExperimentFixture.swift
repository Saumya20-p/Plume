#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import AVFoundation

/// Opt-in, in-memory content for reproducible UI checks. No production store
/// is read or edited when this launch argument is present.
@MainActor
enum UIExperimentFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-experiment-fixture") }
    static var emptyLibrary: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-empty-library")
    }
    static var autoHideEnabled: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-auto-hide")
    }

    static func autoHideMarkers(in text: String) -> [WordTimestamp] {
        var markers: [WordTimestamp] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let nsRange = NSRange(range, in: text)
            markers.append(WordTimestamp(word: word, startTime: Double(markers.count) * 0.18,
                                         endTime: Double(markers.count + 1) * 0.18,
                                         rangeLocation: nsRange.location, rangeLength: nsRange.length))
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-experiment-stationary-markers"), let first = markers.first {
            return Array(repeating: first, count: 1000)
        }
        return markers
    }

    static var readerDiagnosticsEnabled: Bool {
        autoHideEnabled || (enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-apple-speech"))
    }

    static var finalParagraphEnabled: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-final-paragraph")
    }

    static func finalParagraphMarkers(in text: String) -> [WordTimestamp] {
        let chapter = text as NSString
        let paragraph = chapter.paragraphRange(for: NSRange(location: max(0, chapter.length - 1), length: 0))
        var markers: [WordTimestamp] = []
        text.enumerateSubstrings(in: Range(paragraph, in: text)!, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let nsRange = NSRange(range, in: text)
            markers.append(WordTimestamp(word: word, startTime: Double(markers.count),
                                         endTime: Double(markers.count + 1),
                                         rangeLocation: nsRange.location, rangeLength: nsRange.length))
        }
        return markers
    }
    static func recordPlaybackDiagnostics() {
        guard enabled else { return }
        Task { @MainActor in
            for delay in [1, 4] {
                try? await Task.sleep(for: .seconds(delay))
                let engine = AudioPlaybackEngine.shared
                let generation = AudioGenerationManager.shared
                print("UI playback diagnostics:", "playing=\(engine.isPlaying)", "chunks=\(engine.chunks.count)", "time=\(engine.currentTime)", "generation=\(generation.generationProgress ?? "none")", "generationError=\(generation.lastError ?? "none")", "routingError=\(engine.coordinator.lastError ?? "none")", "intent=\(String(describing: engine.coordinator.contract?.desiredPlayIntent))", "modelLoaded=\(KokoroTTSService.shared.isModelLoaded)")
            }
        }
    }
    static func populate(_ container: ModelContainer) {
        guard enabled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let appearance = AppearanceManager.shared
        appearance.matchDevice = false
        if arguments.contains("--ui-experiment-auto-hide-on") { appearance.autoHideReaderControls = true }
        if let index = arguments.firstIndex(of: "-appearance.selectedTheme"), arguments.indices.contains(index + 1),
           let theme = ReadingTheme(rawValue: arguments[index + 1]) { appearance.selectedTheme = theme }
        if emptyLibrary { return }
        let context = container.mainContext
        if arguments.contains("--ui-experiment-startup-library") || arguments.contains("--ui-experiment-folder-only") {
            let count = arguments.contains("--ui-experiment-folder-only") ? 0 :
                (arguments.contains("--ui-experiment-large-library") ? 1000 : 100)
            let folders = (1...5).map { Folder(name: "Startup Folder \($0)") }
            for folder in folders { context.insert(folder) }
            for index in 0..<count {
                let text = String(repeating: "A synthetic passage for launch verification. ", count: 100)
                let document = Document(title: "Startup Chapter \(index + 1)", bodyText: text, wordCount: 700)
                document.folder = folders[index % folders.count]
                context.insert(document)
            }
            try? context.save()
            return
        }
        let folder = Folder(name: "Experiment Book")
        context.insert(folder)
        let passage = "The river moved slowly beneath the old bridge. Morning light touched the water and the quiet windows of the town. She paused to listen, then opened the book and began to read."
        var body = (1...30).map { "Paragraph \($0). \(passage)" }.joined(separator: "\n\n")
        if finalParagraphEnabled {
            let finalParagraph = arguments.contains("--ui-experiment-wrapped-final") ?
                "At the end of the chapter, she watched the river carry the last light beyond the bridge. The quiet room seemed larger now. She turned back through the pages, remembering each familiar voice and every small discovery along the way. Outside, the town settled into evening while the water continued past the windows. There was time for one more thought before she closed the book. Every final word should remain clear and easy to follow, all the way to the end." :
                "The final words stay clear."
            body += "\n\n" + finalParagraph
        }
        let document = Document(title: "A Long Chapter Title for Reader and Library Verification", bodyText: body, wordCount: 1000)
        document.folder = folder
        context.insert(document)
        context.insert(Document(title: "A Standalone Chapter", bodyText: passage))
        context.insert(ListeningSession(documentId: document.id, secondsListened: 35, wordsListened: 90, playbackSpeed: 1))
        try? context.save()
        if ProcessInfo.processInfo.arguments.contains("--ui-experiment-reader") {
            let engine = AudioPlaybackEngine.shared
            let restoreSavedPosition = arguments.contains("--ui-experiment-restored-position")
            if restoreSavedPosition {
                let chapter = document.bodyText as NSString
                document.lastReadCharIndex = chapter.range(of: "Paragraph 8. ").location +
                    "Paragraph 8. The river moved slowly beneath the old bridge. ".utf16.count
            }
            engine.load(document: document)
            if arguments.contains("--ui-experiment-apple-speech"), let voice = AVSpeechSynthesisVoice(language: "en-US") {
                // Select only this fixture's session; do not persist a test voice.
                _ = engine.coordinator.begin(document: document, snapshot: PlaybackSessionSnapshot(
                    documentID: document.id, preferences: VoicePreferences(primary: .apple(identifier: voice.identifier),
                                                                          fallbackAppleVoiceIdentifier: nil)))
                engine.duration = document.estimatedDuration
                engine.isGenerationActive = false
            }
            engine.pause()
            PlaybackProgress.shared.currentWord = restoreSavedPosition ?
                WordTimestamp(word: "", startTime: 0, endTime: 0, rangeLocation: document.lastReadCharIndex, rangeLength: 0) :
                WordTimestamp(word: "The", startTime: 0, endTime: 1, rangeLocation: 13, rangeLength: 3)
            if finalParagraphEnabled {
                PlaybackProgress.shared.currentWord = finalParagraphMarkers(in: body).first
            }
            if arguments.contains("--ui-experiment-position") {
                engine.currentTime = 60
                engine.duration = 120
            }
            engine.presentedPlayerDocument = document
        }
    }
}
struct UIExperimentEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.dynamicTypeSize) { size in
                if UIExperimentFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-large-text") {
                    size = .accessibility5
                }
            }
            .transformEnvironment(\.legibilityWeight) { weight in
                if UIExperimentFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-large-text") {
                    weight = .bold
                }
            }
    }
}
#endif
