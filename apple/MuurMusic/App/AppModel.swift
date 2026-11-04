import Foundation
import Combine
import SwiftUI
import MuurCore
import MuurAudio

/// A screen of the app. Used by the macOS sidebar and the iOS tab bar / "More" list.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case songs, albums, artists, albumArtists, genres, composers, folders
    case playlists, sources, files, downloads, favorites, history, search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .albumArtists: return "Album Artists"
        case .genres: return "Genres"
        case .composers: return "Composers"
        case .folders: return "Folders"
        case .playlists: return "Playlists"
        case .sources: return "Sources"
        case .files: return "Files"
        case .downloads: return "Downloads"
        case .favorites: return "Favorites"
        case .history: return "History"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "person.fill"
        case .albumArtists: return "person.2.fill"
        case .genres: return "guitars"
        case .composers: return "music.quarternote.3"
        case .folders: return "folder.fill"
        case .playlists: return "music.note.list"
        case .sources: return "externaldrive.fill.badge.wifi"
        case .files: return "doc.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .favorites: return "heart.fill"
        case .history: return "clock.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }

    init?(_ tab: LibraryTab) {
        self.init(rawValue: tab.rawValue)
    }

    /// Sections driven by the customizable tab order setting.
    static var tabConfigurable: [AppSection] {
        [.songs, .albums, .artists, .albumArtists, .genres, .composers, .folders, .playlists, .sources, .files, .search]
    }
}

/// The shared app state: MuurKit environment, playback facade, navigation and toasts.
@MainActor
final class AppModel: ObservableObject {
    /// Set at launch; used by CarPlay and App Intents.
    private(set) static var shared: AppModel?

    static func requireShared() -> AppModel {
        // App Intents and CarPlay can run before (or without) any UI scene.
        if let shared { return shared }
        return AppModel()
    }

    let environment: MuurEnvironment
    let player: PlaybackController

    var settings: MuurSettings { environment.settings }

    /// Database error at launch (falls back to an in-memory library).
    @Published var startupError: String?
    @Published var toast: MuurToast?

    // Navigation
    @Published var section: AppSection? = .songs
    /// iOS tab selection.
    @Published var tab: HomeTab = .home
    @Published var isShowingNowPlaying = false
    /// Incremented to ask the macOS root view to open the Now Playing window.
    @Published var nowPlayingWindowRequest = 0
    /// Playlist the user wants to see (deep link).
    @Published var openPlaylistID: Int64?
    /// Navigation path of the iOS Library tab (deep links to unpinned sections push here).
    @Published var homePath = NavigationPath()

    // Shared observed state
    @Published private(set) var sources: [SourceConfig] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = ScanProgress()
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var watchedFolders: [WatchedFolder] = []

    // Recent searches
    @Published private(set) var recentSearches: [String] = []

    private var settingsForwarding: AnyCancellable?
    private var scanErrorForwarding: AnyCancellable?

    init() {
        let booted: MuurEnvironment
        if let environment = try? MuurEnvironment.bootstrap() {
            booted = environment
            startupError = nil
        } else if let fallback = try? MuurEnvironment.inMemory() {
            booted = fallback
            startupError = "The library database could not be opened; running with a temporary in-memory library."
        } else {
            fatalError("MuurKit failed to initialize")
        }
        environment = booted
        player = PlaybackController(environment: booted)
        recentSearches = booted.defaults.stringArray(forKey: "recentSearches") ?? []
        if let firstTab = settings.tabOrder.first, let firstSection = AppSection(firstTab) {
            section = firstSection
        }
        AppModel.shared = self
        // Views read settings through `model.settings`, so they only redraw if the model re-publishes.
        settingsForwarding = booted.settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        booted.scanner.$isScanning.assign(to: &$isScanning)
        booted.scanner.$progress.assign(to: &$scanProgress)
        scanErrorForwarding = booted.scanner.$lastError.compactMap { $0 }.sink { [weak self] message in
            self?.toast = .error("Library scan failed: \(message)")
        }
        observe()
        if let startupError {
            toast = .error(startupError)
        }
    }

