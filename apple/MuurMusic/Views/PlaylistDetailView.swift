import SwiftUI
import MuurCore
import MuurAudio

/// Playlist detail: collage header, draggable track list, smart rule editing, export.
struct PlaylistDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let playlistID: Int64

    @State private var loaded: PlaylistWithTracks?
    @State private var isEditingSmart = false
    @State private var editMode: EditMode = .inactive

    private var playlist: Playlist? { loaded?.playlist }
    private var tracks: [Track] { loaded?.tracks ?? [] }

    #if os(iOS)
    private let editLabel = "Edit"
    #else
    private let editLabel = "Reorder"
    #endif

    var body: some View {
        Group {
            if let playlist {
                content(playlist)
            } else {
                LoadingView()
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let playlist, playlist.isSmart {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isEditingSmart = true
                    } label: {
                        Label("Edit Rules", systemImage: "wand.and.stars")
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    // Not EditButton: it drives the toolbar's edit mode, not the List's `editMode` binding.
                    Button(editMode.isEditing ? "Done" : editLabel) {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
        .sheet(isPresented: $isEditingSmart) {
            if let playlist, let definition = playlist.smartDefinition {
                SmartPlaylistEditorView(playlistID: playlistID, definition: definition)
            }
        }
        .task(id: playlistID) { await observe() }
    }

    @ViewBuilder
    private func content(_ playlist: Playlist) -> some View {
        List {
            Section {
                VStack(spacing: 16) {
                    PlaylistCollage(tracks: tracks)
                        .frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                    VStack(spacing: 4) {
                        Text(playlist.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if !playlist.notes.isEmpty {
                            Text(playlist.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Text(playlistSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    PlayShuffleButtons(play: { model.play(tracks) }, shuffle: { model.play(tracks, shuffle: true) })
                        .disabled(tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                    TrackRowView(track: track, onRemove: playlist.isSmart ? nil : { delete(at: IndexSet(integer: index)) })
                        .onTapGesture {
                            model.play(tracks, startIndex: index)
                        }
                }
                .onMove(perform: playlist.isSmart ? nil : move)
                .onDelete(perform: playlist.isSmart ? nil : delete)
            }
        }
        .listStyle(.plain)
        .muurEditMode($editMode)
    }

    private var playlistSummary: String {
        let songs = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let duration = MuurFormat.longDuration(tracks.reduce(0) { $0 + $1.duration })
        let kind = playlist?.isSmart == true ? "SMART PLAYLIST · " : ""
        return "\(kind)\(songs.uppercased()) · \(duration.uppercased())"
    }

    private func move(from source: IndexSet, to destination: Int) {
        Task {
            do {
                try await model.environment.playlists.move(in: playlistID, fromOffsets: source, toOffset: destination)
            } catch {
                model.showError(error)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        Task {
            do {
                try await model.environment.playlists.remove(atOffsets: offsets, from: playlistID)
            } catch {
                model.showError(error)
            }
        }
    }

    private func observe() async {
        do {
            for try await value in model.environment.playlists.observeContents(of: playlistID) {
                loaded = value
            }
        } catch {}
    }
}

/// 2x2 collage of the first few track artworks.
struct PlaylistCollage: View {
    let tracks: [Track]

    private var keys: [String] {
        var seen: [String] = []
        for track in tracks {
            if let key = track.artworkKey, !key.isEmpty, !seen.contains(key) {
                seen.append(key)
            }
            if seen.count == 4 { break }
        }
        return seen
    }

    var body: some View {
        if keys.isEmpty {
            PlaylistArtwork(artworkKey: nil)
        } else if keys.count == 1 {
            ArtworkImage(artworkKey: keys[0], cornerRadius: MuurTheme.radiusCard, size: 400)
        } else {
            let padded = keys + Array(repeating: keys[0], count: max(0, 4 - keys.count))
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    cell(padded[0])
                    cell(padded[1])
                }
                GridRow {
                    cell(padded[2])
                    cell(padded[3])
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MuurTheme.radiusCard, style: .continuous))
        }
    }

    private func cell(_ key: String) -> some View {
        ArtworkImage(artworkKey: key, cornerRadius: 2, size: 200)
            .aspectRatio(1, contentMode: .fit)
    }
}
