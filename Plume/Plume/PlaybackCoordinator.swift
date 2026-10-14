import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
public class PlaybackCoordinator: ObservableObject {
    public static let shared = PlaybackCoordinator()
    
    private var modelContainer: ModelContainer?
    
    private init() {}
    
    /// Configure with the app's ModelContainer at startup.
    /// This is safer than holding a potentially-stale ModelContext from a SwiftUI Environment.
    public func configure(container: ModelContainer) {
        self.modelContainer = container
    }
    
    public func advanceNext() {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        guard let nextDoc = Self.nextActiveQueuedDocument(in: context, queue: .shared) else { return }
        if AudioPlaybackEngine.shared.isPlayerViewPresented {
            AudioPlaybackEngine.shared.presentedPlayerDocument = nextDoc
        }
        AudioGenerationManager.shared.cancelCurrentGeneration()
        AudioPlaybackEngine.shared.load(document: nextDoc)
        if nextDoc.audioFileURL == nil && !AudioPlaybackEngine.shared.isAppleActive {
            AudioGenerationManager.shared.generate(document: nextDoc, playbackEngine: AudioPlaybackEngine.shared)
        }
        AudioPlaybackEngine.shared.play()
    }

    static func nextActiveQueuedDocument(in context: ModelContext, queue: PlaybackQueueManager) -> Document? {
        while let nextID = queue.popNext() {
            let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.id == nextID && $0.deletedAt == nil })
            if let document = try? context.fetch(descriptor).first { return document }
        }
        return nil
    }

}
