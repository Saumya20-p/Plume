import Foundation

public final class StorageManager {
    public static let shared = StorageManager()
    
    public let swiftDataURL: URL
    public let audioCacheURL: URL
    
    private init() {
        let container: URL
        #if DEBUG
        container = UIExperimentFixture.enabled
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PlumeUIExperiment-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : AppGroup.containerURL
        #else
        container = AppGroup.containerURL
        #endif
        
        swiftDataURL = container.appendingPathComponent("SwiftData", isDirectory: true)
        audioCacheURL = container.appendingPathComponent("AudioCache", isDirectory: true)
        
        // Ensure directories exist so we can safely write to them later
        try? FileManager.default.createDirectory(at: swiftDataURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioCacheURL, withIntermediateDirectories: true)
    }
}

@MainActor
extension AudioCacheStore {
    static let shared = AudioCacheStore(root: StorageManager.shared.audioCacheURL)
}
