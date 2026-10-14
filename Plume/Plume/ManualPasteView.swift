import SwiftUI

struct ManualPasteView: View {
    @Environment(\.dismiss) private var dismiss
    

    @State private var title: String
    @State private var bodyText: String
    
    let destinationName: String

    init(title: String, bodyText: String, destinationName: String = "Library", onSave: @escaping (String, String) -> Void) {
        _title = State(initialValue: title)
        _bodyText = State(initialValue: bodyText)
        self.destinationName = destinationName
        self.onSave = onSave
    }

    var onSave: (String, String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
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
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Chapter" : title, bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                }
            }
        }
    }
}
