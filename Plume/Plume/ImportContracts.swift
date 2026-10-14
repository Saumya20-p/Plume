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
