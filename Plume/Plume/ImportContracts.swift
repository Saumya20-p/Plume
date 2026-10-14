import Foundation

/// Captured when Add opens and retained for retries and manual fallback.
struct ImportDestination: Equatable, Sendable {
    let folderID: UUID?
    let name: String

    nonisolated init(folderID: UUID? = nil, name: String = "Library") {
        self.folderID = folderID
        self.name = name
    }

    nonisolated func resolveFolderID(availableIDs: Set<UUID>) throws -> UUID? {
        guard let folderID else { return nil }
        guard availableIDs.contains(folderID) else { throw ImportFailure.destinationRemoved }
        return folderID
    }

    nonisolated func createsBookFolder(isEPUB: Bool) -> Bool { isEPUB && folderID == nil }
}

enum ImportFailure: LocalizedError {
    case invalidURL, emptyFile, destinationRemoved, extractionFailed
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete http or https link with a website address."
        case .emptyFile: "This file has no readable text. Scanned PDFs need text recognition before importing."
        case .destinationRemoved: "The destination folder was removed. Cancel and choose a new destination."
        case .extractionFailed: "Plume couldn't extract readable text from this page. Retry or paste the chapter text manually."
        }
    }
}

nonisolated func validatedImportURL(_ text: String) throws -> URL {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty else { throw ImportFailure.invalidURL }
    return url
}

/// Serializes timeout, cancellation, navigation and JavaScript completions.
@MainActor final class ImportCompletionGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

/// The worker owns any temporary resources until it actually exits. The caller
/// can return immediately on cancellation or deadline without waiting for CPU work.
@MainActor func awaitImportWorker<Value: Sendable>(
    _ worker: Task<Value, Error>, deadline: ContinuousClock.Instant
) async throws -> Value {
    let operation = ImportDeadlineOperation(worker: worker)
    return try await operation.run(deadline: deadline)
}

@MainActor private final class ImportDeadlineOperation<Value: Sendable> {
    private let worker: Task<Value, Error>
    private var gate: ImportCompletionGate<Value>?
    private var observer: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(worker: Task<Value, Error>) { self.worker = worker }

    func run(deadline: ContinuousClock.Instant) async throws -> Value {
        guard !Task.isCancelled else { worker.cancel(); throw CancellationError() }
        guard ContinuousClock.now < deadline else { worker.cancel(); throw URLError(.timedOut) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate = ImportCompletionGate(continuation)
                observer = Task { [weak self, worker] in
                    let result = await worker.result
                    self?.finish(result)
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let gate else { return }
        self.gate = nil
        worker.cancel()
        observer?.cancel()
        timer?.cancel()
        gate.finish(result)
    }
}
