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
        guard let nextID = PlaybackQueueManager.shared.popNext() else { return }
        
        // Create a fresh context for each advance to avoid stale-context issues
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.id == nextID })
        if let docs = try? context.fetch(descriptor), let nextDoc = docs.first {
            if nextDoc.audioFileURL != nil {
                AudioPlaybackEngine.shared.load(document: nextDoc)
                AudioPlaybackEngine.shared.play()
            } else {
                // Generate then play
                AudioGenerationManager.shared.generate(document: nextDoc, playbackEngine: AudioPlaybackEngine.shared)
            }
        }
    }
}
