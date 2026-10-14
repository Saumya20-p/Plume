import Foundation
import AppIntents
import SwiftData

struct PlayArticleIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Article"
    
    // We open the app to reliably handle AVQueuePlayer and AudioPlaybackEngine logic
    // without hitting strict background launch audio limitations.
    static var openAppWhenRun: Bool = true
    
    @Parameter(title: "Article Title")
    var title: String
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // We use the shared AppGroup container where the SQLite DB is stored
        let schema = Schema([Document.self, ListeningSession.self, Folder.self])
        let storeURL = StorageManager.shared.swiftDataURL.appendingPathComponent("Plume.sqlite")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            let context = ModelContext(container)
            
            // Search for document matching title
            let descriptor = FetchDescriptor<Document>()
            let allDocs = try context.fetch(descriptor)
            
            if let matchedDoc = allDocs.first(where: { $0.title.localizedCaseInsensitiveContains(self.title) }) {
                PlaybackQueueManager.shared.enqueue(matchedDoc.id)
                if matchedDoc.audioFileURL != nil {
                    AudioPlaybackEngine.shared.load(document: matchedDoc)
                    AudioPlaybackEngine.shared.play()
                } else {
                    AudioGenerationManager.shared.generate(document: matchedDoc, playbackEngine: AudioPlaybackEngine.shared)
                }
            }
        } catch {
            print("Failed to initialize SwiftData or fetch documents for AppIntent: \(error)")
        }
        
        return .result()
    }
}
