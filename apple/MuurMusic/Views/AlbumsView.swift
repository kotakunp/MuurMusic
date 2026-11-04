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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)]

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
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            ArtworkImage(artworkKey: album.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 400)
                .overlay {
                    RoundedRectangle(cornerRadius: MuurTheme.radiusCard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .padding(.bottom, 7)
            HStack(spacing: 4) {
                Text(album.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if album.isHiRes {
                    Image(systemName: "hifispeaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hi-Res")
                }
            }
            Text(album.displayArtist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Album detail: centered artwork header with Play / Shuffle, then the numbered track list.
struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let album: Album

    @State private var tracks: [Track] = []
    @State private var sheetRequest: TrackSheetRequest?

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

            ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                TrackRowView(
                    track: track,
                    showsArtwork: false,
                    subtitleOverride: track.displayArtist == album.displayArtist ? "" : track.displayArtist,
                    index: track.trackNumber ?? index + 1
                )
                .onTapGesture {
                    model.play(tracks, startIndex: index)
                }
            }

            if !tracks.isEmpty {
                Text(footerLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    TrackContextMenu(tracks: tracks, sheet: $sheetRequest)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Album actions")
            }
        }
        .sheet(item: $sheetRequest) { request in
            TrackSheetHost(request: request)
        }
        .task(id: album.id) { await observe() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            ArtworkImage(artworkKey: album.artworkKey, cornerRadius: MuurTheme.radiusArtwork, size: 800)
                .frame(maxWidth: 280)
                .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text(album.displayTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(album.displayArtist)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.center)
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            PlayShuffleButtons(play: { model.play(tracks) }, shuffle: { model.play(tracks, shuffle: true) })
                .disabled(tracks.isEmpty)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    /// "ROCK · 2021 · FLAC 24/96"
    private var metaLine: String {
        var parts: [String] = []
        if !album.genre.isEmpty { parts.append(album.genre.uppercased()) }
        if let year = album.year { parts.append(String(year)) }
        if !album.codec.isEmpty {
            parts.append(album.isHiRes ? "\(album.codec.uppercased()) HI-RES" : album.codec.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private var footerLine: String {
        let songs = "\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs"), \(MuurFormat.longDuration(album.duration))"
        if let year = album.year {
            return "\(year)\n\(songs)"
        }
        return songs
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
