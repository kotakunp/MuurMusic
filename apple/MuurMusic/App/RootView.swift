import SwiftUI
import MuurCore
import MuurAudio

/// The root of the app: a tab bar on iOS, a sidebar split view on macOS.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        content
            .tint(Color(hex: model.settings.accent.hex))
            .preferredColorScheme(preferredScheme)
            .onOpenURL { url in model.handleIncomingURL(url) }
            .muurToast($model.toast)
            .task {
                // Keep widget artwork pruned and warm the discovery list once.
                model.environment.discovery.start()
            }
    }

    private var preferredScheme: ColorScheme? {
        switch model.settings.theme {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        iOSRoot
        #else
        macRoot
        #endif
    }

    // MARK: iOS

    #if os(iOS)
    private var orderedTabs: [LibraryTab] {
        model.settings.tabOrder
    }

    private var visibleTabs: [LibraryTab] {
        Array(orderedTabs.prefix(4))
    }

    private var overflowTabs: [LibraryTab] {
        Array(orderedTabs.dropFirst(4))
    }

    private var iOSRoot: some View {
        TabView(selection: $model.tab) {
            ForEach(visibleTabs, id: \.self) { tab in
                // The inset goes on the stack, not the root view, so pushed screens keep the mini player.
                NavigationStack {
                    sectionView(AppSection(tab) ?? .songs)
                }
                .withMiniPlayer()
                .tabItem {
                    let section = AppSection(tab) ?? .songs
                    Label(section.title, systemImage: section.systemImage)
                }
                .tag(HomeTab.library(tab))
            }
            NavigationStack(path: $model.morePath) {
                MoreView(overflow: overflowTabs)
            }
            .withMiniPlayer()
            .tabItem { Label("More", systemImage: "ellipsis") }
            .tag(HomeTab.more)
        }
        .fullScreenCover(isPresented: $model.isShowingNowPlaying) {
            NowPlayingView()
                .environmentObject(model)
                .environmentObject(player)
        }
    }
    #endif

    // MARK: macOS

    #if os(macOS)
    private var macRoot: some View {
        NavigationSplitView {
            SidebarView(selection: $model.section)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            NavigationStack {
                sectionView(model.section ?? .songs)
            }
            .withMiniPlayer()
        }
        .frame(minWidth: 860, minHeight: 540)
        .onChange(of: model.nowPlayingWindowRequest) { _, _ in
            openWindow(id: MuurWindowID.nowPlaying.rawValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .muurOpenMiniPlayer)) { _ in
            openWindow(id: MuurWindowID.miniPlayer.rawValue)
        }
    }
    #endif

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .songs: SongsView()
        case .albums: AlbumsView()
        case .artists: GroupListView(kind: .artist)
        case .albumArtists: GroupListView(kind: .albumArtist)
        case .genres: GroupListView(kind: .genre)
        case .composers: GroupListView(kind: .composer)
        case .folders: FoldersView()
        case .playlists: PlaylistsView()
        case .sources: SourcesView()
        case .files: FilesView()
        case .downloads: DownloadsView()
        case .favorites: FavoritesView()
        case .history: HistoryView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    /// Attaches the mini player above the tab bar (iOS) or at the bottom of the detail column (macOS).
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView()
        }
    }
}

/// iOS "More" tab: remaining library sections plus Downloads, Favorites, History and Settings.
struct MoreView: View {
    @EnvironmentObject var model: AppModel
    let overflow: [LibraryTab]

    private var overflowSections: [AppSection] {
        overflow.compactMap(AppSection.init)
    }

    private var fixedSections: [AppSection] {
        [.downloads, .favorites, .history, .settings]
    }

    var body: some View {
        List {
            if !overflowSections.isEmpty {
                Section("Library") {
                    ForEach(overflowSections) { section in
                        NavigationLink(value: section) {
                            Label(section.title, systemImage: section.systemImage)
                        }
                    }
                }
            }
            Section {
                ForEach(fixedSections) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
        }
        .navigationTitle("MuurMusic")
        .navigationDestination(for: AppSection.self) { section in
            RootSectionDestination(section: section)
        }
    }
}

/// Pushed section destination (used by the iOS "More" list).
struct RootSectionDestination: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .songs: SongsView()
        case .albums: AlbumsView()
        case .artists: GroupListView(kind: .artist)
        case .albumArtists: GroupListView(kind: .albumArtist)
        case .genres: GroupListView(kind: .genre)
        case .composers: GroupListView(kind: .composer)
        case .folders: FoldersView()
        case .playlists: PlaylistsView()
        case .sources: SourcesView()
        case .files: FilesView()
        case .downloads: DownloadsView()
        case .favorites: FavoritesView()
        case .history: HistoryView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}
