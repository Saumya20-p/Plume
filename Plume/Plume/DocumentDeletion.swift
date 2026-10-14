import Foundation
import SwiftData

@MainActor
enum DocumentDeletion {
    private static var deletingIDs: Set<UUID> = []
    static func permanentlyDelete(_ documents: [Document], context: ModelContext) async -> CacheClearResult {
        let documents = documents.filter { !deletingIDs.contains($0.id) }
        let ids = Set(documents.map(\.id))
        deletingIDs.formUnion(ids)
        defer { deletingIDs.subtract(ids) }
        let cache = AudioCacheStore.shared
        for document in documents {
            cache.blockNewWriters(for: document.id)
            document.deletedAt = document.deletedAt ?? .now
            PlaybackQueueManager.shared.remove(document.id)
        }
        let engine = AudioPlaybackEngine.shared
        if documents.contains(where: { $0.id == engine.currentDocument?.id }) {
            engine.stopAndRelease()
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
