import SwiftUI
import MuurCore

/// macOS sidebar: library sections, playlists, sources and settings.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: AppSection?

    private let librarySections: [AppSection] = [.songs, .albums, .artists, .albumArtists, .genres, .composers, .folders]

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(librarySections) { section in
                    sidebarRow(section)
                }
            }
            Section("Playlists") {
                sidebarRow(.playlists)
                sidebarRow(.favorites)
                sidebarRow(.history)
            }
            Section("Library Sources") {
                sidebarRow(.sources)
                sidebarRow(.files)
                sidebarRow(.downloads)
            }
            Section {
                sidebarRow(.search)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.isScanning {
                    HStack(spacing: 8) {
                        PawProgressView(pawSize: 12)
                        Text(model.scanProgress.folderName.isEmpty ? "Scanning…" : "Scanning \(model.scanProgress.folderName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                }
                Divider()
                Button {
                    selection = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }
}
