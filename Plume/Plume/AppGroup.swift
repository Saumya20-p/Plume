import Foundation

enum AppGroup {
    static let identifier = "group.com.saumyapatel.plume"
    
    static var containerURL: URL {
        if let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return sharedURL
        }
        // Fallback for simulator or local dev without App Group entitlement
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}
