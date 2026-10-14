import Foundation
import Testing
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
}
