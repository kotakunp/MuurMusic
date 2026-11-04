import SwiftUI
import MuurCore
import MuurAudio

/// Browse the contents of a configured source (folders, files, archives).
struct SourceBrowserView: View {
    @EnvironmentObject var model: AppModel

    let config: SourceConfig

    @State private var source: (any MusicSource)?
    @State private var connectError: String?

    var body: some View {
        Group {
            if let source {
                SourceItemList(source: source, container: nil)
            } else if let connectError {
                EmptyStateView(
                    illustration: .offline,
                    title: "Cannot connect",
                    message: connectError,
                    actionTitle: "Try Again",
                    action: { connect() }
                )
            } else {
                LoadingView(message: "Connecting to \(config.name)…")
            }
        }
        .muurScreen()
        .navigationTitle(config.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: SourceItem.self) { item in
            if item.kind == .archive {
                ArchiveLevelView(archive: item, parent: source)
            } else if let source {
                SourceItemList(source: source, container: item)
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

/// A list of items in one container of a source.
struct SourceItemList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let source: any MusicSource
    let container: SourceItem?

    @State private var items: [SourceItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText = ""
    @State private var searchResults: [SourceItem]?
    @State private var isCollecting = false

    private var displayed: [SourceItem] {
        let list = searchResults ?? items
        return list.sorted { lhs, rhs in
            if lhs.isContainer != rhs.isContainer { return lhs.isContainer && !rhs.isContainer }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let error {
                EmptyStateView(
                    illustration: .offline,
                    title: "Could not load",
                    message: error,
                    actionTitle: "Retry",
                    action: { load() }
                )
            } else if displayed.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "Empty",
                    message: "Nothing in this folder."
                )
            } else {
                List(displayed) { item in
                    row(for: item)
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .searchable(if: source.capabilities.contains(.search), text: $searchText, prompt: "Search this source")
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, text in
            if text.isEmpty { searchResults = nil }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    playAll()
                } label: {
                    Image(systemName: "play.circle")
                }
                .disabled(isCollecting)
                .accessibilityLabel("Play all audio here")
            }
        }
        .task(id: container?.uri) { load() }
    }

    @ViewBuilder
    private func row(for item: SourceItem) -> some View {
        let label = SourceItemRow(item: item)
        if item.kind == .folder || item.kind == .archive {
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
            Button { play(item) } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button { enqueue(item, next: true) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { enqueue(item, next: false) } label: {
                Label("Play Later", systemImage: "text.append")
            }
        }
        if item.isPlayable || item.kind == .folder {
            Button { addToLibrary(item) } label: {
                Label("Add to Library", systemImage: "plus.rectangle.on.rectangle")
            }
        }
        if item.isPlayable {
            Button { download(item) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        if source.capabilities.contains(.delete) {
            Divider()
            Button(role: .destructive) { deleteItem(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func play(_ item: SourceItem) {
        let audioItems = displayed.filter(\.isPlayable)
        guard let index = audioItems.firstIndex(of: item) else { return }
        let tracks = audioItems.map { source.makeTrack(for: $0) }
        model.play(tracks, startIndex: index)
    }

    private func playAll() {
        isCollecting = true
        Task {
            do {
                let audio = try await source.collectAudio(under: container)
                let tracks = audio.map { source.makeTrack(for: $0) }
                model.play(tracks)
            } catch {
                model.showError(error)
            }
            isCollecting = false
        }
    }

    private func enqueue(_ item: SourceItem, next: Bool) {
        let track = source.makeTrack(for: item)
        next ? model.playNext([track]) : model.playLater([track])
    }

    private func download(_ item: SourceItem) {
        model.download([source.makeTrack(for: item)])
    }

    private func addToLibrary(_ item: SourceItem) {
        Task {
            do {
                let tracks = try await model.environment.sources.addToLibrary([item], from: source)
                model.showToast(.success("Added \(tracks.count) track(s) to the library", systemImage: "plus.rectangle.on.rectangle"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func deleteItem(_ item: SourceItem) {
        Task {
            do {
                try await source.delete(item)
                load()
            } catch {
                model.showError(error)
            }
        }
    }

    private func performSearch() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { searchResults = nil; return }
        isLoading = true
        Task {
            do {
                searchResults = try await source.search(text)
            } catch {
                model.showError(error)
                searchResults = nil
            }
            isLoading = false
        }
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

/// Row for a source item.
struct SourceItemRow: View {
    let item: SourceItem

    var body: some View {
        HStack(spacing: 12) {
            if let artworkURL = item.artworkURL {
                RemoteArtworkImage(url: artworkURL, headers: item.artworkHeaders, cornerRadius: 6)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .playlist: return "music.note.list"
        case .archive: return "doc.zipper"
        case .image: return "photo"
        case .lyrics: return "text.quote"
        case .other: return "doc"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .folder: return MuurTheme.accentAmber
        case .audio: return MuurTheme.accentViolet
        case .archive: return MuurTheme.success
        default: return .secondary
        }
    }

    private var subtitle: String {
        if let custom = item.subtitle, !custom.isEmpty { return custom }
        var parts: [String] = []
        if let size = item.size { parts.append(MuurFormat.bytes(size)) }
        if let count = item.childCount { parts.append("\(count) items") }
        if let modified = item.modified { parts.append(MuurFormat.relative(modified)) }
        return parts.joined(separator: " • ")
    }
}

/// Drills into a ZIP archive as if it were a folder.
struct ArchiveLevelView: View {
    @EnvironmentObject var model: AppModel

    let archive: SourceItem
    let parent: (any MusicSource)?

    @State private var archiveSource: (any MusicSource)?
    @State private var error: String?

    var body: some View {
        Group {
            if let archiveSource {
                SourceItemList(source: archiveSource, container: nil)
            } else if let error {
                EmptyStateView(illustration: .offline, title: "Cannot open archive", message: error)
            } else {
                LoadingView(message: "Opening archive…")
            }
        }
        .muurScreen()
        .navigationTitle(archive.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { openArchive() }
    }

    private func openArchive() {
        Task {
            do {
                archiveSource = try await model.environment.sources.archiveSource(for: archive, in: parent)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Applies `.searchable` only when the condition holds (capability-gated search).
    @ViewBuilder
    func searchable(if condition: Bool, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        if condition {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}
