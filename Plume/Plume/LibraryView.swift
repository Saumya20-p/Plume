import SwiftUI
import SwiftData

struct LibraryView: View {
    var onAdd: (Folder?) -> Void = { _ in }
    @Environment(\.modelContext) private var modelContext
    // Sort pinned items first, then by dateAdded
    @Query(filter: #Predicate<Document> { $0.deletedAt == nil },
           sort: [SortDescriptor(\Document.isPinned, order: .reverse),
                  SortDescriptor(\Document.dateAdded, order: .reverse)] as [SortDescriptor<Document>])
    private var documents: [Document]
    
    @Query(sort: \Folder.dateAdded, order: .reverse)
    private var folders: [Folder]
    
    @ObservedObject private var generationManager = AudioGenerationManager.shared
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var filterSelection: LibraryFilter = .all
    
    private var filteredDocuments: [Document] {
        documents.filter {
            LibrarySearchScope.matches(title: $0.title, progress: $0.progress, folderID: $0.folder?.id,
                                       deleted: $0.deletedAt != nil, query: searchText, filter: filterSelection)
        }
    }

    private var filteredFolders: [Folder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return folders.filter { folder in
            let active = folder.documents.filter { $0.deletedAt == nil }
            let matchesFilter = filterSelection == .all || active.contains { filterSelection.matches(progress: $0.progress) }
            return matchesFilter && (query.isEmpty || folder.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var emptyTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No search results" }
        if filterSelection != .all { return "No \(filterSelection.rawValue.lowercased()) chapters" }
        return "No chapters yet"
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Search checks chapters in Library and every folder." }
        if filterSelection != .all { return "Choose All to see your chapters." }
        return "Tap Add to import a chapter."
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom Header
                HStack {
                    Text("Library")
                        .font(.largeTitle.bold())
                        .tracking(-0.5)
                    Spacer()
                    HStack(spacing: 20) {
                        Button { onAdd(nil) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add to Library")
                        Button {
                            showingCreateFolder = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isSearchVisible.toggle()
                                if !isSearchVisible {
                                    searchText = ""
                                }
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        NavigationLink(destination: SettingsView()) {
                            Image(systemName: "gearshape")
                        }
                    }
                    .font(.title3)
                    .foregroundStyle(.primary)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, isSearchVisible ? 8 : 16)
                
                if isSearchVisible {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search all chapters", text: $searchText)
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.secondarySystemFill))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Picker("Filter", selection: $filterSelection) {
                        ForEach(LibraryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                
                if filteredDocuments.isEmpty && filteredFolders.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text(emptyTitle)
                            .font(.title3.weight(.semibold))
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if filterSelection != .all || !searchText.isEmpty {
                            Button("Clear Search and Filters") { searchText = ""; filterSelection = .all }
                        }
                    }
                    Spacer()
                } else {
                    List {
                        if !filteredFolders.isEmpty {
                            ForEach(filteredFolders) { folder in
                                NavigationLink(destination: FolderDetailView(folder: folder, onAdd: { onAdd(folder) })) {
                                    HStack(alignment: .center, spacing: 16) {
                                        if let data = folder.coverImageData, let uiImage = UIImage(data: data) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 56, height: 56)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(UIColor.secondarySystemFill))
                                                .frame(width: 56, height: 56)
                                                .overlay(
                                                    Image(systemName: "folder.fill")
                                                        .foregroundStyle(DesignSystem.accent)
                                                        .font(.title2)
                                                )
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(folder.name)
                                                .font(.body.weight(.semibold))
                                                .lineLimit(2)
                                            
                                            Text("\(folder.documents.filter { $0.deletedAt == nil }.count) chapters")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        if UserDefaults.standard.bool(forKey: "deleteFolderContents") {
                                            for doc in folder.documents {
                                                softDelete(doc)
                                            }
                                        }
                                        modelContext.delete(folder)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        
                        ForEach(filteredDocuments) { doc in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                playbackEngine.presentedPlayerDocument = doc
                            } label: {
                                LibraryRowView(doc: doc, allFolders: folders, onSoftDelete: softDelete)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                autoPurge()
                checkSharedItems()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                checkSharedItems()
            }
            .alert("New Folder", isPresented: $showingCreateFolder) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { modelContext.insert(Folder(name: trimmed)) }
                    newFolderName = ""
                }
            }
        }
    }
    
    private func softDelete(_ doc: Document) {
        PlaybackQueueManager.shared.remove(documentID: doc.id)
        doc.deletedAt = Date()
        doc.isPinned = false // unpin upon deletion so it doesn't float when restored
    }
    
    private func autoPurge() {
        // Query deleted documents directly since we don't have access to them in `documents`
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.deletedAt != nil })
        if let deletedDocs = try? modelContext.fetch(descriptor) {
            let now = Date()
            
            var urlsToDelete: [URL] = []
            var docsToDelete: [Document] = []
            
            for doc in deletedDocs {
                if let deletedAt = doc.deletedAt {
                    if let days = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day, days >= 30 {
                        // Hard delete
                        if let audioURL = doc.audioFileURL {
                            urlsToDelete.append(audioURL)
                        }
                        docsToDelete.append(doc)
                    }
                }
            }
            
            // Delete files in background
            Task.detached {
                let fileManager = FileManager.default
                for url in urlsToDelete {
                    try? fileManager.removeItem(at: url)
                }
            }
            
            // Delete models on main thread
            for doc in docsToDelete {
                modelContext.delete(doc)
            }
        }
    }
    
    private func checkSharedItems() {
        let container = AppGroup.containerURL
        guard let files = try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil) else { return }
        let sharedFiles = files.filter { $0.lastPathComponent.hasPrefix("shared_") && $0.pathExtension == "json" }
        
        for fileURL in sharedFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let item = try? JSONDecoder().decode(SharedItem.self, from: data) else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            
            // Remove temp file immediately so we don't import it twice
            try? FileManager.default.removeItem(at: fileURL)
            
            let itemURL = item.url
            let itemHTML = item.html
            
            Task {
                var title = "Shared Web Article"
                var bodyText = ""
                var coverImageURL: URL? = nil
                
                if let html = itemHTML, !html.isEmpty {
                    let extracted = ContentExtractor.extract(html: html, sourceURL: URL(string: itemURL))
                    title = extracted.title
                    bodyText = extracted.body
                    coverImageURL = extracted.coverImageURL
                } else if let url = URL(string: itemURL) {
                    if let html = try? await WebViewFetcher.shared.fetchHTML(from: url) {
                        let extracted = ContentExtractor.extract(html: html, sourceURL: url)
                        title = extracted.title
                        bodyText = extracted.body
                        coverImageURL = extracted.coverImageURL
                    }
                }
                

                if !bodyText.isEmpty {
                    let doc = Document(
                        title: title,
                        sourceURL: URL(string: itemURL),
                        bodyText: bodyText,
                        extractionFailed: false,
                        wordCount: bodyText.split(separator: " ").count
                    )
                    let artworkURL = coverImageURL
                    Task { @MainActor in
                        guard let data = await fetchImportArtwork(artworkURL), doc.deletedAt == nil else { return }
                        doc.coverImageData = data
                    }
                    modelContext.insert(doc)
                    PlaybackQueueManager.shared.enqueue(doc.id)
                    if let defaults = UserDefaults(suiteName: AppGroup.identifier),
                       let autoOpenURL = defaults.string(forKey: "autoOpenLatestSharedURL"),
                       autoOpenURL == itemURL {
                        defaults.removeObject(forKey: "autoOpenLatestSharedURL")
                        await MainActor.run {
                            playbackEngine.presentedPlayerDocument = doc
                        }
                    }
                }
            }
        }
    }
}

