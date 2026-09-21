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
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            queueManager.skipTo(doc.id)
                            AudioPlaybackEngine.shared.presentedPlayerDocument = doc
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if let data = doc.coverImageData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(UIColor.secondarySystemFill))
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            Image(systemName: "book.closed.fill")
                                                .foregroundStyle(.tertiary)
                                                .font(.body)
                                        )
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(doc.title)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(1)
                                    
                                    HStack {
                                        if doc.audioFileURL != nil {
                                            Label("Ready", systemImage: "waveform")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.accent)
                                        } else {
                                            Label("Will stream", systemImage: "play.circle")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
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
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .large))
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
