import SwiftUI
import MuurCore
import MuurAudio

/// Favorite tracks.
struct FavoritesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    @State private var tracks: [Track] = []
    @State private var isLoaded = false

    var body: some View {
        Group {
            if !isLoaded {
                LoadingView()
            } else if tracks.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No favorites yet",
                    message: "Tap the heart on any song and it curls up here. The cat approves."
                )
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                        TrackRowView(track: track)
                            .onTapGesture {
                                model.play(tracks, startIndex: index)
                            }
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .muurScreen()
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.play(tracks, shuffle: true)
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(tracks.isEmpty)
                .accessibilityLabel("Shuffle favorites")
            }
        }
        .task { await observe() }
    }

    private func observe() async {
        do {
            for try await value in model.environment.repository.observeTracks(filter: .favorites, sort: TrackSort(field: .dateAdded, ascending: false)) {
                tracks = value
                isLoaded = true
            }
        } catch {
            isLoaded = true
        }
    }
}
