import SwiftUI

struct ManualPasteView: View {
    @Environment(\.dismiss) private var dismiss
    
    let url: URL?
    @State var title: String
    @State var bodyText: String
    
    var onSave: (String, String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Chapter Title")) {
                    TextField("Title", text: $title)
                }
                
                Section(header: Text("Chapter Content"), footer: Text("Paste the chapter text here.")) {
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
                        onSave(title, bodyText)
                        dismiss()
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                }
            }
        }
    }
}
