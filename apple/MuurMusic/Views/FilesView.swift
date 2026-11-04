import SwiftUI
import UniformTypeIdentifiers
import MuurCore
import MuurAudio

/// File manager: pick a source, browse, organize and upload files.
struct FilesView: View {
    @EnvironmentObject var model: AppModel

    /// Kinds that make sense in the file manager.
    private var manageable: [SourceConfig] {
        model.sources.filter { config in
            switch config.kind {
            case .subsonic, .jellyfin, .emby, .plex, .upnp:
                return false
            default:
                return true
            }
        }
    }

    var body: some View {
        Group {
            if manageable.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No file sources",
                    message: "Add a folder, NAS or cloud drive in Sources first.",
                    actionTitle: "Add Source",
                    action: { model.navigate(to: .sources) }
                )
            } else {
                List(manageable) { config in
                    NavigationLink(value: config) {
                        SourceRow(config: config)
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .navigationTitle("Files")
        .navigationDestination(for: SourceConfig.self) { config in
            FileBrowserView(config: config)
        }
    }
}

/// Browses one source with multi-select and file operations.
struct FileBrowserView: View {
    @EnvironmentObject var model: AppModel

    let config: SourceConfig

    @State private var source: (any MusicSource)?
    @State private var connectError: String?

    var body: some View {
        Group {
            if let source {
                FileListView(source: source, container: nil)
            } else if let connectError {
                EmptyStateView(
                    illustration: .offline,
                    title: "Cannot connect",
                    message: connectError,
                    actionTitle: "Try Again",
                    action: { connect() }
                )
            } else {
                LoadingView(message: "Connecting…")
            }
        }
        .navigationTitle(config.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: SourceItem.self) { item in
            if let source {
                FileListView(source: source, container: item)
                    .navigationTitle(item.name)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }
        .task { connect() }
    }

    private func connect() {
        connectError = nil
        source = nil
        Task {
            do {
                let resolved = try model.environment.sources.source(for: config)
                try await resolved.connect()
                source = resolved
            } catch {
                connectError = error.localizedDescription
            }
        }
    }
}

/// One folder level with selection and operations.
struct FileListView: View {
    @EnvironmentObject var model: AppModel

    let source: any MusicSource
    let container: SourceItem?

    @State private var items: [SourceItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: SourceItem?
    @State private var renameText = ""
    @State private var isImporting = false
    @State private var sharedFile: SharedFile?

    private var capabilities: SourceCapabilities { source.capabilities }

    private var sorted: [SourceItem] {
        items.sorted { lhs, rhs in
            if lhs.isContainer != rhs.isContainer { return lhs.isContainer && !rhs.isContainer }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedItems: [SourceItem] {
        sorted.filter { selection.contains($0.uri) }
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let error {
                EmptyStateView(illustration: .offline, title: "Could not load", message: error, actionTitle: "Retry", action: load)
            } else if items.isEmpty {
                EmptyStateView(illustration: .library, title: "Empty folder", message: "Nothing here yet.")
            } else {
                List(sorted, selection: $selection) { item in
                    row(for: item)
                        .tag(item.uri)
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .muurEditMode($editMode)
        .toolbar { toolbarContent }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleUpload(result)
        }
        .sheet(item: $sharedFile) { file in
            MuurShareSheet(file: file)
        }
        .task(id: container?.uri) { load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation {
                    editMode = editMode.isEditing ? .inactive : .active
                    selection.removeAll()
                }
            } label: {
                Text(editMode.isEditing ? "Done" : "Select")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if editMode.isEditing {
                    Button { addSelectedToLibrary() } label: {
                        Label("Add to Library", systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button { downloadSelected() } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    if capabilities.contains(.delete) {
                        Divider()
                        Button(role: .destructive) { deleteSelected() } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                    }
                } else {
                    if capabilities.contains(.createFolder) {
                        Button { isCreatingFolder = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    }
                    if capabilities.contains(.upload) {
                        Button { isImporting = true } label: {
                            Label("Upload Files…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { addFolderToLibrary() } label: {
                        Label("Add This Folder to Library", systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button { playFolder() } label: {
                        Label("Play Folder", systemImage: "play.circle")
                    }
                }
            } label: {
                Image(systemName: editMode.isEditing ? "checklist" : "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func row(for item: SourceItem) -> some View {
        let label = SourceItemRow(item: item)
        if editMode.isEditing {
            label
        } else if item.isContainer {
            NavigationLink(value: item) { label }
                .contextMenu { itemMenu(item) }
        } else {
            label
                .contentShape(Rectangle())
                .onTapGesture { play(item) }
                .contextMenu { itemMenu(item) }
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: SourceItem) -> some View {
        if item.isPlayable {
            Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
            Button { model.playLater([source.makeTrack(for: item)]) } label: {
                Label("Play Later", systemImage: "text.append")
            }
        }
        Button { addToLibrary([item]) } label: {
            Label("Add to Library", systemImage: "plus.rectangle.on.rectangle")
        }
        if item.isPlayable {
            Button { model.download([source.makeTrack(for: item)]) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        if capabilities.contains(.rename) {
            Button {
                renameText = item.name
                renameTarget = item
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
        if capabilities.contains(.delete) {
            Divider()
            Button(role: .destructive) { delete([item]) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    // MARK: Actions

    private func play(_ item: SourceItem) {
        let audioItems = sorted.filter(\.isPlayable)
        guard let index = audioItems.firstIndex(of: item) else { return }
        model.play(audioItems.map { source.makeTrack(for: $0) }, startIndex: index)
    }

    private func playFolder() {
        Task {
            do {
                let audio = try await source.collectAudio(under: container)
                model.play(audio.map { source.makeTrack(for: $0) })
            } catch {
                model.showError(error)
            }
        }
    }

    private func addToLibrary(_ targets: [SourceItem]) {
        Task {
            do {
                let tracks = try await model.environment.sources.addToLibrary(targets, from: source)
                model.showToast(.success("Added \(tracks.count) track(s)", systemImage: "plus.rectangle.on.rectangle"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func addSelectedToLibrary() {
        let targets = selectedItems
        clearSelection()
        addToLibrary(targets)
    }

    private func addFolderToLibrary() {
        if let container {
            addToLibrary([container])
        } else {
            addToLibrary(sorted)
        }
    }

    private func downloadSelected() {
        let audio = selectedItems.filter(\.isPlayable).map { source.makeTrack(for: $0) }
        clearSelection()
        model.download(audio)
    }

    private func deleteSelected() {
        let targets = selectedItems
        clearSelection()
        delete(targets)
    }

    private func delete(_ targets: [SourceItem]) {
        Task {
            do {
                for item in targets {
                    try await source.delete(item)
                }
                model.showToast(.success("Deleted", systemImage: "trash"))
                load()
            } catch {
                model.showError(error)
            }
        }
    }

    private func createFolder() {
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !folderName.isEmpty else { return }
        Task {
            do {
                try await source.createFolder(named: folderName, in: container)
                load()
            } catch {
                model.showError(error)
            }
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !newName.isEmpty, newName != target.name else { return }
        Task {
            do {
                try await source.rename(target, to: newName)
                load()
            } catch {
                model.showError(error)
            }
        }
    }

    private func handleUpload(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.showError(error)
        case .success(let urls):
            Task {
                var uploaded = 0
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    do {
                        // Copy to a temp file so the upload outlives the security scope.
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                        try FileManager.default.copyItem(at: url, to: temp)
                        if accessing { url.stopAccessingSecurityScopedResource() }
                        try await source.upload(from: temp, to: container, fileName: url.lastPathComponent)
                        try? FileManager.default.removeItem(at: temp)
                        uploaded += 1
                    } catch {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                        model.showError(error)
                    }
                }
                if uploaded > 0 {
                    model.showToast(.success("Uploaded \(uploaded) file(s)", systemImage: "square.and.arrow.up"))
                    load()
                }
            }
        }
    }

    private func clearSelection() {
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    private func load() {
        isLoading = true
        error = nil
        Task {
            do {
                items = try await source.list(container)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
