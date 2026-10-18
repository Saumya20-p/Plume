import SwiftUI
import Combine
import os

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
            let arguments = ProcessInfo.processInfo.arguments
            let index = arguments.firstIndex(of: "--ui-experiment-appearance-suite")
            let suite = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "PlumeUIAppearance-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            if arguments.contains("--ui-experiment-reset-appearance") { defaults.removePersistentDomain(forName: suite) }
            return AppearanceManager(defaults: defaults)
        }
        #endif
        return AppearanceManager()
    }()
    private let defaults: UserDefaults
    private var isPreviewingTypography = false
    @Published var autoHideReaderControls: Bool {
        didSet { defaults.set(autoHideReaderControls, forKey: "appearance.autoHideReaderControls") }
    }
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
        didSet {
            if fontSize != oldValue && !isPreviewingTypography {
                defaults.set(fontSize, forKey: "appearance.fontSize")
            }
        }
    }
    @Published var isBold: Bool {
        didSet { defaults.set(isBold, forKey: "appearance.isBold") }
    }
    @Published var lineSpacing: Double {
        didSet {
            if lineSpacing != oldValue && !isPreviewingTypography {
                defaults.set(lineSpacing, forKey: "appearance.lineSpacing")
            }
        }
    }

    @Published private(set) var typographyRevision = 0
    private var pendingTypography: (size: Double, spacing: Double)?
    private var awaitingReaders: Set<UUID> = []
    private var readers: Set<UUID> = []
    private var inFlightRevision: Int?
    private var typographyTrace: OSSignpostID?
    private let typographyPreview = TypographyPreview()
    var latestFontSize: Double { pendingTypography?.size ?? fontSize }
    var latestLineSpacing: Double { pendingTypography?.spacing ?? lineSpacing }

    /// Persistence is independent of rendering. A final selection is saved even
    /// while a previous revision is waiting for UIKit to settle.
    func updateTypography(fontSize: Double, lineSpacing: Double, persist: Bool) {
        if persist {
            if defaults.object(forKey: "appearance.fontSize") as? Double != fontSize {
                defaults.set(fontSize, forKey: "appearance.fontSize")
            }
            if defaults.object(forKey: "appearance.lineSpacing") as? Double != lineSpacing {
                defaults.set(lineSpacing, forKey: "appearance.lineSpacing")
            }
        }
        pendingTypography = (fontSize, lineSpacing)
        scheduleTypography()
    }

    private func scheduleTypography() {
        guard inFlightRevision == nil else { return }
        typographyPreview.schedule { [weak self] in self?.applyPendingTypography() }
    }

    private func applyPendingTypography() {
        guard inFlightRevision == nil, let pending = pendingTypography else { return }
        pendingTypography = nil
        guard fontSize != pending.size || lineSpacing != pending.spacing else { return }
        let revision = typographyRevision + 1
        awaitingReaders = readers
        inFlightRevision = readers.isEmpty ? nil : revision
        typographyTrace = StabilityTrace.begin("TypographyRevision", revision: revision)
        isPreviewingTypography = true
        if fontSize != pending.size { fontSize = pending.size }
        if lineSpacing != pending.spacing { lineSpacing = pending.spacing }
        isPreviewingTypography = false
        typographyRevision = revision
        if readers.isEmpty { finishTypographyRevision() }
    }

    func readerAttached(_ id: UUID) { readers.insert(id) }

    func readerDetached(_ id: UUID) {
        readers.remove(id)
        awaitingReaders.remove(id)
        // Never publish new appearance state during representable teardown.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.awaitingReaders.isEmpty else { return }
            self.finishTypographyRevision()
            if self.readers.isEmpty { self.applyPendingTypography() }
        }
    }

    func readerAppliedTypography(_ revision: Int, reader: UUID) {
        guard inFlightRevision == revision else { return }
        awaitingReaders.remove(reader)
        if awaitingReaders.isEmpty { finishTypographyRevision() }
    }

    private func finishTypographyRevision() {
        if let trace = typographyTrace { StabilityTrace.end("TypographyRevision", trace) }
        typographyTrace = nil
        inFlightRevision = nil
        if pendingTypography != nil { scheduleTypography() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoHideReaderControls = defaults.bool(forKey: "appearance.autoHideReaderControls")
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
