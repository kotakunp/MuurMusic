import SwiftUI
import MuurCore
import MuurAudio

/// Browse the library by folder structure.
struct FoldersView: View {
    var body: some View {
        FolderLevelView(path: "")
            .navigationDestination(for: String.self) { path in
                FolderLevelView(path: path)
            }
    }
}

/// One level of the folder tree: subfolders and the tracks directly inside.
struct FolderLevelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let path: String

    @State private var folders: [LibraryFolder] = []
    @State private var tracks: [Track] = []
    @State private var isLoaded = false

    private var title: String {
        path.isEmpty ? "Folders" : (path.split(separator: "/").last.map(String.init) ?? path)
    }

    var body: some View {
        Group {
            if !isLoaded {
                LoadingView()
            } else if folders.isEmpty && tracks.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "Nothing here",
                    message: "This folder has no music. Add folders in Settings → Library."
                )
            } else {
                List {
                    if !tracks.isEmpty || !folders.isEmpty {
                        Section {
                            Button {
                                playAll()
                            } label: {
                                Label("Play All (including subfolders)", systemImage: "play.fill")
                            }
                        }
                    }
                    if !folders.isEmpty {
                        Section("Folders") {
                            ForEach(folders) { folder in
                                NavigationLink(value: folder.path) {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder.name)
                                                .lineLimit(1)
                                            Text("\(folder.trackCount) songs")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(MuurTheme.accentAmber)
                                    }
                                }
                            }
                        }
                    }
                    if !tracks.isEmpty {
                        Section("Songs") {
                            ForEach(Array(tracks.enumerated()), id: \.element.stableID) { index, track in
                                TrackRowView(track: track)
                                    .onTapGesture {
                                        model.play(tracks, startIndex: index)
                                    }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
        .muurScreen()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(path.isEmpty ? .automatic : .inline)
        #endif
        .task(id: path) { await observe() }
    }

    private func playAll() {
        Task {
            do {
                let all = try await model.environment.database.read { db in
                    try LibraryQueries.tracks(db, filter: .folder(path, recursive: true))
                }
                model.play(all)
            } catch {
                model.showError(error)
            }
        }
    }

    private func observe() async {
        isLoaded = false
        let repository = model.environment.repository
        async let folderStream: Void = observeFolders(repository: repository)
        async let trackStream: Void = observeTracks(repository: repository)
        _ = await (folderStream, trackStream)
    }

    private func observeFolders(repository: LibraryRepository) async {
        do {
            for try await value in repository.observeFolders(parent: path) {
                folders = value
                isLoaded = true
            }
        } catch {
            isLoaded = true
        }
    }

    private func observeTracks(repository: LibraryRepository) async {
        do {
            for try await value in repository.observeTracks(filter: .folder(path, recursive: false)) {
                tracks = value
            }
        } catch {}
    }
}
