import SwiftUI
import SwiftData

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    let folder: Folder
    var onAdd: () -> Void = {}
    
    @Query(sort: \Folder.dateAdded, order: .reverse)
    private var allFolders: [Folder]
    
    @State private var showingAddSheet = false
    @State private var showingFileImporter = false
    @State private var showingRenameFolder = false
    @State private var newFolderName = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            let activeDocs = folder.documents.filter { $0.deletedAt == nil }.sorted { $0.dateAdded > $1.dateAdded }
            
            if activeDocs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Folder is empty")
                        .font(.title3.weight(.semibold))
                    Text("Tap Add to import into this folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(activeDocs) { doc in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            playbackEngine.presentedPlayerDocument = doc
                        } label: {
                            LibraryRowView(doc: doc, allFolders: allFolders, onSoftDelete: { d in
                                PlaybackQueueManager.shared.remove(documentID: d.id)
                                d.deletedAt = Date()
                                d.isPinned = false
                            })
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus", action: onAdd)
                    .accessibilityLabel("Add to \(folder.name)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newFolderName = folder.name
                        showingRenameFolder = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if UserDefaults.standard.bool(forKey: "deleteFolderContents") {
                            for doc in folder.documents {
                                PlaybackQueueManager.shared.remove(documentID: doc.id)
                                doc.deletedAt = Date()
                                doc.isPinned = false
                            }
                        }
                        modelContext.delete(folder)
                        dismiss()
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .alert("Rename Folder", isPresented: $showingRenameFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Save") {
                folder.name = newFolderName
                newFolderName = ""
            }
        }
    }
}
