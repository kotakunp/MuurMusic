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
    /// Custom swipe actions replace a List's built-in delete, so editable lists pass their removal here.
    var onRemove: (() -> Void)? = nil

    @State private var sheetRequest: TrackSheetRequest?

    var body: some View {
        HStack(spacing: 12) {
            if let index {
                ZStack {
                    if isCurrent {
                        NowPlayingIndicator()
                    } else {
                        Text("\(index)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24)
            }
            if showsArtwork {
                ArtworkImage(artworkKey: track.artworkKey, cornerRadius: MuurTheme.radiusRow, size: 120)
                    .frame(width: 46, height: 46)
                    .overlay {
                        if isCurrent && index == nil {
                            RoundedRectangle(cornerRadius: MuurTheme.radiusRow, style: .continuous)
                                .fill(.black.opacity(0.4))
                            NowPlayingIndicator()
                                .foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                let subtitle = subtitleOverride ?? defaultSubtitle
                let showsHeart = showsFavorite && track.favorite
                if !subtitle.isEmpty || showsHeart || (track.isHiRes && model.settings.showHiResBadges) {
                    HStack(spacing: 5) {
                        if showsHeart {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Favorite")
                        }
                        FormatBadge(track: track)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                TrackContextMenu(tracks: [track], sheet: $sheetRequest)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu { TrackContextMenu(tracks: [track], sheet: $sheetRequest) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.playNext([track])
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "minus.circle")
                }
                .tint(MuurTheme.danger)
            }
            Button {
                model.toggleFavorite(track)
            } label: {
                Label(track.favorite ? "Unfavorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart.fill")
            }
            .tint(.pink)
        }
        .sheet(item: $sheetRequest) { request in
            TrackSheetHost(request: request)
        }
    }

    private var isCurrent: Bool {
        player.currentTrack?.libraryKey == track.libraryKey
    }

    private var defaultSubtitle: String {
        "\(track.displayArtist) · \(track.displayAlbum)"
    }
}

/// Animated bars marking the row of the track that is playing.
struct NowPlayingIndicator: View {
    @EnvironmentObject var player: PlaybackController

    var body: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: player.isPlaying)
            .accessibilityLabel("Now playing")
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
