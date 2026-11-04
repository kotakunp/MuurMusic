import SwiftUI
import MuurCore
import MuurAudio

#if os(iOS)
/// iOS Library tab: every library section, then recently added albums.
struct LibraryHomeView: View {
    @EnvironmentObject var model: AppModel

    @State private var recentAlbums: [Album] = []

    private static let sections: [AppSection] = [
        .playlists, .artists, .albums, .songs, .genres, .albumArtists, .composers,
        .folders, .favorites, .downloads, .history, .sources, .files,
    ]

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        List {
            Section {
                ForEach(Self.sections) { section in
                    NavigationLink(value: section) {
                        Label {
                            Text(section.title)
                                .font(.title3)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowSeparator(section == Self.sections.first ? .hidden : .automatic, edges: .top)
                }
            }

            if !recentAlbums.isEmpty {
                Text("Recently Added")
                    .font(.title2.bold())
                    .padding(.top, 20)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                // Buttons rather than NavigationLinks: links inside a List row get disclosure chevrons.
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(recentAlbums) { album in
                        Button {
                            model.homePath.append(album)
                        } label: {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 24, trailing: 20))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .muurTopLevelTitle()
        .navigationDestination(for: AppSection.self) { section in
            RootSectionDestination(section: section)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ScanStatusLabel()
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppSection.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task { await observeRecent() }
    }

    private func observeRecent() async {
        do {
            for try await value in model.environment.repository.observeAlbums(filter: .all, sort: .dateAdded) {
                recentAlbums = Array(value.prefix(10))
            }
        } catch {
            recentAlbums = []
        }
    }
}
#endif
