import SwiftUI
import Combine

enum FontStyle: String, CaseIterable, Identifiable {
    case system = "System"
    case serif = "Serif"
    case rounded = "Rounded"
    case monospaced = "Monospaced"
    
    var id: String { rawValue }
    
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case warm = "Warm"
    case muted = "Muted"
    
    var id: String { rawValue }
    
    var backgroundColor: Color {
        switch self {
        case .basic: return .black
        case .warm: return Color(red: 0.96, green: 0.94, blue: 0.89) // Cream/Sepia
        case .muted: return Color(red: 0.2, green: 0.2, blue: 0.2) // Charcoal
        }
    }
    
    var textColor: Color {
        switch self {
        case .basic: return Color(white: 0.95) // Off-white
        case .warm: return Color(red: 0.3, green: 0.2, blue: 0.1) // Dark brown
        case .muted: return Color(white: 0.8) // Soft gray
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
    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "appearance.fontFamily") }
    }
    @Published var fontStyle: FontStyle {
        didSet { UserDefaults.standard.set(fontStyle.rawValue, forKey: "appearance.fontStyle") }
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
        
        self.fontFamily = UserDefaults.standard.string(forKey: "appearance.fontFamily") ?? "Georgia"
        
        if let styleString = UserDefaults.standard.string(forKey: "appearance.fontStyle"),
           let style = FontStyle(rawValue: styleString) {
            self.fontStyle = style
        } else {
            self.fontStyle = .system
        }
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
