import Foundation
import SwiftData

@Model
public final class Folder {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var dateAdded: Date
    @Attribute(.externalStorage) public var coverImageData: Data?
    
    @Relationship(deleteRule: .nullify, inverse: \Document.folder)
    public var documents: [Document] = []
    
    public init(id: UUID = UUID(), name: String, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.dateAdded = dateAdded
    }
}
