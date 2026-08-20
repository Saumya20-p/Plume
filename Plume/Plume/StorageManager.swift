import Foundation

public final class StorageManager {
    public static let shared = StorageManager()
    
    public let swiftDataURL: URL
    public let audioCacheURL: URL
    
    private init() {
        let container = AppGroup.containerURL
        
        swiftDataURL = container.appendingPathComponent("SwiftData", isDirectory: true)
        audioCacheURL = container.appendingPathComponent("AudioCache", isDirectory: true)
        
        // Ensure directories exist so we can safely write to them later
        try? FileManager.default.createDirectory(at: swiftDataURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioCacheURL, withIntermediateDirectories: true)
    }
}
