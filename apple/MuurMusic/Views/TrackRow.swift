import SwiftUI
import MuurCore
import MuurAudio

/// Identifies which track-related sheet is open.
struct TrackSheetRequest: Identifiable {
    enum Kind {
        case playlistPicker
        case tagEditor
        case musicBrainz
    }

    let id = UUID()
    let kind: Kind
    let tracks: [Track]
}

/// Hosts the track sheets so every list row gets them for free.
struct TrackSheetHost: View {
    let request: TrackSheetRequest

    var body: some View {
        switch request.kind {
        case .playlistPicker:
            PlaylistPickerSheet(tracks: request.tracks)
        case .tagEditor:
            TagEditorView(tracks: request.tracks)
        case .musicBrainz:
            MusicBrainzLookupView(track: request.tracks.first)
        }
    }
}

/// A single track row: artwork, title, badges, subtitle, duration.
/// Adds the standard context menu, swipe actions and sheets.
struct TrackRowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let track: Track
    var showsArtwork = true
    var subtitleOverride: String? = nil
    var showsFavorite = true
    var index: Int? = nil

    @State private var sheetRequest: TrackSheetRequest?

    var body: some View {
        HStack(spacing: 10) {
            if let index {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            if showsArtwork {
                ArtworkImage(artworkKey: track.artworkKey, cornerRadius: 6, size: 120)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color(hex: model.settings.accent.hex) : .primary)
                    FormatBadge(track: track)
                    if showsFavorite && track.favorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(MuurTheme.accentAmber)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(subtitleOverride ?? defaultSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(MuurFormat.duration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { TrackContextMenu(tracks: [track], sheet: $sheetRequest) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.playNext([track])
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(MuurTheme.accentViolet)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                model.toggleFavorite(track)
            } label: {
                Label(track.favorite ? "Unfavorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart.fill")
            }
            .tint(MuurTheme.accentAmber)
        }
        .sheet(item: $sheetRequest) { request in
            TrackSheetHost(request: request)
        }
    }

    private var isCurrent: Bool {
        player.currentTrack?.libraryKey == track.libraryKey
    }

    private var defaultSubtitle: String {
        "\(track.displayArtist) — \(track.displayAlbum)"
    }
}

/// Standard context menu for one or more tracks.
struct TrackContextMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let tracks: [Track]
    @Binding var sheet: TrackSheetRequest?

    private var single: Track? { tracks.count == 1 ? tracks.first : nil }

    var body: some View {
        Button {
            model.play(tracks)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            model.playNext(tracks)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            model.playLater(tracks)
        } label: {
            Label("Play Later", systemImage: "text.append")
        }

        Divider()

        Button {
            sheet = TrackSheetRequest(kind: .playlistPicker, tracks: tracks)
        } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }

        if let track = single {
            Button {
                model.toggleFavorite(track)
            } label: {
                Label(track.favorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: track.favorite ? "heart.slash" : "heart")
            }
            Menu {
                ForEach(0...5, id: \.self) { value in
                    Button {
                        model.setRating(value, for: track)
                    } label: {
                        if value == 0 {
                            Text("No Rating")
                        } else {
                            Label("\(value) Star\(value == 1 ? "" : "s")", systemImage: "star.fill")
                        }
                    }
                }
            } label: {
                Label("Rating", systemImage: "star")
            }

            if player.currentTrack?.libraryKey == track.libraryKey {
                Button {
                    addBookmark(for: track)
                } label: {
                    Label("Add Bookmark at \(MuurFormat.duration(player.position))", systemImage: "bookmark.fill")
                }
            }
        }

        Divider()

        Button {
            sheet = TrackSheetRequest(kind: .tagEditor, tracks: tracks)
        } label: {
            Label(tracks.count > 1 ? "Edit \(tracks.count) Tracks…" : "Edit Tags…", systemImage: "tag")
        }
        if model.settings.autoTagOnline, let track = single {
            Button {
                sheet = TrackSheetRequest(kind: .musicBrainz, tracks: [track])
            } label: {
                Label("Look Up Tags Online…", systemImage: "globe")
            }
        }

        Divider()

        if tracks.contains(where: { !$0.isLocal }) {
            Button {
                model.download(tracks)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        if let track = single, track.isLocal, let url = URL(string: track.sourceURI) {
            ShareLink(item: url) {
                Label("Share File…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func addBookmark(for track: Track) {
        let position = player.position
        Task {
            do {
                _ = try await model.environment.repository.addBookmark(track: track, position: position)
                model.showToast(.success("Bookmark added", systemImage: "bookmark.fill"))
            } catch {
                model.showError(error)
            }
        }
    }
}
