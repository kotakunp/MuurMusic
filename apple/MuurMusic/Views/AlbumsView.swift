import SwiftUI
import MuurCore
import MuurAudio

/// Album grid with sort options.
struct AlbumsView: View {
    @EnvironmentObject var model: AppModel

    var filter: AlbumFilter = .all

    @State private var sort: AlbumSort = .title
    @State private var albums: [Album] = []
    @State private var isLoaded = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if !isLoaded {
                LoadingView()
            } else if albums.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No albums yet",
                    message: "Albums appear here once your library has tagged music."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .muurScreen()
        .navigationTitle("Albums")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(AlbumSort.allCases, id: \.self) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort albums")
            }
        }
        .task(id: sort) { await observe() }
    }

    private func observe() async {
        isLoaded = false
        do {
            for try await value in model.environment.repository.observeAlbums(filter: filter, sort: sort) {
                albums = value
                isLoaded = true
            }
        } catch {
            isLoaded = true
        }
    }
}

/// A single album tile in the grid.
struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(artworkKey: album.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 400)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if album.isHiRes {
                        Text("HI-RES")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(MuurTheme.accentAmber, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                            .padding(6)
                    }
                }
            Text(album.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(album.displayArtist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Album detail: header with artwork and actions, then the track list.
struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let album: Album

    @State private var tracks: [Track] = []
    @State private var sheetRequest: TrackSheetRequest?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ArtworkImage(artworkKey: album.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 600)
                        .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.displayTitle)
                            .font(.title3.weight(.bold))
                        Text(album.displayArtist)
                            .foregroundStyle(.secondary)
                        Text(detailsLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                model.play(tracks)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                model.play(tracks, shuffle: true)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
            .listRowSeparator(.hidden)

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                    TrackRowView(track: track, showsArtwork: false, subtitleOverride: track.displayArtist, index: track.trackNumber ?? index + 1)
                        .onTapGesture {
                            model.play(tracks, startIndex: index)
                        }
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .muurScreen()
        .navigationTitle(album.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    TrackContextMenu(tracks: tracks, sheet: $sheetRequest)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $sheetRequest) { request in
            TrackSheetHost(request: request)
        }
        .task(id: album.id) { await observe() }
    }

    private var detailsLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.trackCount) songs")
        parts.append(MuurFormat.longDuration(album.duration))
        if !album.codec.isEmpty { parts.append(album.codec.uppercased()) }
        return parts.joined(separator: " • ")
    }

    private func observe() async {
        do {
            for try await value in model.environment.repository.observeTracks(
                filter: .album(title: album.title, artist: album.artist),
                sort: TrackSort(field: .trackNumber, ascending: true)
            ) {
                tracks = value
            }
        } catch {
            // Leave the last good value in place.
        }
    }
}
