import Foundation

struct CacheClearResult: Sendable {
    var clearedBytes: Int64 = 0
    var retainedBytes: Int64 = 0
    var failedBytes: Int64 = 0
    var failedEntries: Int = 0
}

/// Protection changes and live-cache renames share one executor. There is no
/// suspension between the final protection check and moving an entry away.
@MainActor
final class AudioCacheStore {
    let root: URL
    private var writers: [UUID: UUID] = [:]
    private var deleting: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(root: URL) { self.root = root }

    func beginWriting(documentID: UUID) throws -> UUID {
        guard !deleting.contains(documentID) else { throw CancellationError() }
        let token = UUID()
        writers[token] = documentID
        return token
    }

    func finishWriting(_ token: UUID) {
        guard let id = writers.removeValue(forKey: token), !writers.values.contains(id) else { return }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    var protectedWriterIDs: Set<UUID> { Set(writers.values) }
    func blockNewWriters(for id: UUID) { deleting.insert(id) }

    func waitForWriters(for id: UUID) async {
        guard writers.values.contains(id) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func totalBytes() -> Int64 { entries(at: root).reduce(0) { $0 + Self.bytes(at: $1) } }

    struct QuarantinedClear: Sendable {
        var result: CacheClearResult
        var entries: [(URL, Int64)]
    }

    /// Synchronous preparation is also useful when a caller needs to coordinate
    /// model deletion with removal. New writers may recreate the live path
    /// after this returns; only the quarantined paths are removed afterward.
    func quarantineUnused(currentDocumentID: UUID?, only documentID: UUID? = nil) -> QuarantinedClear {
        let protection = protectedWriterIDs.union(currentDocumentID.map { [$0] } ?? [])
        var result = CacheClearResult()
        var quarantined: [(URL, Int64)] = []
        let quarantine = root.appendingPathComponent(".quarantine", isDirectory: true)
        if documentID == nil {
            quarantined = entries(at: quarantine).map { ($0, Self.bytes(at: $0)) }
        }
        for entry in entries(at: root) where entry.lastPathComponent != ".quarantine" {
            let bytes = Self.bytes(at: entry)
            guard let id = Self.documentID(for: entry) else { result.retainedBytes += bytes; continue }
            guard documentID == nil || documentID == id else { continue }
            guard !protection.contains(id) else { result.retainedBytes += bytes; continue }
            do {
                try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let target = quarantine.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: entry, to: target)
                quarantined.append((target, bytes))
            } catch {
                result.failedBytes += bytes
                result.failedEntries += 1
            }
        }
        return QuarantinedClear(result: result, entries: quarantined)
    }

    func clearUnused(currentDocumentID: UUID?, only documentID: UUID? = nil) async -> CacheClearResult {
        await removeQuarantined(quarantineUnused(currentDocumentID: currentDocumentID, only: documentID))
    }

    func removeQuarantined(_ pending: QuarantinedClear) async -> CacheClearResult {
        await Task.detached {
            var result = pending.result
            for (url, bytes) in pending.entries {
                do {
                    try FileManager.default.removeItem(at: url)
                    result.clearedBytes += bytes
                } catch {
                    result.failedBytes += bytes
                    result.failedEntries += 1
                }
            }
            return result
        }.value
    }

    private func entries(at directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    nonisolated static func documentID(for url: URL) -> UUID? {
        UUID(uuidString: url.pathExtension == "m4a" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
    }

    nonisolated static func bytes(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
}
