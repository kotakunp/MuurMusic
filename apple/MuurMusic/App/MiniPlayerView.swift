import SwiftUI
import MuurCore
import MuurAudio

/// Artwork, title and the two transport buttons shared by every mini player.
struct MiniPlayerContent: View {
    @EnvironmentObject var player: PlaybackController

    let track: Track
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkImage(artworkKey: track.artworkKey, cornerRadius: compact ? 5 : 7, size: 120)
                .frame(width: compact ? 26 : 36, height: compact ? 26 : 36)

            VStack(alignment: .leading, spacing: 0) {
                Text(track.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !compact {
                    Text(track.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next track")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

#if os(iOS)
/// iOS 26 tab bar accessory. Shrinks to a single line when the tab bar minimizes.
@available(iOS 26.0, *)
struct MiniPlayerAccessory: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let namespace: Namespace.ID

    var body: some View {
        if let track = player.currentTrack {
            MiniPlayerContent(track: track, compact: placement == .inline)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
                .onTapGesture { model.isShowingNowPlaying = true }
                .nowPlayingTransitionSource(namespace)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens Now Playing")
        }
    }
}
#endif

/// Floating glass mini player (iOS before 26.1, macOS detail column).
struct MiniPlayerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var namespace: Namespace.ID? = nil

    var body: some View {
        if let track = player.currentTrack {
            MiniPlayerContent(track: track)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
                .muurGlass(in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { presentNowPlaying() }
                .nowPlayingTransitionSource(namespace)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .accessibilityElement(children: .contain)
        }
    }

    private func presentNowPlaying() {
        #if os(iOS)
        model.isShowingNowPlaying = true
        #else
        openWindow(id: MuurWindowID.nowPlaying.rawValue)
        #endif
    }
}
