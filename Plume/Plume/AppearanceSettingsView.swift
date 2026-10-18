import SwiftUI
import UIKit
import Combine

struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var appearanceManager: AppearanceManager
    @ScaledMetric(relativeTo: .caption) private var themeCardMinimumWidth: CGFloat = 88
    @State private var fontSize = 18.0
    @State private var lineSpacing = 4.0
    @State private var typographyLoaded = false
    @State private var isEditingTypography = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Match Device", isOn: $appearanceManager.matchDevice)
                        .tint(.accentColor)
                }
                
                Section(header: Text("Theme")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: themeCardMinimumWidth), spacing: 12)], spacing: 12) {
                        ForEach(ReadingTheme.allCases) { theme in
                            ThemeCard(theme: theme,
                                      isSelected: appearanceManager.activeTheme(colorScheme: colorScheme) == theme,
                                      action: { selectTheme(theme) })
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                Section {
                    Toggle("Auto-Hide Reader Controls", isOn: $appearanceManager.autoHideReaderControls)
                        .tint(.accentColor)
                        .accessibilityIdentifier("appearance.autoHideReaderControls")
                } header: {
                    Text("Reader Controls")
                } footer: {
                    Text("Hide the header and player while following playback. Tap the page or scroll to show them again.")
                }

                Section(header: Text("Font")) {
                    Picker("Reading Font", selection: $appearanceManager.readerFont) {
                        ForEach(ReaderFont.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Font Size")
                        HStack {
                            Text("A")
                                .font(.system(size: 14))
                            Slider(value: $fontSize, in: 12...36, step: 1, onEditingChanged: finishTypographyEditing)
                                .accessibilityLabel("Reading font size")
                                .accessibilityValue("\(Int(fontSize)) points")
                                .onChange(of: fontSize) { previewTypography() }
                            Text("A")
                                .font(.system(size: 24))
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Line Spacing")
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14))
                            Slider(value: $lineSpacing, in: 0...20, step: 1, onEditingChanged: finishTypographyEditing)
                                .accessibilityLabel("Line spacing")
                                .accessibilityValue("\(Int(lineSpacing)) points")
                                .onChange(of: lineSpacing) { previewTypography() }
                            Image(systemName: "arrow.up.and.down.text.horizontal")
                                .font(.system(size: 20))
                        }
                    }
                    
                    Toggle("Bold Font", isOn: $appearanceManager.isBold)
                        .tint(.accentColor)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        commitTypography()
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.disabled)
        .presentationDetents([.height(650), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            fontSize = appearanceManager.latestFontSize
            lineSpacing = appearanceManager.latestLineSpacing
            typographyLoaded = true
        }
        .onDisappear {
            commitTypography()
            typographyLoaded = false
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { commitTypography() }
        }
    }

    private func previewTypography() {
        guard typographyLoaded else { return }
        let size = fontSize
        let spacing = lineSpacing
        let persist = !isEditingTypography
        appearanceManager.updateTypography(fontSize: size, lineSpacing: spacing, persist: persist)
    }

    private func finishTypographyEditing(_ editing: Bool) {
        isEditingTypography = editing
        if !editing { commitTypography() }
    }

    private func commitTypography() {
        guard typographyLoaded else { return }
        appearanceManager.updateTypography(fontSize: fontSize, lineSpacing: lineSpacing, persist: true)
    }
    
    private func selectTheme(_ theme: ReadingTheme) {
        appearanceManager.selectedTheme = theme
        appearanceManager.matchDevice = false
    }
}

struct ThemeCard: View {
    let theme: ReadingTheme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack {
                Circle()
                    .fill(theme.backgroundColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        Text("Aa")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textColor)
                    )
                
                Text(theme.rawValue)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.rawValue) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    AppearanceSettingsView()
        .environmentObject(AppearanceManager.shared)
}
