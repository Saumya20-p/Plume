import Foundation
import SwiftData

@Model
public final class ListeningSession {
    @Attribute(.unique) public var id: UUID
    public var documentId: UUID
    public var date: Date
    public var secondsListened: Double
    public var wordsListened: Int
    public var playbackSpeed: Double
    
    public init(
        id: UUID = UUID(),
        documentId: UUID,
        date: Date = Date(),
        secondsListened: Double,
        wordsListened: Int,
        playbackSpeed: Double
    ) {
        self.id = id
        self.documentId = documentId
        self.date = date
        self.secondsListened = secondsListened
        self.wordsListened = wordsListened
        self.playbackSpeed = playbackSpeed
    }
}
