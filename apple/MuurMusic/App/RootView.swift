import SwiftUI
import MuurCore
import MuurAudio

/// The root of the app: a tab bar on iOS, a sidebar split view on macOS.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Namespace private var playerNamespace
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        content
            .tint(model.settings.accentColor)
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
    /// Library hub, up to three pinned sections, then Search.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.1, *) {
            glassTabs
        } else {
            classicTabs
        }
    }

    private var iOSRoot: some View {
        tabs
            .fullScreenCover(isPresented: $model.isShowingNowPlaying) {
                NowPlayingView()
                    .environmentObject(model)
                    .environmentObject(player)
                    .nowPlayingZoom(playerNamespace)
            }
    }

    /// iOS 26: Liquid Glass tab bar that shrinks on scroll, the mini player as its bottom
    /// accessory, and Search as the separate search-role tab.
    @available(iOS 26.1, *)
    private var glassTabs: some View {
        TabView(selection: $model.tab) {
            Tab("Library", systemImage: "books.vertical.fill", value: HomeTab.home) {
                NavigationStack(path: $model.homePath) {
                    LibraryHomeView()
                }
            }
            ForEach(model.pinnedTabs, id: \.self) { tab in
                Tab(AppSection(tab)?.title ?? "", systemImage: AppSection(tab)?.systemImage ?? "music.note", value: HomeTab.library(tab)) {
                    NavigationStack {
                        RootSectionDestination(section: AppSection(tab) ?? .songs)
                    }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: HomeTab.search, role: .search) {
                NavigationStack {
                    SearchView()
                        .muurTopLevelTitle()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: player.currentTrack != nil) {
            MiniPlayerAccessory(namespace: playerNamespace)
        }
    }

    /// iOS 17-26.0: the same tabs with a floating mini player above the tab bar.
    private var classicTabs: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.homePath) {
                LibraryHomeView()
            }
            .withMiniPlayer(namespace: playerNamespace)
            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            .tag(HomeTab.home)

            ForEach(model.pinnedTabs, id: \.self) { tab in
                let section = AppSection(tab) ?? .songs
                // The inset goes on the stack, not the root view, so pushed screens keep the mini player.
                NavigationStack {
                    RootSectionDestination(section: section)
                }
                .withMiniPlayer(namespace: playerNamespace)
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(HomeTab.library(tab))
            }

            NavigationStack {
                SearchView()
                    .muurTopLevelTitle()
            }
            .withMiniPlayer(namespace: playerNamespace)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(HomeTab.search)
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
                RootSectionDestination(section: model.section ?? .songs)
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
}

extension View {
    /// Floats the mini player above the tab bar (iOS before 26.1) or at the bottom of the detail column (macOS).
    func withMiniPlayer(namespace: Namespace.ID? = nil) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView(namespace: namespace)
        }
    }

    /// Marks the view the Now Playing screen zooms out of.
    @ViewBuilder
    func nowPlayingTransitionSource(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            if #available(iOS 18.0, macOS 15.0, *) {
                matchedTransitionSource(id: NowPlayingTransition.sourceID, in: namespace)
            } else {
                self
            }
        } else {
            self
        }
    }

    /// Zooms the Now Playing cover out of the mini player (iOS 18+).
    @ViewBuilder
    func nowPlayingZoom(_ namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: NowPlayingTransition.sourceID, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Large bold title on the same row as the toolbar buttons, instead of a second row below them.
    @ViewBuilder
    func muurTopLevelTitle() -> some View {
        #if os(iOS)
        toolbarTitleDisplayMode(.inlineLarge)
        #else
        self
        #endif
    }
}

enum NowPlayingTransition {
    static let sourceID = "now-playing"
}

/// The screen for a section, used by tabs, the Library hub and the macOS detail column.
struct RootSectionDestination: View {
    let section: AppSection

    var body: some View {
        content
            .muurTopLevelTitle()
    }

    @ViewBuilder
    private var content: some View {
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
