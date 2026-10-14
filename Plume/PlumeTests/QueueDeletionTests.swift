import Foundation
import Testing
import SwiftData
@testable import Plume

struct QueueDeletionTests {
    @Test @MainActor func deletingEntryKeepsRemainingQueueOrder() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = PlaybackQueueManager(defaults: defaults)
        let a = UUID(), b = UUID(), c = UUID()
        queue.enqueue(a); queue.enqueue(b); queue.enqueue(c)
        queue.remove(documentID: b)
        #expect(queue.popNext() == a)
        #expect(queue.popNext() == c)
        #expect(queue.popNext() == nil)
    }
    @Test @MainActor func queueSkipsMissingAndSoftDeletedChapters() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = PlaybackQueueManager(defaults: defaults)
        let container = try ModelContainer(for: Document.self, Folder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let deleted = Document(title: "Deleted", bodyText: "text")
        deleted.deletedAt = .now
        let active = Document(title: "Active", bodyText: "text")
        context.insert(deleted); context.insert(active)
        try context.save()
        queue.enqueue(UUID()); queue.enqueue(deleted.id); queue.enqueue(active.id)
        #expect(PlaybackCoordinator.nextActiveQueuedDocument(in: context, queue: queue)?.id == active.id)
        #expect(queue.queue.isEmpty)
    }

}
