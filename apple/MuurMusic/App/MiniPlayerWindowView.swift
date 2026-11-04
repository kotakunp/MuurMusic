#if os(macOS)
import SwiftUI
import MuurCore
import MuurAudio

/// Compact floating player window (macOS).
struct MiniPlayerWindowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @ObservedObject var clock: PlaybackClock
    @Environment(\.openWindow) private var openWindow
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkImage(artworkKey: player.currentTrack?.artworkKey, cornerRadius: MuurTheme.radiusCard)
                    .frame(width: 64, height: 64)
                    .onTapGesture { openWindow(id: MuurWindowID.nowPlaying.rawValue) }
                    .muurPointer()

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.displayTitle ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(player.currentTrack?.displayArtist ?? "Pick a song and press play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 16) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentTrack == nil)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 2) {
                Slider(value: sliderValue, in: 0...max(player.duration, 1)) { editing in
                    isSeeking = editing
                    if !editing { player.seek(to: seekPosition) }
                }
                .controlSize(.small)
                HStack {
                    Text(MuurFormat.duration(isSeeking ? seekPosition : clock.position))
                    Spacer()
                    Text(MuurFormat.duration(player.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial)
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { isSeeking ? seekPosition : clock.position },
                set: { seekPosition = $0 })
    }
}
#endif
