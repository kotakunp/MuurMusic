import AppIntents
import MuurCore
import MuurAudio

/// Play/pause toggle (Siri, Shortcuts, Control Center).
struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggles playback in MuurMusic.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.requireShared().player.togglePlayPause()
        return .result()
    }
}

/// Skip to the next track.
struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track in MuurMusic.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.requireShared().player.next()
        return .result()
    }
}

/// Go back to the previous track.
struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Returns to the previous track in MuurMusic.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.requireShared().player.previous()
        return .result()
    }
}

/// Resume the restored queue.
struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume MuurMusic"
    static var description = IntentDescription("Resumes your last MuurMusic session.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.requireShared().player.resumeRestoredQueue()
        return .result()
    }
}

/// Shuffle the liked songs.
struct ShuffleFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var description = IntentDescription("Plays your MuurMusic liked songs on shuffle.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.requireShared()
        do {
            let tracks = try await model.environment.database.read { db in
                try LibraryQueries.tracks(db, filter: .favorites, sort: TrackSort(field: .dateAdded, ascending: false), limit: 500)
            }
            model.play(tracks, shuffle: true)
        } catch {
            model.showError(error)
        }
        return .result()
    }
}

/// A playlist as an App Entity for Shortcuts.
struct MuurPlaylistEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")

    // Int64 is not EntityIdentifierConvertible; playlist row IDs fit in Int on 64-bit platforms.
    var id: Int
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = MuurPlaylistQuery()
}

struct MuurPlaylistQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [MuurPlaylistEntity] {
        await allPlaylists().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MuurPlaylistEntity] {
        await allPlaylists()
    }

    @MainActor
    private func allPlaylists() -> [MuurPlaylistEntity] {
        guard let model = AppModel.shared else { return [] }
        return model.playlists.compactMap { playlist in
            guard let id = playlist.id else { return nil }
            return MuurPlaylistEntity(id: Int(id), name: playlist.name)
        }
    }
}

/// Play a chosen playlist.
struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Plays a MuurMusic playlist from the start.")
    static var openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: MuurPlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.requireShared()
        if let contents = try await model.environment.playlists.contents(of: Int64(playlist.id)) {
            model.play(contents.tracks)
        }
        return .result()
    }
}

#if os(iOS)
/// Spotlight / Siri shortcuts.
struct MuurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: ["Play or pause \(.applicationName)", "Toggle \(.applicationName)"],
            shortTitle: "Play/Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track in \(.applicationName)"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: ShuffleFavoritesIntent(),
            phrases: ["Shuffle my liked songs in \(.applicationName)", "Shuffle my favorites in \(.applicationName)"],
            shortTitle: "Shuffle Liked Songs",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: ["Play a playlist in \(.applicationName)"],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
#endif
