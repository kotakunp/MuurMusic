import Foundation
import MediaPlayer
import MuurCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Publishes the current track to `MPNowPlayingInfoCenter` (Control Center, lock screen, Now Playing
/// app on macOS) and wires `MPRemoteCommandCenter` (headset buttons, lock screen controls).
@MainActor
public final class NowPlayingManager {
    public var onPlay: (@MainActor () -> Void)?
    public var onPause: (@MainActor () -> Void)?
    public var onTogglePlayPause: (@MainActor () -> Void)?
    public var onNext: (@MainActor () -> Void)?
    public var onPrevious: (@MainActor () -> Void)?
    public var onSeek: (@MainActor (Double) -> Void)?
    public var onSkipForward: (@MainActor (Double) -> Void)?
    public var onSkipBackward: (@MainActor (Double) -> Void)?
    public var onSetFavorite: (@MainActor (Track, Bool) async -> Void)?
    public var onChangePlaybackRate: (@MainActor (Double) -> Void)?

    private var configured = false
    private var lastArtworkKey: String?
    private var cachedArtwork: MPMediaItemArtwork?
    private var publishedTrack: Track?

    public init() {}

    /// Registers the remote-command handlers (call once at launch).
    public func configure(skipBack: Double = 15, skipForward: Double = 30) {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.fire(\.onPlay); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.fire(\.onPause); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.fire(\.onTogglePlayPause); return .success }
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in self?.fire(\.onNext); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.fire(\.onPrevious); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, let onSeek = self?.onSeek else { return .commandFailed }
            Task { @MainActor in onSeek(event.positionTime) }
            return .success
        }
        #if os(iOS)
        // iOS gives interval skips priority over track navigation in the system player.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.likeCommand.addTarget { [weak self] event in
            guard let feedback = event as? MPFeedbackCommandEvent else { return .commandFailed }
            let favorite = !feedback.isNegative
            Task { @MainActor [weak self] in
                guard let self, let track = publishedTrack else { return }
                await onSetFavorite?(track, favorite)
            }
            return .success
        }
        #else
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent, let handler = self?.onSkipForward else { return .commandFailed }
            Task { @MainActor in handler(event.interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent, let handler = self?.onSkipBackward else { return .commandFailed }
            Task { @MainActor in handler(event.interval) }
            return .success
        }
        #endif
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent, let handler = self?.onChangePlaybackRate else { return .commandFailed }
            Task { @MainActor in handler(Double(event.playbackRate)) }
            return .success
        }
    }

    private func fire(_ handler: KeyPath<NowPlayingManager, (@MainActor () -> Void)?>) {
        Task { @MainActor in self[keyPath: handler]?() }
    }

    /// Publishes track metadata. `artwork` is JPEG/PNG data (read from `ArtworkCache`); cached per key.
    public func update(track: Track, elapsed: Double, duration: Double, rate: Double, isPlaying: Bool, artwork: Data?) {
        updateFavorite(track)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if let number = track.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = number }
        if let genre = Optional(track.genre), !genre.isEmpty { info[MPMediaItemPropertyGenre] = genre }
        if track.isCueTrack { info[MPMediaItemPropertyComposer] = track.composer }
        if let artwork, track.artworkKey != lastArtworkKey || cachedArtwork == nil {
            lastArtworkKey = track.artworkKey
            #if canImport(UIKit)
            if let image = UIImage(data: artwork) {
                cachedArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: artwork) {
                cachedArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            #endif
        }
        if let cachedArtwork { info[MPMediaItemPropertyArtwork] = cachedArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Lightweight elapsed-time refresh (call once per second while playing).
    public func updateElapsed(_ elapsed: Double, rate: Double, isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func setPlaybackStatePlaying(_ playing: Bool) {
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
    }

    private func updateFavorite(_ track: Track?) {
        #if os(iOS)
        publishedTrack = track
        let command = MPRemoteCommandCenter.shared().likeCommand
        let favorite = track?.favorite == true
        command.isEnabled = track != nil
        command.isActive = favorite
        command.localizedTitle = favorite ? String(localized: "Remove from Liked Songs") : String(localized: "Add to Liked Songs")
        command.localizedShortTitle = favorite ? String(localized: "Unlike") : String(localized: "Like")
        #endif
    }

    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateFavorite(nil)
        lastArtworkKey = nil
        cachedArtwork = nil
    }
}
