import SwiftUI
import UniformTypeIdentifiers
import MuurCore
import MuurAudio

/// All playlists: create, rename, duplicate, delete, reorder, import/export.
struct PlaylistsView: View {
    @EnvironmentObject var model: AppModel

    @State private var isShowingNewPlaylist = false
    @State private var newName = ""
    @State private var isImporting = false
    @State private var renameTarget: Playlist?
    @State private var renameText = ""
    @State private var deleteTarget: Playlist?
    @State private var sharedFile: SharedFile?
    @State private var deepLinkedPlaylist: Playlist?

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No playlists yet",
                    message: "Build the perfect mixtape — or let a smart playlist do it for you.",
                    actionTitle: "New Playlist",
                    action: { isShowingNewPlaylist = true }
                )
            } else {
                List {
                    ForEach(model.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist)
                        }
                        .contextMenu { playlistMenu(playlist) }
                    }
                    .onMove(perform: move)
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .muurScreen()
        .navigationTitle("Playlists")
        .navigationDestination(for: Playlist.self) { playlist in
            if let id = playlist.id {
                PlaylistDetailView(playlistID: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isShowingNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    Button {
                        createSmart()
                    } label: {
                        Label("New Smart Playlist", systemImage: "wand.and.stars")
                    }
                    Divider()
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Playlist…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add playlist")
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            #endif
        }
        .alert("New Playlist", isPresented: $isShowingNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename Playlist", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete “\(deleteTarget?.name ?? "")”?", isPresented: deletePresented) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The playlist is removed; your songs stay in the library.")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $sharedFile) { file in
            MuurShareSheet(file: file)
        }
        .sheet(item: $deepLinkedPlaylist) { playlist in
            if let id = playlist.id {
                NavigationStack {
                    PlaylistDetailView(playlistID: id)
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 560)
                #endif
            }
        }
        .onChange(of: model.openPlaylistID) { _, id in
            guard let id, let playlist = model.playlists.first(where: { $0.id == id }) else { return }
            deepLinkedPlaylist = playlist
            model.openPlaylistID = nil
        }
    }

    private static var importTypes: [UTType] {
        let custom = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        return custom + [.json, .plainText, .data]
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        Button {
            renameText = playlist.name
            renameTarget = playlist
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            duplicate(playlist)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Menu {
            ForEach(PlaylistExportFormat.allCases, id: \.self) { format in
                Button {
                    export(playlist, format: format)
                } label: {
                    Text(format == .smart ? "Smart Playlist (.muursmart.json)" : format.rawValue.uppercased())
                }
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = playlist
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            do {
                _ = try await model.environment.playlists.create(name: name)
            } catch {
                model.showError(error)
            }
        }
    }

    private func createSmart() {
        let definition = SmartPlaylistDefinition(
            name: "New Smart Playlist",
            match: .all,
            rules: [SmartRule(field: .rating, op: .gt, value: .number(3))],
            sort: "title",
            limit: 0
        )
        Task {
            do {
                _ = try await model.environment.playlists.createSmart(definition)
            } catch {
                model.showError(error)
            }
        }
    }

    private func commitRename() {
        guard let playlist = renameTarget, let id = playlist.id else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task {
            do {
                try await model.environment.playlists.rename(id: id, to: name)
            } catch {
                model.showError(error)
            }
        }
    }

    private func commitDelete() {
        guard let playlist = deleteTarget, let id = playlist.id else { return }
        deleteTarget = nil
        Task {
            do {
                try await model.environment.playlists.delete(id: id)
            } catch {
                model.showError(error)
            }
        }
    }

    private func duplicate(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        Task {
            do {
                _ = try await model.environment.playlists.duplicate(id: id)
            } catch {
                model.showError(error)
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = model.playlists
        ordered.move(fromOffsets: source, toOffset: destination)
        let ids = ordered.compactMap(\.id)
        Task {
            do {
                try await model.environment.playlists.reorderPlaylists(ids)
            } catch {
                model.showError(error)
            }
        }
    }

    private func export(_ playlist: Playlist, format: PlaylistExportFormat) {
        guard let id = playlist.id else { return }
        Task {
            do {
                let data = try await model.environment.playlists.export(id: id, format: format, fileURI: nil)
                let name = PathUtils.sanitizeFileName(playlist.name) + "." + format.fileExtension
                sharedFile = try SharedFile.write(data: data, fileName: name)
            } catch {
                model.showError(error)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.showError(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let importResult = try await model.environment.playlists.importPlaylist(
                        data: data, fileName: url.lastPathComponent, fileURI: url.absoluteString
                    )
                    let unmatched = importResult.unmatched.count
                    if unmatched > 0 {
                        model.showToast(.success("Imported \(importResult.matchedCount) tracks (\(unmatched) not in library yet)", systemImage: "music.note.list"))
                    } else {
                        model.showToast(.success("Imported \(importResult.playlist.name)", systemImage: "music.note.list"))
                    }
                } catch {
                    model.showError(error)
                }
            }
        }
    }
}

/// Row in the playlists list.
struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtwork(artworkKey: playlist.artworkKey, isSmart: playlist.isSmart)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)
                if !playlist.notes.isEmpty {
                    Text(playlist.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if playlist.isSmart {
                Spacer()
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(MuurTheme.accentViolet)
                    .accessibilityLabel("Smart playlist")
            }
        }
    }
}

/// Playlist artwork: stored image, or a themed icon.
struct PlaylistArtwork: View {
    let artworkKey: String?
    var isSmart: Bool = false

    var body: some View {
        if let artworkKey, !artworkKey.isEmpty {
            ArtworkImage(artworkKey: artworkKey, cornerRadius: 8, size: 200)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MuurTheme.accentViolet.opacity(0.15))
                Image(systemName: isSmart ? "wand.and.stars" : "music.note.list")
                    .foregroundStyle(MuurTheme.accentViolet)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A temporary file ready to share/export.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL

    static func write(data: Data, fileName: String) throws -> SharedFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muur-export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return SharedFile(url: url)
    }
}

/// Cross-platform share sheet for a file URL.
struct MuurShareSheet: View {
    let file: SharedFile

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.largeTitle)
                .foregroundStyle(MuurTheme.accentAmber)
            Text(file.url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
            ShareLink(item: file.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        #if os(macOS)
        .frame(width: 320)
        #endif
        .presentationDetents([.height(220)])
    }
}
