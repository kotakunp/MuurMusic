import SwiftUI
import MuurCore
import MuurAudio

/// Library-wide search with recent searches and grouped results.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    @State private var query = ""
    @State private var results: LibrarySearchResults?
    @State private var isSearching = false

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                recentSearches
            } else if isSearching && results == nil {
                LoadingView(message: "Sniffing out \(query)…")
            } else if let results, !results.isEmpty {
                resultList(results)
            } else if results != nil {
                EmptyStateView(
                    illustration: .search,
                    title: "No matches",
                    message: "The cat found nothing for “\(query)”. Try fewer words."
                )
            } else {
                LoadingView()
            }
        }
        .muurScreen()
        .navigationTitle("Search")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: LibraryGroup.self) { group in
            GroupDetailView(group: group)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            if let id = playlist.id {
                PlaylistDetailView(playlistID: id)
            }
        }
        .searchable(text: $query, placement: .automatic, prompt: "Songs, albums, artists…")
        .onSubmit(of: .search) {
            model.recordSearch(query)
        }
        .task(id: query) { await search() }
    }

    private var recentSearches: some View {
        List {
            if !model.recentSearches.isEmpty {
                Section("Recent") {
                    ForEach(model.recentSearches, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button(role: .destructive) {
                    model.clearRecentSearches()
                } label: {
                    Label("Clear Recent Searches", systemImage: "trash")
                }
            } else {
                Section {
                    VStack(spacing: 8) {
                        Image("EmptySearch")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 160, maxHeight: 120)
                        Text("Search your library")
                            .font(.headline)
                        Text("Songs, albums, artists and playlists — all in one place.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowSeparator(.hidden)
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    private func resultList(_ results: LibrarySearchResults) -> some View {
        List {
            if !results.tracks.isEmpty {
                Section("Songs") {
                    ForEach(Array(results.tracks.enumerated()), id: \.element.stableID) { index, track in
                        TrackRowView(track: track)
                            .onTapGesture {
                                model.play(results.tracks, startIndex: index)
                            }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkImage(artworkKey: album.artworkKey, cornerRadius: 8, size: 120)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.displayTitle).lineLimit(1)
                                    Text(album.displayArtist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { group in
                        NavigationLink(value: group) {
                            Label(group.displayName, systemImage: "person.fill")
                        }
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(results.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = nil
            return
        }
        isSearching = true
        // Small debounce so we don't hammer FTS on every keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            results = try await model.environment.repository.search(text, limit: 60)
        } catch {
            results = LibrarySearchResults()
        }
        isSearching = false
    }
}
