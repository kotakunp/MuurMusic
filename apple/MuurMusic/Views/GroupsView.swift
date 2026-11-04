import SwiftUI
import MuurCore
import MuurAudio

/// List of artists / album artists / genres / composers.
struct GroupListView: View {
    @EnvironmentObject var model: AppModel

    let kind: LibraryGroup.Kind

    @State private var groups: [LibraryGroup] = []
    @State private var isLoaded = false

    private var title: String {
        switch kind {
        case .artist: return "Artists"
        case .albumArtist: return "Album Artists"
        case .genre: return "Genres"
        case .composer: return "Composers"
        }
    }

    var body: some View {
        Group {
            if !isLoaded {
                LoadingView()
            } else if groups.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No \(title.lowercased()) yet",
                    message: "They appear once your library has tagged music."
                )
            } else {
                List(groups) { group in
                    NavigationLink(value: group) {
                        HStack(spacing: 12) {
                            ArtworkImage(artworkKey: group.artworkKey, cornerRadius: 6, size: 120)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName)
                                    .font(.body)
                                    .lineLimit(1)
                                Text("\(group.trackCount) songs • \(group.albumCount) albums")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .muurScreen()
        .navigationTitle(title)
        .navigationDestination(for: LibraryGroup.self) { group in
            GroupDetailView(group: group)
        }
        .task(id: kind) { await observe() }
    }

    private func observe() async {
        isLoaded = false
        do {
            for try await value in model.environment.repository.observeGroups(kind: kind) {
                groups = value
                isLoaded = true
            }
        } catch {
            isLoaded = true
        }
    }
}

extension LibraryGroup.Kind {
    var albumFilter: (String) -> AlbumFilter {
        switch self {
        case .artist: return { .artist($0) }
        case .albumArtist: return { .albumArtist($0) }
        case .genre: return { .genre($0) }
        case .composer: return { .composer($0) }
        }
    }
}

/// Detail page for an artist/genre/composer: their albums plus all tracks.
struct GroupDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let group: LibraryGroup

    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var sheetRequest: TrackSheetRequest?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    ArtworkImage(artworkKey: group.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 400)
                        .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.displayName)
                            .font(.title3.weight(.bold))
                        Text("\(group.trackCount) songs • \(group.albumCount) albums • \(MuurFormat.longDuration(group.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PlayShuffleButtons(play: { model.play(tracks) }, shuffle: { model.play(tracks, shuffle: true) })
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)

                if !albums.isEmpty {
                    Text("Albums")
                        .font(.headline)
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Text("Songs")
                    .font(.headline)
                    .padding(.horizontal, 16)
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                        TrackRowView(track: track)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .onTapGesture {
                                model.play(tracks, startIndex: index)
                            }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .muurScreen()
        .navigationTitle(group.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .sheet(item: $sheetRequest) { request in
            TrackSheetHost(request: request)
        }
        .task(id: group.id) { await observe() }
    }

    private func observe() async {
        let repository = model.environment.repository
        let name = group.name
        let albumFilter = group.kind.albumFilter(name)
        async let albumStream: Void = observeAlbums(repository: repository, filter: albumFilter)
        async let trackStream: Void = observeTracks(repository: repository, name: name)
        _ = await (albumStream, trackStream)
    }

    private func observeAlbums(repository: LibraryRepository, filter: AlbumFilter) async {
        do {
            for try await value in repository.observeAlbums(filter: filter) {
                albums = value
            }
        } catch {}
    }

    private func observeTracks(repository: LibraryRepository, name: String) async {
        do {
            for try await value in repository.observeTracks(filter: .group(group.kind, name)) {
                tracks = value
            }
        } catch {}
    }
}
