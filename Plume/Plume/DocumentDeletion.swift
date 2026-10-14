import Foundation
import SwiftData

@MainActor
enum DocumentDeletion {
    static func permanentlyDelete(_ documents: [Document], context: ModelContext) async -> CacheClearResult {
        let cache = AudioCacheStore.shared
        for document in documents {
            cache.blockNewWriters(for: document.id)
            document.deletedAt = document.deletedAt ?? .now
            PlaybackQueueManager.shared.remove(document.id)
        }
        let engine = AudioPlaybackEngine.shared
        if documents.contains(where: { $0.id == engine.currentDocument?.id }) {
            AudioGenerationManager.shared.cancelCurrentGeneration()
            engine.pause()
            engine.clearMemory()
            engine.currentDocument = nil
            engine.presentedPlayerDocument = nil
            engine.isPlayerViewPresented = false
            PlaybackProgress.shared.currentWord = nil
            PlaybackProgress.shared.currentTime = 0
        }
        var result = CacheClearResult()
        for document in documents {
            await cache.waitForWriters(for: document.id)
            let cleared = await cache.clearUnused(currentDocumentID: engine.currentDocument?.id, only: document.id)
            result.clearedBytes += cleared.clearedBytes
            result.retainedBytes += cleared.retainedBytes
            result.failedBytes += cleared.failedBytes
            result.failedEntries += cleared.failedEntries
            context.delete(document)
        }
        return result
    }
}
