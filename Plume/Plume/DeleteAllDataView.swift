import SwiftUI
import SwiftData

struct DeleteAllDataView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var documents: [Document]
    @Query private var folders: [Folder]
    
    @State private var showStep1 = false
    @State private var isDeleting = false
    @State private var deletionError: String?
    
    var body: some View {
        Button(role: .destructive, action: {
            showStep1 = true
        }) {
            HStack {
                Label("Delete All Files", systemImage: "trash")
                Spacer()
            }
        }
        .disabled(isDeleting)
        .foregroundStyle(.red)
        .alert("Deletion Incomplete", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
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
            
            PlaybackQueueManager.shared.clear()
            let result = await DocumentDeletion.permanentlyDelete(allDocs, context: modelContext)
            for folder in allFolders { modelContext.delete(folder) }
            do { try modelContext.save() } catch { deletionError = error.localizedDescription }
            if result.failedEntries > 0 { deletionError = "Files were removed, but some cached audio could not be deleted." }

            // Reset states
            isDeleting = false
        }
    }
}