struct LibraryRowView: View {
    let doc: Document
    let allFolders: [Folder]
    @ObservedObject var generationManager = AudioGenerationManager.shared
    @ObservedObject var playbackEngine = AudioPlaybackEngine.shared
    var onSoftDelete: (Document) -> Void
    @State private var showingRenameAlert = false
    @State private var newDocumentTitle = ""
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
                // Cover Art Placeholder
                if let data = doc.coverImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.secondarySystemFill))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.tertiary)
                                .font(.title2)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(doc.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                        if doc.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    if let folder = doc.folder {
                        Label(folder.name, systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text("\(Int(doc.progress * 100))%")
                        Text("•")
                        Text(doc.dateAdded.formatted(.relative(presentation: .numeric)))
                        Text("•")
                        Text(sourceDomain(for: doc))
                        
                        if generationManager.generatingDocumentIDs.contains(doc.id) || playbackEngine.currentDocument?.id == doc.id {
                            Text("•")
                            Image(systemName: "waveform.circle.fill")
                                .foregroundStyle(DesignSystem.accent)
                                .symbolEffect(.pulse, options: .repeating, isActive: playbackEngine.currentDocument?.id == doc.id ? playbackEngine.isPlaying : true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                
                Spacer()
                
                Menu {
                    Button {
                        doc.isPinned.toggle()
                    } label: {
                        Label(doc.isPinned ? "Unpin" : "Pin", systemImage: doc.isPinned ? "pin.slash" : "pin")
                    }
                    
                    Button {
                        newDocumentTitle = doc.title
                        showingRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    
                    Menu("Move to Folder") {
                        ForEach(allFolders) { folder in
                            Button(folder.name) {
                                doc.folder = folder
                            }
                        }
                        if doc.folder != nil {
                            Button("Remove from Folder") {
                                doc.folder = nil
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(.vertical, 8)
            .alert("Rename", isPresented: $showingRenameAlert) {
                TextField("Title", text: $newDocumentTitle)
                Button("Cancel", role: .cancel) { newDocumentTitle = "" }
                Button("Save") {
                    doc.title = newDocumentTitle
                    newDocumentTitle = ""
                }
            }
        .contextMenu {
        }
        .swipeActions(edge: .leading) {
            Button {
                PlaybackQueueManager.shared.insertNext(doc.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(.blue)
            
            Button {
                PlaybackQueueManager.shared.enqueue(doc.id)
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onSoftDelete(doc)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            
            Button {
                doc.isPinned.toggle()
            } label: {
                Label(doc.isPinned ? "Unpin" : "Pin", systemImage: doc.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
    }
    
    private func sourceDomain(for doc: Document) -> String {
        guard let url = doc.sourceURL, let host = url.host else {
            return "Imported text"
        }
        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
        return cleanHost
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    
    var body: some View {
        Text(title)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.primary : Color(UIColor.secondarySystemFill))
            .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : Color.primary)
            .clipShape(Capsule())
    }
}

