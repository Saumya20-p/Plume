import SwiftUI
import SwiftData

struct AddURLView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var pastedURL = ""
    @State private var isExtracting = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var fallbackTitle = ""
    @State private var fallbackBody = ""
    var destination = ImportDestination()
    var onFailedExtraction: (URL, String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/chapter-1", text: $pastedURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isExtracting)
                } header: { Text("URL") } footer: {
                    Text("Extract readable text from a web page. Saves to \(destination.name).")
                }
                if isExtracting { Section { ProgressView("Extracting text…") } }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Retry", action: importURL)
                        Button("Paste Text Manually") {
                            guard let url = try? validatedImportURL(pastedURL) else { return }
                            onFailedExtraction(url, fallbackTitle, fallbackBody)
                            dismiss()
                        }
                        .disabled((try? validatedImportURL(pastedURL)) == nil)
                    } header: { Text("Import Failed") }
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { importTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: importURL)
                        .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExtracting)
                }
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    private func importURL() {
        guard !isExtracting else { return }
        let url: URL
        do { url = try validatedImportURL(pastedURL) }
        catch { errorMessage = error.localizedDescription; return }
        isExtracting = true
        errorMessage = nil
        fallbackTitle = ""
        fallbackBody = ""
        importTask = Task { @MainActor in
            defer { isExtracting = false }
            do {
                let html = try await WebViewFetcher.shared.fetchHTML(from: url)
                try Task.checkCancellation()
                let result = ContentExtractor.extract(html: html, sourceURL: url)
                fallbackTitle = result.title
                fallbackBody = result.body
                guard !result.failed, !result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ImportFailure.extractionFailed
                }
                let folder = try destination.folder(in: modelContext)
                try Task.checkCancellation()
                let doc = Document(title: result.title, sourceURL: url, bodyText: result.body,
                                   wordCount: result.body.split(whereSeparator: \.isWhitespace).count)
                doc.folder = folder
                modelContext.insert(doc)
                do { try modelContext.save() } catch { modelContext.delete(doc); throw error }
                PlaybackQueueManager.shared.enqueue(doc.id)
                let imageURL = result.coverImageURL
                Task { @MainActor in
                    guard let data = await fetchImportArtwork(imageURL), doc.deletedAt == nil else { return }
                    doc.coverImageData = data
                }
                dismiss()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
