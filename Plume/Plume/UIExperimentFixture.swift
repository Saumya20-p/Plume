#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// Opt-in, in-memory content for reproducible UI checks. No production store
/// is read or edited when this launch argument is present.
@MainActor
enum UIExperimentFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-experiment-fixture") }
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
        if let index = arguments.firstIndex(of: "-appearance.selectedTheme"), arguments.indices.contains(index + 1),
           let theme = ReadingTheme(rawValue: arguments[index + 1]) { appearance.selectedTheme = theme }
        let context = container.mainContext
        let folder = Folder(name: "Experiment Book")
        context.insert(folder)
        let passage = "The river moved slowly beneath the old bridge. Morning light touched the water and the quiet windows of the town. She paused to listen, then opened the book and began to read."
        let document = Document(title: "A Long Chapter Title for Reader and Library Verification", bodyText: (1...30).map { "Paragraph \($0). \(passage)" }.joined(separator: "\n\n"), wordCount: 1000)
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
            engine.pause()
            PlaybackProgress.shared.currentWord = restoreSavedPosition ?
                WordTimestamp(word: "", startTime: 0, endTime: 0, rangeLocation: document.lastReadCharIndex, rangeLength: 0) :
                WordTimestamp(word: "The", startTime: 0, endTime: 1, rangeLocation: 13, rangeLength: 3)
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
        if UIExperimentFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-large-text") {
            content.environment(\.dynamicTypeSize, .accessibility5).environment(\.legibilityWeight, .bold)
        } else { content }
    }
}
#endif
