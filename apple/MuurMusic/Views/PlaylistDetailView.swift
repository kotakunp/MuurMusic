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

    var body: some View {
        Group {
            if let playlist {
                content(playlist)
            } else {
                LoadingView()
            }
        }
        .muurScreen()
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
                    #if os(iOS)
                    EditButton()
                    #else
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                    #endif
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
                VStack(spacing: 12) {
                    PlaylistCollage(tracks: tracks)
                        .frame(width: 150, height: 150)
                    Text(playlist.name)
                        .font(.title3.weight(.bold))
                    Text("\(tracks.count) songs • \(MuurFormat.longDuration(tracks.reduce(0) { $0 + $1.duration }))")
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
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowSeparator(.hidden)

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                    TrackRowView(track: track)
                        .onTapGesture {
                            model.play(tracks, startIndex: index)
                        }
                }
                .onMove(perform: playlist.isSmart ? nil : move)
                .onDelete(perform: playlist.isSmart ? nil : delete)
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .environment(\.editMode, $editMode)
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
