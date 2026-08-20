import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appearanceManager: AppearanceManager
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Match Device", isOn: $appearanceManager.matchDevice)
                        .tint(.accentColor)
                }
                
                Section(header: Text("Theme")) {
                    HStack(spacing: 12) {
                        ThemeCard(
                            theme: .basic,
                            isSelected: appearanceManager.selectedTheme == .basic,
                            action: { selectTheme(.basic) }
                        )
                        ThemeCard(
                            theme: .warm,
                            isSelected: appearanceManager.selectedTheme == .warm,
                            action: { selectTheme(.warm) }
                        )
                        ThemeCard(
                            theme: .muted,
                            isSelected: appearanceManager.selectedTheme == .muted,
                            action: { selectTheme(.muted) }
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                Section(header: Text("Font")) {
                    Picker("Font Style", selection: $appearanceManager.fontStyle) {
                        ForEach(FontStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Font Size")
                        HStack {
                            Text("A")
                                .font(.system(size: 14))
                            Slider(value: $appearanceManager.fontSize, in: 12...36, step: 1)
                            Text("A")
                                .font(.system(size: 24))
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Line Spacing")
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14))
                            Slider(value: $appearanceManager.lineSpacing, in: 0...20, step: 1)
                            Image(systemName: "arrow.up.and.down.text.horizontal")
                                .font(.system(size: 20))
                        }
                    }
                    
                    Toggle("Bold Font", isOn: $appearanceManager.isBold)
                        .tint(.accentColor)
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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
    }
}

#Preview {
    AppearanceSettingsView()
        .environmentObject(AppearanceManager.shared)
}
