import SwiftUI
import SwiftData
import os

struct SettingsView: View {
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage("defaultSkipInterval") private var defaultSkipInterval: Int = 15
    @Query private var documents: [Document]
    
    @State private var showingClearCacheAlert = false
    @State private var cacheClearedMessage: String?
    @State private var cacheSizeString: String = "Calculating..."
    
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
                    HStack {
                        Text("Selected Voice")
                        Spacer()
                        Text("af_heart")
                            .foregroundStyle(.secondary)
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
                        Text("Clear All Cached Audio")
                    }
                    .alert("Clear Cached Audio?", isPresented: $showingClearCacheAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) { clearCache() }
                    } message: {
                        Text("This will delete all generated audio files, freeing up space. You can regenerate audio for chapters later.")
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
            .safeAreaPadding(.bottom, 120)
            .task(id: documents.count) {
                await calculateCacheSize()
            }
        }
    }
    
    // MARK: - Cache Management
    private func calculateCacheSize() async {
        // Extract URLs to avoid accessing SwiftData models off MainActor
        let urls = documents.compactMap { $0.audioFileURL }
        
        let sizeString = await Task.detached { () -> String in
            let fileManager = FileManager.default
            var totalBytes: Int64 = 0
            
            for url in urls {
                if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? Int64 {
                    totalBytes += size
                }
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: totalBytes)
        }.value
        
        await MainActor.run {
            self.cacheSizeString = sizeString
        }
    }
    
    private func clearCache() {
        // Extract documents with URLs
        let docsWithAudio = documents.filter { $0.audioFileURL != nil }
        let urls = docsWithAudio.compactMap { $0.audioFileURL }
        
        Task {
            let filesDeleted = await Task.detached { () -> Int in
                let fileManager = FileManager.default
                var count = 0
                for url in urls {
                    do {
                        try fileManager.removeItem(at: url)
                        count += 1
                    } catch {
                        print("Failed to delete \(url.path): \(error.localizedDescription)")
                    }
                }
                return count
            }.value
            
            await MainActor.run {
                
                cacheClearedMessage = "Cleared \(filesDeleted) audio files."
                
                // Clear message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    cacheClearedMessage = nil
                }
                
                // Recalculate cache size
                Task {
                    await calculateCacheSize()
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
