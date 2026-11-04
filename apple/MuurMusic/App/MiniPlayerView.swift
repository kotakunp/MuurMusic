import SwiftUI
import MuurCore
import MuurAudio

/// The persistent bottom mini player (above the tab bar on iOS, bottom of the detail column on macOS).
struct MiniPlayerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                ProgressView(value: player.duration > 0 ? player.position / player.duration : 0)
                    .progressViewStyle(.linear)
                    .tint(Color(hex: model.settings.accent.hex))
                    .frame(height: 2)
                    .accessibilityHidden(true)

                HStack(spacing: 12) {
                    ArtworkImage(artworkKey: track.artworkKey, cornerRadius: 6)
                        .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(track.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button {
                        model.toggleFavorite(track)
                    } label: {
                        Image(systemName: track.favorite ? "heart.fill" : "heart")
                            .foregroundStyle(track.favorite ? MuurTheme.accentAmber : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(track.favorite ? "Remove from favorites" : "Add to favorites")

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { presentNowPlaying() }
            }
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
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
