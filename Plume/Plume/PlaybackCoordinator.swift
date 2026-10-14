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
        while let nextID = PlaybackQueueManager.shared.popNext() {
            let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.id == nextID && $0.deletedAt == nil })
            guard let nextDoc = try? context.fetch(descriptor).first else { continue }
            if AudioPlaybackEngine.shared.isPlayerViewPresented {
                AudioPlaybackEngine.shared.presentedPlayerDocument = nextDoc
            }
            AudioGenerationManager.shared.cancelCurrentGeneration()
            AudioPlaybackEngine.shared.load(document: nextDoc)
            if nextDoc.audioFileURL == nil && !AudioPlaybackEngine.shared.isAppleActive {
                AudioGenerationManager.shared.generate(document: nextDoc, playbackEngine: AudioPlaybackEngine.shared)
            }
            AudioPlaybackEngine.shared.play()
            return
        }
    }
}
