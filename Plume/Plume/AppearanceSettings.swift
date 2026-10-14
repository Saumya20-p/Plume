import SwiftUI
import Combine

enum ReadingTheme: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case warm = "Warm"
    case muted = "Muted"
    
    var id: String { rawValue }
    
    var backgroundColor: Color {
        switch self {
        case .basic: return .black
        case .warm: return Color(hex: "#DDD5CD") // Warm Greige
        case .muted: return Color(hex: "#2E2E2E") // Charcoal Espresso
        }
    }
    
    var textColor: Color {
        switch self {
        case .basic: return Color(hex: "#F1ECE6") // Alabaster Cream
        case .warm: return Color(hex: "#47382F") // Deep warm brown
        case .muted: return Color(hex: "#D8D0C8") // Brightened Warm Greige
        }
    }
}

class AppearanceManager: ObservableObject {
    static let shared: AppearanceManager = {
        #if DEBUG
        if UIExperimentFixture.enabled {
            return AppearanceManager(defaults: UserDefaults(suiteName: "PlumeUIAppearance-\(UUID().uuidString)")!)
        }
        #endif
        return AppearanceManager()
    }()
    private let defaults: UserDefaults
    @Published var matchDevice: Bool {
        didSet { defaults.set(matchDevice, forKey: "appearance.matchDevice") }
    }
    @Published var selectedTheme: ReadingTheme {
        didSet { defaults.set(selectedTheme.rawValue, forKey: "appearance.selectedTheme") }
    }
    @Published var readerFont: ReaderFont {
        didSet { defaults.set(readerFont.rawValue, forKey: ReaderFont.preferenceKey) }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "appearance.fontSize") }
    }
    @Published var isBold: Bool {
        didSet { defaults.set(isBold, forKey: "appearance.isBold") }
    }
    @Published var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: "appearance.lineSpacing") }
    }
    
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.matchDevice = defaults.object(forKey: "appearance.matchDevice") as? Bool ?? true
        
        if let themeString = defaults.string(forKey: "appearance.selectedTheme"),
           let theme = ReadingTheme(rawValue: themeString) {
            self.selectedTheme = theme
        } else {
            self.selectedTheme = .basic
        }
        
        self.readerFont = ReaderFont.migratedPreference(in: defaults)
        self.fontSize = defaults.object(forKey: "appearance.fontSize") as? Double ?? 18.0
        self.isBold = defaults.object(forKey: "appearance.isBold") as? Bool ?? false
        self.lineSpacing = defaults.object(forKey: "appearance.lineSpacing") as? Double ?? 4.0
    }
    
    func activeTheme(colorScheme: ColorScheme) -> ReadingTheme {
        if matchDevice {
            return colorScheme == .dark ? .basic : .warm
        } else {
            return selectedTheme
        }
    }
}
