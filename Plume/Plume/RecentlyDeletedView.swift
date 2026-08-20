import SwiftUI
import SwiftData

struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Document> { $0.deletedAt != nil }, sort: \Document.deletedAt, order: .reverse) private var deletedDocuments: [Document]
    
    var body: some View {
        List {
            ForEach(deletedDocuments) { doc in
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.title)
                        .font(.headline)
                    
                    if let deletedAt = doc.deletedAt {
                        let daysRemaining = max(0, 30 - Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day!)
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
                        deletePermanently(doc)
                    } label: {
                        Label("Delete", systemImage: "trash")
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
        .onAppear {
            autoPurge()
        }
    }
    
    private func restore(_ doc: Document) {
        doc.deletedAt = nil
    }
    
    private func deletePermanently(_ doc: Document) {
        // Delete audio file if it exists
        if let audioURL = doc.audioFileURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        modelContext.delete(doc)
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
