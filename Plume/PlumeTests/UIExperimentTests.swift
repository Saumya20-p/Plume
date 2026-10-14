import Foundation
import Testing
@testable import Plume

struct UIExperimentTests {
    @Test @MainActor func cacheRetainsCanceledWritersUntilCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioCacheStore(root: root)
        let writerID = UUID(), currentID = UUID(), unusedID = UUID()
        for id in [writerID, currentID, unusedID] {
            let directory = root.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: directory.appendingPathComponent("chunk_0.m4a"))
        }
        try Data(repeating: 1, count: 50).write(to: root.appendingPathComponent(unusedID.uuidString + ".m4a"))
        let token = try store.beginWriting(documentID: writerID)
        #expect(store.totalBytes() == 350)
        let first = await store.clearUnused(currentDocumentID: currentID)
        #expect(first.clearedBytes == 150)
        #expect(first.retainedBytes == 200)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(writerID.uuidString).path))
        store.finishWriting(token)
        let second = await store.clearUnused(currentDocumentID: currentID)
        #expect(second.clearedBytes == 100)
        #expect(second.retainedBytes == 100)
    }

    @Test @MainActor func quarantinedDeletionCannotRemoveNewWriterFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioCacheStore(root: root), id = UUID()
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: directory.appendingPathComponent("old.m4a"))
        let pending = store.quarantineUnused(currentDocumentID: nil)
        let token = try store.beginWriting(documentID: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fresh = directory.appendingPathComponent("fresh.m4a")
        try Data(repeating: 1, count: 20).write(to: fresh)
        let removed = await store.removeQuarantined(pending)
        #expect(removed.clearedBytes == 100)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        store.finishWriting(token)
    }

    @Test @MainActor func permanentDeletionBlocksNewWriters() async throws {
        let store = AudioCacheStore(root: FileManager.default.temporaryDirectory)
        let id = UUID(), first = try store.beginWriting(documentID: id), second = try store.beginWriting(documentID: id)
        store.blockNewWriters(for: id)
        #expect(throws: CancellationError.self) { try store.beginWriting(documentID: id) }
        store.finishWriting(first)
        #expect(store.protectedWriterIDs.contains(id))
        store.finishWriting(second)
        await store.waitForWriters(for: id)
        #expect(!store.protectedWriterIDs.contains(id))
    }

    @Test func calendarRangesUseMatchingBucketsAndDayCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 12)))
        let week = StatsTimeframe.week.range(now: now, calendar: calendar)
        #expect(week.days == 7)
        #expect(week.bucketDates(calendar: calendar).count == 7)
        let month = StatsTimeframe.month.range(now: now, calendar: calendar)
        #expect(month.days == 29)
        #expect(month.bucketDates(calendar: calendar).count == 29)
        #expect(!month.contains(now.addingTimeInterval(1)))
        #expect(StatsTimeframe.year.title == "Last Year")
        #expect(ListeningDurationFormat.string(0) == "0 min")
        #expect(ListeningDurationFormat.string(1) == "<1 min")
        #expect(ListeningDurationFormat.string(59.9) == "<1 min")
        #expect(ListeningDurationFormat.string(60) == "1 min")
    }
}
