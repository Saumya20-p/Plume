import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

struct MainTabView: View {
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    @Environment(\.modelContext) private var modelContext
    
    @State private var showAddSheet = false
    
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

    var body: some View {
        ZStack(alignment: .bottom) {
            // Main Content
            LibraryView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            VStack(spacing: 0) {
                Spacer()
                
                if !playbackEngine.isPlayerViewPresented {
                    HStack(spacing: 16) {
                        if let doc = playbackEngine.currentDocument {
                            MiniPlayerView(document: doc)
                        } else {
                            Spacer()
                        }
                        
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(DesignSystem.accent)
                                .clipShape(Circle())
                                .shadow(radius: 10, y: 5)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(item: $playbackEngine.presentedPlayerDocument) { doc in
            NavigationStack {
                PlayerView(document: doc)
                    .equatable()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMenuSheet(
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
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAddURL) {
            AddURLView(onFailedExtraction: { url, title, body in
                self.failedURL = url
                self.failedTitle = title
                self.failedBody = body
                self.showingManualPaste = true
            })
        }
        .sheet(isPresented: $showingManualPaste) {
            ManualPasteView(
                url: failedURL,
                title: failedTitle,
                bodyText: failedBody,
                onSave: { newTitle, newBody in
                    let wordCount = newBody.split(separator: .init(" ")).count
                    
                    let descriptor = FetchDescriptor<Document>()
                    let allDocs = try? modelContext.fetch(descriptor)
                    
                    if let url = failedURL, let existingDoc = allDocs?.first(where: { $0.sourceURL == url }) {
                        existingDoc.title = newTitle
                        existingDoc.bodyText = newBody
                        existingDoc.wordCount = wordCount
                        existingDoc.extractionFailed = false
                    } else {
                        let doc = Document(
                            title: newTitle,
                            sourceURL: failedURL,
                            bodyText: newBody,
                            extractionFailed: false,
                            wordCount: wordCount
                        )
                        modelContext.insert(doc)
                        PlaybackQueueManager.shared.enqueue(doc.id)
                    }
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
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
    }
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            // Handle EPUB files separately
            if url.pathExtension.lowercased() == "epub" {
                handleEPUBImport(url: url)
                return
            }
            
            var parsedText = ""
            let title = url.deletingPathExtension().lastPathComponent
            
            if url.pathExtension.lowercased() == "pdf" {
                if let pdf = PDFDocument(url: url) {
                    for i in 0..<pdf.pageCount {
                        if let page = pdf.page(at: i) {
                            parsedText += page.string ?? ""
                            parsedText += "\n\n"
                        }
                    }
                }
            } else {
                parsedText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            
            let trimmedText = parsedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let wordCount = trimmedText.split(separator: .init(" ")).count
                let doc = Document(title: title, bodyText: trimmedText, wordCount: wordCount)
                modelContext.insert(doc)
                PlaybackQueueManager.shared.enqueue(doc.id)
            }
        case .failure(let error):
            self.importErrorMessage = error.localizedDescription
            self.showingImportError = true
        }
    }
    
    private func handleEPUBImport(url: URL) {
        do {
            var coordinatedError: NSError?
            var finalError: Error?
            
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatedError) { (secureURL) in
                do {
                    let tempCopy = FileManager.default.temporaryDirectory
                        .appendingPathComponent("import_\(UUID().uuidString).epub")
                    try FileManager.default.copyItem(at: secureURL, to: tempCopy)
                    
                    let extractedFilename = url.deletingPathExtension().lastPathComponent
                    let fallbackTitle = extractedFilename.isEmpty ? "Untitled Book" : extractedFilename
                    
                    Task {
                        defer { try? FileManager.default.removeItem(at: tempCopy) }
                        do {
                            let book = try EPUBParser.parse(epubURL: tempCopy, fallbackTitle: fallbackTitle)
                            
                            await MainActor.run {
                                let folder = Folder(name: book.title)
                                folder.coverImageData = book.coverImageData
                                modelContext.insert(folder)
                                
                                for chapter in book.chapters {
                                    let doc = Document(
                                        title: chapter.title,
                                        bodyText: chapter.bodyText,
                                        wordCount: chapter.wordCount
                                    )
                                    doc.folder = folder
                                    doc.coverImageData = book.coverImageData
                                    modelContext.insert(doc)
                                }
                                
                                try? modelContext.save()
                                
                                if let firstDoc = folder.documents.first {
                                    PlaybackQueueManager.shared.enqueue(firstDoc.id)
                                }
                            }
                        } catch {
                            await MainActor.run {
                                self.importErrorMessage = error.localizedDescription
                                self.showingImportError = true
                            }
                        }
                    }
                } catch {
                    finalError = error
                }
            }
            
            if let error = finalError ?? coordinatedError {
                throw error
            }
        } catch {
            self.importErrorMessage = error.localizedDescription
            self.showingImportError = true
        }
    }
}



struct AddMenuSheet: View {
    var onCreateFolder: () -> Void
    var onImportFile: () -> Void
    var onPasteLink: () -> Void
    var onPasteText: () -> Void
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    AddMenuRow(icon: "folder.badge.plus", title: "Create Folder", action: onCreateFolder)
                    AddMenuRow(icon: "plus", title: "Import File", action: onImportFile)
                    AddMenuRow(icon: "link", title: "Paste Link", action: onPasteLink)
                    AddMenuRow(icon: "text.cursor", title: "Type or Paste Text", action: onPasteText)
                }
                

            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(.top)
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(240)))
        .presentationDetents([.height(240)])
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
                    .lineLimit(1)
                Text(playbackEngine.isPlaying ? "Playing..." : "Paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { playbackEngine.togglePlayPause() }) {
                Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
            .padding(.trailing, 8)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if playbackEngine.presentedPlayerDocument?.id == document.id {
                playbackEngine.presentedPlayerDocument = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    playbackEngine.presentedPlayerDocument = document
                }
            } else {
                playbackEngine.presentedPlayerDocument = document
            }
        }
    }
}

#Preview {
    MainTabView()
}
