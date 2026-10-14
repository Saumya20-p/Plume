#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// Opt-in, in-memory content for reproducible UI checks. No production store
/// is read or edited when this launch argument is present.
@MainActor
enum UIExperimentFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-experiment-fixture") }
    static func populate(_ container: ModelContainer) {
        guard enabled else { return }
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
            engine.load(document: document)
            engine.pause()
            PlaybackProgress.shared.currentWord = WordTimestamp(word: "The", startTime: 0, endTime: 1, rangeLocation: 13, rangeLength: 3)
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
