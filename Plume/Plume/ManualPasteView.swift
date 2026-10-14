import SwiftUI

struct ManualPasteView: View {
    @Environment(\.dismiss) private var dismiss
    

    @State private var title: String
    @State private var bodyText: String
    @State private var errorMessage: String?
    
    let destinationName: String

    init(title: String, bodyText: String, destinationName: String = "Library", onSave: @escaping (String, String) throws -> Void) {
        _title = State(initialValue: title)
        _bodyText = State(initialValue: bodyText)
        self.destinationName = destinationName
        self.onSave = onSave
    }

    var onSave: (String, String) throws -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
                Section(header: Text("Chapter Title")) {
                    TextField("Title", text: $title)
                }
                
                Section(header: Text("Chapter Content"), footer: Text("Paste the chapter text here. Saves to \(destinationName).")) {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 300)
                }
            }
            .navigationTitle("Manual Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            try onSave(trimmedTitle.isEmpty ? "Untitled Chapter" : trimmedTitle, bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
