import SwiftUI
import SwiftData

struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Document> { $0.deletedAt != nil }, sort: \Document.deletedAt, order: .reverse) private var deletedDocuments: [Document]
    
    @State private var pendingDeletion: Document?
    @State private var deletionError: String?

    var body: some View {
        List {
            ForEach(deletedDocuments) { doc in
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.title)
                        .font(.body.weight(.semibold))
                    
                    if let deletedAt = doc.deletedAt {
                        let daysRemaining = max(0, 30 - (Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0))
                        Text("Deletes automatically in \(daysRemaining) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        restore(doc)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDeletion = doc
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .overlay {
            if deletedDocuments.isEmpty {
                Text("No recently deleted chapters.")
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Delete Chapter Permanently?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete Permanently", role: .destructive) {
                if let document = pendingDeletion { deletePermanently(document) }
                pendingDeletion = nil
            }
        } message: {
            Text("The chapter and its generated audio will be removed. This cannot be undone.")
        }
        .alert("Deletion Incomplete", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .onAppear {
            autoPurge()
        }
    }
    
    private func restore(_ doc: Document) {
        doc.deletedAt = nil
    }
    
    private func deletePermanently(_ doc: Document) {
        Task {
            let result = await DocumentDeletion.permanentlyDelete([doc], context: modelContext)
            do { try modelContext.save() } catch { deletionError = error.localizedDescription }
            if result.failedEntries > 0 { deletionError = "The chapter was removed, but some cached audio could not be deleted." }
        }
    }
    
    private func autoPurge() {
        let now = Date()
        for doc in deletedDocuments {
            if let deletedAt = doc.deletedAt {
                if let days = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day, days >= 30 {
                    deletePermanently(doc)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecentlyDeletedView()
    }
}
