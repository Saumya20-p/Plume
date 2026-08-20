import Foundation
import SwiftData

extension Bool: @retroactive Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        return !lhs && rhs
    }
}

@Model
public final class Document {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var sourceURL: URL?
    public var bodyText: String
    public var dateAdded: Date
    public var progress: Double
    
    @Attribute(.externalStorage) public var coverImageData: Data?
    
    public var folder: Folder?
    
    // Dynamically check if the cached audio exists
    @Transient
    public var audioFileURL: URL? {
        let fileURL = StorageManager.shared.audioCacheURL.appendingPathComponent("\(id.uuidString).m4a")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }
    public var wordTimestamps: Data?
    
    @Transient private var _cachedDecodedWordTimestamps: [WordTimestamp]?
    
    public var decodedWordTimestamps: [WordTimestamp] {
        get {
            if let cached = _cachedDecodedWordTimestamps {
                return cached
            }
            guard let data = wordTimestamps else { return [] }
            let decoded = (try? JSONDecoder().decode([WordTimestamp].self, from: data)) ?? []
            _cachedDecodedWordTimestamps = decoded
            return decoded
        }
        set {
            wordTimestamps = try? JSONEncoder().encode(newValue)
            _cachedDecodedWordTimestamps = newValue
        }
    }

    
    public var extractionFailed: Bool
    public var isPinned: Bool
    public var deletedAt: Date?
    public var wordCount: Int
    
    public init(
        id: UUID = UUID(),
        title: String,
        sourceURL: URL? = nil,
        bodyText: String,
        dateAdded: Date = Date(),
        progress: Double = 0,
        extractionFailed: Bool = false,
        isPinned: Bool = false,
        wordCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.bodyText = bodyText
        self.dateAdded = dateAdded
        self.progress = progress
        self.extractionFailed = extractionFailed
        self.isPinned = isPinned
        self.wordCount = wordCount
    }
}

public struct WordTimestamp: Codable, Equatable, Hashable, Sendable {
    public var word: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var rangeLocation: Int?
    public var rangeLength: Int?
    
    nonisolated public init(word: String, startTime: TimeInterval, endTime: TimeInterval, rangeLocation: Int? = nil, rangeLength: Int? = nil) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
    }
}


