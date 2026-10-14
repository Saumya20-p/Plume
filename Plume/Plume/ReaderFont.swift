import Foundation

/// Reader faces have a new key because the legacy font-style picker never
/// affected the Georgia reading surface.
enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case georgia = "Georgia"
    case system = "System"
    case serif = "Serif"
    case rounded = "Rounded"
    case monospaced = "Monospaced"
    var id: String { rawValue }
    static let preferenceKey = "appearance.readerFont"

    static func migratedPreference(in defaults: UserDefaults) -> ReaderFont {
        if let value = defaults.string(forKey: preferenceKey), let font = ReaderFont(rawValue: value) {
            return font
        }
        // All legacy choices rendered Georgia; retain the existing appearance.
        defaults.set(ReaderFont.georgia.rawValue, forKey: preferenceKey)
        return .georgia
    }
}