    private func observe() {
        let repository = environment.repository
        Task { [weak self] in
            do {
                for try await value in repository.observeSources() {
                    self?.sources = value
                }
            } catch { Log.core.error("Source observation failed: \(error.localizedDescription)") }
        }
        Task { [weak self] in
            do {
                for try await value in environment.playlists.observePlaylists() {
                    self?.playlists = value
                }
            } catch { Log.core.error("Playlist observation failed: \(error.localizedDescription)") }
        }
        Task { [weak self] in
            do {
                for try await value in repository.observeWatchedFolders() {
                    self?.watchedFolders = value
                }
            } catch { Log.core.error("Folder observation failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Toasts

    func showToast(_ toast: MuurToast) {
        self.toast = toast
    }

    func showError(_ error: Error) {
        showToast(.error(error))
    }

    func showError(_ message: String) {
        showToast(.error(message))
    }

    // MARK: Playback helpers

    func play(_ tracks: [Track], startIndex: Int = 0, shuffle: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        player.play(tracks, startIndex: startIndex, shuffle: shuffle)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        MuurHaptics.tap(enabled: settings.haptics)
        player.playNext(tracks)
        showToast(.success(tracks.count == 1 ? "Will play next" : "\(tracks.count) tracks play next", systemImage: "text.line.first.and.arrowtriangle.forward"))
    }

    func playLater(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        MuurHaptics.tap(enabled: settings.haptics)
        player.addToQueue(tracks)
        showToast(.success(tracks.count == 1 ? "Added to queue" : "\(tracks.count) tracks added to queue", systemImage: "text.append"))
    }

    func toggleFavorite(_ track: Track) {
        guard let id = track.id else { return }
        Task {
            do {
                let isFavorite = try await environment.repository.toggleFavorite(trackID: id)
                if isFavorite { MuurHaptics.purr(enabled: settings.haptics) }
            } catch {
                showError(error)
            }
        }
    }

    func setRating(_ rating: Int, for track: Track) {
        guard let id = track.id else { return }
        Task {
            do { try await environment.repository.setRating(rating, trackID: id) } catch { showError(error) }
        }
    }

    func download(_ tracks: [Track], groupName: String? = nil) {
        Task {
            do {
                let count = try await environment.downloads.enqueue(tracks, groupName: groupName)
                showToast(.success(count == 0 ? "Already downloaded" : "Downloading \(count) track(s)", systemImage: "arrow.down.circle.fill"))
            } catch {
                showError(error)
            }
        }
    }

    // MARK: Recent searches

    func recordSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        recentSearches = list
        environment.defaults.set(list, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        environment.defaults.removeObject(forKey: "recentSearches")
    }

    // MARK: Deep links

    /// Routes a URL opened by the system (widget deep links, OAuth redirects, files).
    func handleIncomingURL(_ url: URL) {
        if let link = DeepLink.parse(url) {
            route(link)
            return
        }
        Task {
            let handled = await environment.handleOpenURL(url)
            if handled, url.isFileURL {
                showToast(.success("Imported \(url.lastPathComponent)", systemImage: "square.and.arrow.down.fill"))
            }
        }
    }

    private func route(_ link: DeepLink) {
        switch link {
        case .nowPlaying:
            isShowingNowPlaying = true
            nowPlayingWindowRequest += 1
        case .playPause:
            player.togglePlayPause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .resume:
            player.resumeRestoredQueue()
        case .playlist(let id):
            navigate(to: .playlists)
            openPlaylistID = id
        case .search(let text):
            navigate(to: .search)
            if let text { recordSearch(text) }
        }
    }

    /// Library sections pinned as their own iOS tabs, between Library and Search.
    var pinnedTabs: [LibraryTab] {
        Array(settings.tabOrder.filter { $0 != .search }.prefix(3))
    }

    /// Selects the tab (iOS) or sidebar row (macOS) that shows the given section,
    /// pushing onto the Library stack when the section has no tab of its own.
    func navigate(to section: AppSection) {
        self.section = section
        if section == .search {
            tab = .search
        } else if let pinned = pinnedTabs.first(where: { AppSection($0) == section }) {
            tab = .library(pinned)
        } else {
            tab = .home
            var path = NavigationPath()
            path.append(section)
            homePath = path
        }
    }
}

/// iOS tab bar selection.
enum HomeTab: Hashable {
    /// The Library hub with every section.
    case home
    /// A section pinned from the customizable tab order.
    case library(LibraryTab)
    case search
}
