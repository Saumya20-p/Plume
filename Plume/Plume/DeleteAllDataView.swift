import SwiftUI
import SwiftData

struct DeleteAllDataView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var documents: [Document]
    @Query private var sessions: [ListeningSession]
    
    @State private var showStep1 = false
    @State private var isDeleting = false
    
    var body: some View {
        Button(role: .destructive, action: {
            showStep1 = true
        }) {
            HStack {
                Label("Delete All Data", systemImage: "exclamationmark.triangle.fill")
                Spacer()
            }
        }
        .foregroundStyle(.red)
        .alert("Delete All Data?", isPresented: $showStep1) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                deleteAllData()
            }
        } message: {
            let totalTime = sessions.reduce(0) { $0 + $1.secondsListened }
            let hours = Int(totalTime) / 3600
            let minutes = (Int(totalTime) % 3600) / 60
            let timeString = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            
            Text("This will permanently delete \(documents.count) chapters and \(timeString) of listening history. This cannot be undone.")
        }
    }
    
    private func deleteAllData() {
        isDeleting = true
        
        Task {
            // Fetch everything explicitly to ensure full deletion
            let docDescriptor = FetchDescriptor<Document>()
            let sessionDescriptor = FetchDescriptor<ListeningSession>()
            
            let allDocs = (try? modelContext.fetch(docDescriptor)) ?? documents
            let allSessions = (try? modelContext.fetch(sessionDescriptor)) ?? sessions
            
            // Delete generated audio files first
            let fileManager = FileManager.default
            for document in allDocs {
                if let url = document.audioFileURL {
                    try? fileManager.removeItem(at: url)
                }
            }
            
            // Delete SwiftData models on MainActor
            await MainActor.run {
                for session in allSessions {
                    modelContext.delete(session)
                }
                for document in allDocs {
                    modelContext.delete(document)
                }
                
                try? modelContext.save()
                
                // Clear any playback queue state
                AudioPlaybackEngine.shared.pause()
                PlaybackQueueManager.shared.clear()
                
                // Reset states
                isDeleting = false
            }
        }
    }
}
