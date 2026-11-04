import SwiftUI
import MuurCore
import MuurAudio

/// Listening history: recently played, recently added, most played and the play log.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    enum Mode: String, CaseIterable, Identifiable {
        case recentlyPlayed = "Recently Played"
        case recentlyAdded = "Recently Added"
        case mostPlayed = "Most Played"
        case log = "Play Log"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .recentlyPlayed
    @State private var tracks: [Track] = []
    @State private var entries: [PlayHistoryEntry] = []
    @State private var isLoaded = false

    var body: some View {
        content
        .navigationTitle(mode.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Choose history view")
            }
        }
        .task(id: mode) { await observe() }
    }

    @ViewBuilder
    private var content: some View {
        if !isLoaded {
            LoadingView()
        } else if mode == .log {
            logList
        } else if tracks.isEmpty {
            EmptyStateView(
                illustration: .library,
                title: "Quiet in here",
                message: "Play some music and the cat will keep notes."
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

    private var logList: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No history yet",
                    message: "Your play log appears here."
                )
            } else {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? entry.sourceURI : entry.title)
                                .lineLimit(1)
                            Text(entry.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MuurFormat.relative(entry.playedAt))
                            Text("\(MuurFormat.duration(entry.listenedSeconds)) listened")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
    }

    private func observe() async {
        isLoaded = false
        let repository = model.environment.repository
        do {
            switch mode {
            case .recentlyPlayed:
                for try await value in repository.observeRecentlyPlayed(limit: 100) {
                    tracks = value
                    isLoaded = true
                }
            case .recentlyAdded:
                for try await value in repository.observeTracks(sort: TrackSort(field: .dateAdded, ascending: false), limit: 100) {
                    tracks = value
                    isLoaded = true
                }
            case .mostPlayed:
                for try await value in repository.observeTracks(sort: TrackSort(field: .playCount, ascending: false), limit: 100) {
                    tracks = value.filter { $0.playCount > 0 }
                    isLoaded = true
                }
            case .log:
                for try await value in repository.observeHistory(limit: 300) {
                    entries = value
                    isLoaded = true
                }
            }
        } catch {
            isLoaded = true
        }
    }
}
