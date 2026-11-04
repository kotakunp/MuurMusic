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
                        HStack(spacing: 14) {
                            // People get round portraits, like Contacts and Music; genres stay square.
                            ArtworkImage(artworkKey: group.artworkKey, cornerRadius: isPerson ? 999 : MuurTheme.radiusRow, size: 160)
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(countLine(group))
                                    .font(.subheadline)
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
        .navigationTitle(title)
        .navigationDestination(for: LibraryGroup.self) { group in
            GroupDetailView(group: group)
        }
        .task(id: kind) { await observe() }
    }

    private var isPerson: Bool {
        kind != .genre
    }

    private func countLine(_ group: LibraryGroup) -> String {
        let albums = group.albumCount == 1 ? "1 album" : "\(group.albumCount) albums"
        let songs = group.trackCount == 1 ? "1 song" : "\(group.trackCount) songs"
        return "\(albums) · \(songs)"
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

/// Detail page for an artist/genre/composer: an artwork hero that fades into the page,
/// Play / Shuffle, an album shelf and the songs.
struct GroupDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let group: LibraryGroup

    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []

    private static let songPreviewCount = 12

    #if os(iOS)
    private let heroHeight: CGFloat = 400
    #else
    private let heroHeight: CGFloat = 300
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                PlayShuffleButtons(play: { model.play(tracks) }, shuffle: { model.play(tracks, shuffle: true) })
                    .disabled(tracks.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)

                if !albums.isEmpty {
                    sectionTitle("Albums")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(album: album)
                                        .frame(width: 160)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.bottom, 28)
                }

                if !tracks.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle("Songs")
                        Spacer()
                        if tracks.count > Self.songPreviewCount {
                            NavigationLink {
                                SongsView(filter: .group(group.kind, group.name), title: group.displayName)
                            } label: {
                                Text("See All")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 20)
                        }
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.prefix(Self.songPreviewCount).enumerated()), id: \.element.stableID) { index, track in
                            TrackRowView(track: track, subtitleOverride: track.displayAlbum)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                                .onTapGesture {
                                    model.play(tracks, startIndex: index)
                                }
                            if index < min(tracks.count, Self.songPreviewCount) - 1 {
                                Divider()
                                    .padding(.leading, 78)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The name is already on the hero; keep the bar clear over the artwork.
            ToolbarItem(placement: .principal) { Text("") }
        }
        #endif
        .navigationTitle(group.displayName)
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .task(id: group.id) { await observe() }
    }

    private var hero: some View {
        ArtworkImage(artworkKey: group.artworkKey, cornerRadius: 0, size: 1000)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: Color.muurBackground.opacity(0.85), location: 0.85),
                        .init(color: Color.muurBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayName)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(summaryLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
    }

    private var summaryLine: String {
        var parts: [String] = []
        switch group.kind {
        case .artist, .albumArtist: parts.append("Artist")
        case .genre: parts.append("Genre")
        case .composer: parts.append("Composer")
        }
        parts.append(group.albumCount == 1 ? "1 album" : "\(group.albumCount) albums")
        parts.append(MuurFormat.longDuration(group.duration))
        return parts.joined(separator: " · ")
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
