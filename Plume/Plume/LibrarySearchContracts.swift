import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case inProgress = "In Progress"
    case finished = "Finished"
    nonisolated var id: String { rawValue }
    nonisolated func matches(progress: Double) -> Bool {
        switch self {
        case .all: true
        case .inProgress: progress > 0 && progress < 0.99
        case .finished: progress >= 0.99
        }
    }
}

struct LibrarySearchScope {
    nonisolated static func matches(title: String, progress: Double, folderID: UUID?, deleted: Bool,
                                   query: String, filter: LibraryFilter) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !deleted && filter.matches(progress: progress)
            && (query.isEmpty ? folderID == nil : title.localizedCaseInsensitiveContains(query))
    }
}
