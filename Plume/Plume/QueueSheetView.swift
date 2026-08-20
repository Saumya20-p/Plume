import SwiftUI
import SwiftData

struct QueueSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var queueManager = PlaybackQueueManager.shared
    
    // We fetch the documents manually based on the queue UUIDs to preserve order
    @State private var queuedDocuments: [Document] = []
    
    var body: some View {
        NavigationStack {
            List {
                if queuedDocuments.isEmpty {
                        Text("No chapters in queue")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(queuedDocuments) { doc in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(doc.title)
                                .font(.headline)
                                .lineLimit(1)
                            
                            HStack {
                                if doc.audioFileURL != nil {
                                    Label("Ready", systemImage: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(DesignSystem.accent)
                                } else {
                                    Label("Will generate", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove(perform: moveItems)
                    .onDelete(perform: deleteItems)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !queuedDocuments.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadDocuments)
            .onChange(of: queueManager.queue) {
                loadDocuments()
            }
        }
    }
    
    private func loadDocuments() {
        let queueIDs = queueManager.queue
        guard !queueIDs.isEmpty else {
            queuedDocuments = []
            return
        }
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate<Document> { queueIDs.contains($0.id) }
        )
        if let docs = try? modelContext.fetch(descriptor) {
            let docDict = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
            queuedDocuments = queueIDs.compactMap { docDict[$0] }
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        queueManager.move(from: source, to: destination)
        // loadDocuments is triggered by onChange
    }
    
    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let doc = queuedDocuments[index]
            queueManager.remove(doc.id)
        }
    }
}
