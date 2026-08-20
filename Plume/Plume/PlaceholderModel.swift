import Foundation
import SwiftData

@Model
final class PlaceholderModel {
    var id: UUID
    init(id: UUID = UUID()) {
        self.id = id
    }
}
