import Foundation
import MuurCore
import MuurWidgetKitSupport
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the widget snapshot (`WidgetSnapshot` + artwork thumbnails) into the App Group container
/// and reloads widget timelines. Main-actor; called by `PlaybackController` on state changes.
@MainActor
public final class WidgetSnapshotWriter {
    private let store: WidgetSharedStore
    private let artwork: ArtworkCache

    public init(store: WidgetSharedStore, artwork: ArtworkCache) {
        self.store = store
        self.artwork = artwork
    }

    /// Artwork thumbnail stored in the shared container; returns the file name for the snapshot.
    private func artworkFileName(for track: Track) -> String? {
        guard let key = track.artworkKey,
              let data = artwork.thumbnailData(for: key, size: ArtworkCache.Size.widget.rawValue) else { return nil }
        let fileName = key + ".jpg"
        return try? store.writeArtwork(data, fileName: fileName)
    }

    private func queueItem(_ track: Track) -> WidgetQueueItem {
        WidgetQueueItem(id: track.stableID, title: track.displayTitle, artist: track.displayArtist,
                        album: track.album, artworkFileName: artworkFileName(for: track), duration: track.duration)
    }

    /// Publishes a full snapshot and asks the system to refresh the widgets.
    public func publish(nowPlaying track: Track?, isPlaying: Bool, elapsed: Double, playbackRate: Double,
                        upNext: [Track], recentlyPlayed: [Track], lyrics: Lyrics?, accentHex: String, canResume: Bool) {
        var snapshot = WidgetSnapshot()
        if let track {
            snapshot.nowPlaying = WidgetNowPlaying(
                title: track.displayTitle, artist: track.displayArtist, album: track.album,
                artworkFileName: artworkFileName(for: track), duration: track.duration,
                elapsed: elapsed, isPlaying: isPlaying, playbackRate: playbackRate,
                formatBadge: track.formatBadge, isFavorite: track.favorite)
        }
        snapshot.upNext = upNext.prefix(20).map(queueItem)
        snapshot.recentlyPlayed = recentlyPlayed.prefix(10).map(queueItem)
        if let lyrics {
            snapshot.lyrics = lyrics.lines.map { WidgetLyricLine(time: $0.time, text: $0.text) }
            snapshot.lyricsAreSynced = lyrics.isSynced
        }
        snapshot.accentHex = accentHex
        snapshot.canResume = canResume
        snapshot.updatedAt = Date()
        do {
            try store.write(snapshot)
            var keep = Set<String>()
            for item in snapshot.upNext + snapshot.recentlyPlayed { if let name = item.artworkFileName { keep.insert(name) } }
            if let name = snapshot.nowPlaying?.artworkFileName { keep.insert(name) }
            store.pruneArtwork(keeping: keep)
        } catch {
            Log.audio.error("Widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
        reloadTimelines()
    }

    /// Reloads all widget timelines (no-op where WidgetKit is unavailable, e.g. tests on macOS CLI).
    public func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
