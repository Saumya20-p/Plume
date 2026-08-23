import SwiftUI
import SwiftData

struct DeleteAllDataView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var documents: [Document]
    @Query private var folders: [Folder]
    
    @State private var showStep1 = false
    @State private var isDeleting = false
    
    var body: some View {
        Button(role: .destructive, action: {
            showStep1 = true
        }) {
            HStack {
                Label("Delete All Files", systemImage: "trash")
                Spacer()
            }
        }
        .foregroundStyle(.red)
        .alert("Delete All Files?", isPresented: $showStep1) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will permanently delete \(documents.count) chapters and all folders. Your listening history and statistics will be preserved. This cannot be undone.")
        }
    }
    
    private func deleteAllData() {
        isDeleting = true
        
        Task { @MainActor in
            // Fetch everything explicitly to ensure full deletion
            let docDescriptor = FetchDescriptor<Document>()
            let folderDescriptor = FetchDescriptor<Folder>()
            
            let allDocs = (try? modelContext.fetch(docDescriptor)) ?? documents
            let allFolders = (try? modelContext.fetch(folderDescriptor)) ?? folders
            
            // Clear any playback queue and generation state FIRST to prevent UI crashes on deleted objects
            AudioPlaybackEngine.shared.pause()
            AudioPlaybackEngine.shared.currentDocument = nil
            AudioPlaybackEngine.shared.presentedPlayerDocument = nil
            AudioPlaybackEngine.shared.chunks = []
            PlaybackProgress.shared.currentWord = nil
            PlaybackProgress.shared.currentTime = 0
            PlaybackQueueManager.shared.clear()
            AudioGenerationManager.shared.cancelCurrentGeneration()
            
            // Delete generated audio files and caches
            let fileManager = FileManager.default
            for document in allDocs {
                if let url = document.audioFileURL {
                    try? fileManager.removeItem(at: url)
                }
                try? fileManager.removeItem(at: document.audioCacheDirectory)
            }
            
            // Delete SwiftData models (documents first to avoid .nullify cascade overhead)
            for document in allDocs {
                modelContext.delete(document)
            }
            for folder in allFolders {
                modelContext.delete(folder)
            }
            
            try? modelContext.save()
            
            // Reset states
            isDeleting = false
        }
    }
}
