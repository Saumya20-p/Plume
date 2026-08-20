import SwiftUI
import SwiftData

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: Folder
    
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
                        .font(.headline)
                    Text("Tap + to add a chapter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(activeDocs) { doc in
                        LibraryRowView(doc: doc, allFolders: allFolders, onSoftDelete: { d in
                            d.deletedAt = Date()
                            d.isPinned = false
                        })
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
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
