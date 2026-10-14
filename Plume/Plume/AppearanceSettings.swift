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
    static let shared = AppearanceManager()
    @Published var matchDevice: Bool {
        didSet { UserDefaults.standard.set(matchDevice, forKey: "appearance.matchDevice") }
    }
    @Published var selectedTheme: ReadingTheme {
        didSet { UserDefaults.standard.set(selectedTheme.rawValue, forKey: "appearance.selectedTheme") }
    }
    @Published var readerFont: ReaderFont {
        didSet { UserDefaults.standard.set(readerFont.rawValue, forKey: ReaderFont.preferenceKey) }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "appearance.fontSize") }
    }
    @Published var isBold: Bool {
        didSet { UserDefaults.standard.set(isBold, forKey: "appearance.isBold") }
    }
    @Published var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: "appearance.lineSpacing") }
    }
    
    private init() {
        self.matchDevice = UserDefaults.standard.object(forKey: "appearance.matchDevice") as? Bool ?? true
        
        if let themeString = UserDefaults.standard.string(forKey: "appearance.selectedTheme"),
           let theme = ReadingTheme(rawValue: themeString) {
            self.selectedTheme = theme
        } else {
            self.selectedTheme = .basic
        }
        
        self.readerFont = ReaderFont.migratedPreference(in: .standard)
        self.fontSize = UserDefaults.standard.object(forKey: "appearance.fontSize") as? Double ?? 18.0
        self.isBold = UserDefaults.standard.object(forKey: "appearance.isBold") as? Bool ?? false
        self.lineSpacing = UserDefaults.standard.object(forKey: "appearance.lineSpacing") as? Double ?? 4.0
    }
    
    func activeTheme(colorScheme: ColorScheme) -> ReadingTheme {
        if matchDevice {
            return colorScheme == .dark ? .basic : .warm
        } else {
            return selectedTheme
        }
    }
}
