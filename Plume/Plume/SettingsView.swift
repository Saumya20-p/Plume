import SwiftUI
import SwiftData
import AVFoundation
import os

struct SettingsView: View {
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage("defaultSkipInterval") private var defaultSkipInterval: Int = 15
    @Query private var documents: [Document]
    
    @State private var isClearingCache = false
    @ObservedObject private var generation = AudioGenerationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingClearCacheAlert = false
    @State private var cacheClearedMessage: String?
    @State private var cacheSizeString: String = "Calculating..."
    @State private var voicePreferences: VoicePreferences = VoicePreferencesStore().load()
    
    @AppStorage("deleteFolderContents") private var deleteFolderContents: Bool = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: ListeningStatisticsView()) {
                        Label("Listening Statistics", systemImage: "chart.bar.fill")
                            .foregroundStyle(DesignSystem.accent)
                    }
                }
                
                Section(header: Text("Playback Defaults")) {
                    Picker("Default Speed", selection: $defaultPlaybackSpeed) {
                        Text("0.75x").tag(0.75)
                        Text("1.0x").tag(1.0)
                        Text("1.25x").tag(1.25)
                        Text("1.5x").tag(1.5)
                        Text("2.0x").tag(2.0)
                        Text("3.0x").tag(3.0)
                    }
                    
                    Picker("Skip Interval", selection: $defaultSkipInterval) {
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                        Text("30s").tag(30)
                    }
                }
                
                Section(header: Text("Voice")) {
                    NavigationLink(destination: VoiceSettingsView()) {
                        HStack {
                            Text("Voices")
                            Spacer()
                            Text(voiceSummaryText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Library Management")) {
                    Toggle("Delete files when deleting folder", isOn: $deleteFolderContents)
                        .tint(DesignSystem.accent)
                }
                
                Section(header: Text("Storage Management"), footer: Text(cacheClearedMessage ?? "")) {
                    HStack {
                        Text("Cached Audio")
                        Spacer()
                        Text(cacheSizeString)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button(action: { showingClearCacheAlert = true }) {
                        Text("Clear Unused Cached Audio")
                    }
                    .disabled(isClearingCache)
                    .alert("Clear Unused Cached Audio?", isPresented: $showingClearCacheAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) { clearCache() }
                    } message: {
                        Text("Removes unused generated audio. The current chapter and audio still being written are kept. You can regenerate cleared audio later.")
                    }
                    
                    NavigationLink(destination: RecentlyDeletedView()) {
                        Label("Recently Deleted", systemImage: "trash")
                    }
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("Powered by Kokoro TTS (Apache 2.0 License)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                
                Section {
                    DeleteAllDataView()
                }
            }
            .navigationTitle("Settings")
            .listStyle(.insetGrouped)
            .task {
                while !Task.isCancelled {
                    await calculateCacheSize()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .onChange(of: generation.isGeneratingAny) { Task { await calculateCacheSize() } }
            .onChange(of: scenePhase) { Task { await calculateCacheSize() } }
            .onAppear {
                voicePreferences = VoicePreferencesStore().load()
            }
        }
    }
    
    private var voiceSummaryText: String {
        switch voicePreferences.primary {
        case .kokoro(let id):
            let name = allVoiceCategories.flatMap(\.voices).first(where: { $0.id == id })?.name ?? id
            return "\(name) (Kokoro)"
        case .apple(let id):
            let name = AVSpeechSynthesisVoice(identifier: id)?.name ?? id
            return "\(name) (Apple)"
        }
    }
    
    // MARK: - Cache Management
    private func calculateCacheSize() async {
        cacheSizeString = ByteCountFormatter.string(fromByteCount: AudioCacheStore.shared.totalBytes(), countStyle: .file)
    }

    private func clearCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        Task {
            let result = await AudioCacheStore.shared.clearUnused(currentDocumentID: AudioPlaybackEngine.shared.currentDocument?.id)
            let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            cacheClearedMessage = "Cleared \(format(result.clearedBytes)). Kept \(format(result.retainedBytes)) in use. Failed to clear \(format(result.failedBytes)) (\(result.failedEntries) entries)."
            isClearingCache = false
            await calculateCacheSize()
        }
    }

}

#Preview {
    SettingsView()
}
