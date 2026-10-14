import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

struct MainTabView: View {
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    @Environment(\.modelContext) private var modelContext
    
    @State private var showAddSheet = false
    @State private var importDestination = ImportDestination()
    
    // Import State
    @State private var showingAddURL = false
    @State private var showingManualPaste = false
    @State private var failedTitle: String = ""
    @State private var failedBody: String = ""
    @State private var failedURL: URL? = nil
    
    // New Feature State
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var showingFileImporter = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var fileImportTask: Task<Void, Never>?
    @State private var isImportingFile = false
    @State private var pendingManualFallback = false
    @State private var failedDestination = ImportDestination()

    var body: some View {
        LibraryView(onAdd: { folder in
            importDestination = ImportDestination(folderID: folder?.id, name: folder?.name ?? "Library")
            showAddSheet = true
        }, onManualImport: { url, title, body in
            importDestination = ImportDestination()
            failedURL = url
            failedTitle = title
            failedBody = body
            showingManualPaste = true
        })
        .disabled(isImportingFile)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !playbackEngine.isPlayerViewPresented, let doc = playbackEngine.currentDocument {
                MiniPlayerView(document: doc)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .fullScreenCover(item: $playbackEngine.presentedPlayerDocument) { doc in
            NavigationStack {
                PlayerView(document: doc)
                    .equatable()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMenuSheet(
                destinationName: importDestination.name,
                allowsCreateFolder: importDestination.folderID == nil,
                onCreateFolder: {
                    showAddSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingCreateFolder = true
                    }
                },
                onImportFile: {
                    showAddSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingFileImporter = true
                    }
                },
                onPasteLink: {
                    showAddSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingAddURL = true
                    }
                },
                onPasteText: {
                    showAddSheet = false
                    failedTitle = ""
                    failedBody = ""
                    failedURL = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingManualPaste = true
                    }
                }
            )
            .presentationDetents([.height(320), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAddURL, onDismiss: {
            if pendingManualFallback { pendingManualFallback = false; showingManualPaste = true }
        }) {
            AddURLView(destination: importDestination, onFailedExtraction: { url, title, body in
                self.failedURL = url
                self.failedTitle = title
                self.failedBody = body
                self.pendingManualFallback = true
            })
        }
        .sheet(isPresented: $showingManualPaste) {
            ManualPasteView(

                title: failedTitle,
                bodyText: failedBody,
                destinationName: importDestination.name,
                onSave: { newTitle, newBody in
                    let folder = try importDestination.folder(in: modelContext)
                    let doc = Document(title: newTitle, sourceURL: failedURL, bodyText: newBody,
                                       wordCount: newBody.split(whereSeparator: \.isWhitespace).count)
                    doc.folder = folder
                    modelContext.insert(doc)
                    do { try modelContext.save() } catch { modelContext.delete(doc); throw error }
                    PlaybackQueueManager.shared.enqueue(doc.id)
                }
            )
        }
        .alert("New Folder", isPresented: $showingCreateFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let folder = Folder(name: trimmed)
                    modelContext.insert(folder)
                }
                newFolderName = ""
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf, .plainText, .epub],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .overlay {
            if isImportingFile {
                VStack(spacing: 16) {
                    ProgressView("Importing file…")
                    Button("Cancel Import") { fileImportTask?.cancel() }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onDisappear { fileImportTask?.cancel() }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("Choose File Again") { importDestination = failedDestination; showingFileImporter = true }
            Button("Paste Text Manually") { importDestination = failedDestination; failedURL = nil; failedBody = ""; showingManualPaste = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
    }
    
    private func handleFileImport(result: Result<[URL], Error>) {
        failedDestination = importDestination
        switch result {
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            importErrorMessage = error.localizedDescription
            showingImportError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let destination = importDestination
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                    do { try FileManager.default.copyItem(at: source, to: copy) }
                    catch { copyError = error }
                }
                if let error = copyError ?? coordinationError { throw error }
                let title = url.deletingPathExtension().lastPathComponent
                failedTitle = title
                isImportingFile = true
                fileImportTask = Task { @MainActor in
                    defer {
                        isImportingFile = false
                        try? FileManager.default.removeItem(at: copy)
                    }
                    let parser = Task.detached { try ImportFileContent.parse(url: copy, fallbackTitle: title) }
                    do {
                        let content = try await withTaskCancellationHandler {
                            try await parser.value
                        } onCancel: { parser.cancel() }
                        try Task.checkCancellation()
                        let destinationFolder = try destination.folder(in: modelContext)
                        let folder = destinationFolder ?? (destination.createsBookFolder(isEPUB: content.isBook) ? Folder(name: content.title) : nil)
                        var inserted: [Document] = []
                        if destinationFolder == nil, let folder {
                            folder.coverImageData = content.coverImageData
                            modelContext.insert(folder)
                        }
                        for chapter in content.chapters {
                            let doc = Document(title: chapter.title, bodyText: chapter.bodyText, wordCount: chapter.wordCount)
                            doc.folder = folder
                            doc.coverImageData = content.coverImageData
                            modelContext.insert(doc)
                            inserted.append(doc)
                        }
                        do { try modelContext.save() }
                        catch {
                            inserted.forEach { modelContext.delete($0) }
                            if destinationFolder == nil, let folder { modelContext.delete(folder) }
                            throw error
                        }
                        if let first = inserted.first { PlaybackQueueManager.shared.enqueue(first.id) }
                    } catch is CancellationError {
                    } catch {
                        guard !Task.isCancelled else { return }
                        failedDestination = destination
                        importErrorMessage = error.localizedDescription
                        showingImportError = true
                    }
                }
            } catch {
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
    }

}



struct AddMenuSheet: View {
    var destinationName: String = "Library"
    var allowsCreateFolder = true
    var onCreateFolder: () -> Void
    var onImportFile: () -> Void
    var onPasteLink: () -> Void
    var onPasteText: () -> Void
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allowsCreateFolder { AddMenuRow(icon: "folder.badge.plus", title: "Create Folder", action: onCreateFolder) }
                    AddMenuRow(icon: "plus", title: "Import File", action: onImportFile)
                    AddMenuRow(icon: "link", title: "Paste Link", action: onPasteLink)
                    AddMenuRow(icon: "text.cursor", title: "Type or Paste Text", action: onPasteText)
                }
                

            }
            .navigationTitle("Add to \(destinationName)")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(.top)
        }
        .presentationBackground(.ultraThinMaterial)

    }
}

struct AddMenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 32)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
}

struct MiniPlayerView: View {
    let document: Document
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    
    var body: some View {
        HStack {
            Button { playbackEngine.presentedPlayerDocument = document } label: {
            HStack {
            if let data = document.coverImageData, let uiImage = UIImage(data: data) {
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
                
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(playbackEngine.isPlaying ? "Playing..." : "Paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player for \(document.title)")
            Button(action: { playbackEngine.togglePlayPause() }) {
                Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel(playbackEngine.isPlaying ? "Pause" : "Play")
            .frame(minWidth: 44, minHeight: 44)
            .tint(.primary)
            .padding(.trailing, 8)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 10)
        .contentShape(Rectangle())

    }
}

#Preview {
    MainTabView()
}

@MainActor extension ImportDestination {
    func folder(in context: ModelContext) throws -> Folder? {
        guard folderID != nil else { return nil }
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let resolvedID = try resolveFolderID(availableIDs: Set(folders.map(\.id)))
        return folders.first { $0.id == resolvedID }
    }
}
