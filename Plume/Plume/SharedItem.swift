import Foundation

public struct SharedItem: Codable, Identifiable {
    public let id: UUID
    public let url: String
    public let html: String?
    public let dateAdded: Date
}
