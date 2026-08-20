import SwiftUI
import SwiftData
import os

struct AddURLView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var pastedURL: String = ""
    @State private var isExtracting = false
    
    var onFailedExtraction: (URL, String, String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("URL"), footer: Text("Paste a link to a web novel chapter. Plume will automatically extract the content.")) {
                    TextField("https://example.com/chapter-1", text: $pastedURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                
                if isExtracting {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Extracting...")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isExtracting)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importURL()
                    }
                    .disabled(pastedURL.isEmpty || isExtracting)
                }
            }
        }
        .interactiveDismissDisabled(isExtracting)
    }
    
    private func importURL() {
        guard !isExtracting else { return }
        guard let url = URL(string: pastedURL) else { return }
        isExtracting = true
        
        Task {
            do {
                let html = try await WebViewFetcher.shared.fetchHTML(from: url)
                let result = ContentExtractor.extract(html: html, sourceURL: url)
                
                var coverImageData: Data? = nil
                if let imageURL = result.coverImageURL {
                    var request = URLRequest(url: imageURL)
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200 {
                        coverImageData = data
                    }
                }
                
                await MainActor.run {
                    if result.failed {
                        // Pass back to parent to show ManualPasteView
                        onFailedExtraction(url, result.title, result.body)
                        dismiss()
                    } else {
                        let wordCount = result.body.components(separatedBy: .whitespacesAndNewlines).filter({!$0.isEmpty}).count
                        let doc = Document(
                            title: result.title,
                            sourceURL: url,
                            bodyText: result.body,
                            extractionFailed: false,
                            wordCount: wordCount
                        )
                        doc.coverImageData = coverImageData
                        modelContext.insert(doc)
                        PlaybackQueueManager.shared.enqueue(doc.id)
                        dismiss()
                    }
                }
            } catch {
                Log.network.error("Failed to fetch HTML: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { isExtracting = false }
            }
        }
    }
}
