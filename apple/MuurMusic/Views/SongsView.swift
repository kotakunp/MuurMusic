import SwiftUI
import MuurCore
import MuurAudio

/// All songs in the library with sorting, shuffle play and pull-to-rescan.
struct SongsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    var filter: TrackFilter = .all
    var title: String = "Songs"
    var allowSort = true

    @State private var sort = TrackSort()
    @State private var tracks: [Track] = []
    @State private var isLoaded = false

    private var countLine: String {
        let songs = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        return "\(songs), \(MuurFormat.longDuration(tracks.reduce(0) { $0 + $1.duration }))"
    }

    private var sortKey: String {
        "\(sort.field.rawValue)-\(sort.ascending)"
    }

    var body: some View {
        Group {
            if !isLoaded {
                LoadingView()
            } else if tracks.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "No music yet",
                    message: "Import songs, send them over Wi-Fi, or connect a server and the cat will fetch them.",
                    actionTitle: "Add Songs",
                    action: { model.showAddSongs() }
                )
            } else {
                List {
                    if model.isScanning {
                        ScanStatusLabel()
                            .listRowSeparator(.hidden)
                    }
                    PlayShuffleButtons(play: { model.play(tracks) }, shuffle: { model.play(tracks, shuffle: true) })
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
                    ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                        TrackRowView(track: track)
                            .onTapGesture {
                                model.play(tracks, startIndex: index)
                            }
                    }
                    Text(countLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 16)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if allowSort {
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
            }
        }
        .task(id: sortKey) {
            await observe()
        }
        #if os(iOS)
        .refreshable {
            model.environment.scanner.scanAll()
            await model.environment.scanner.waitUntilIdle()
        }
        #endif
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TrackSortField.allCases, id: \.self) { field in
                Button {
                    if sort.field == field {
                        sort.ascending.toggle()
                    } else {
                        sort = TrackSort(field: field, ascending: true)
                    }
                } label: {
                    if sort.field == field {
                        Label(field.displayName, systemImage: sort.ascending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(field.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort songs")
    }

    private func observe() async {
        isLoaded = false
        do {
            for try await value in model.environment.repository.observeTracks(filter: filter, sort: sort) {
                tracks = value
                isLoaded = true
            }
        } catch {
            isLoaded = true
        }
    }
}
