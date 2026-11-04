import SwiftUI
import MuurCore
import MuurAudio

/// Full Now Playing screen: artwork/vinyl/visualizer, transport, seek, extras.
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    enum Pane: String, CaseIterable, Identifiable {
        case player = "Now Playing"
        case lyrics = "Lyrics"
        case queue = "Up Next"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .player: return "play.circle"
            case .lyrics: return "quote.bubble"
            case .queue: return "list.bullet"
            }
        }
    }

    @State private var pane: Pane = .player
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var isShowingEQ = false
    @State private var isShowingEffects = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch pane {
                case .player:
                    playerPane
                case .lyrics:
                    LyricsView(track: player.currentTrack)
                case .queue:
                    QueueView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(backgroundGradient)
        .sheet(isPresented: $isShowingEQ) {
            NavigationStack { EQView() }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 420)
            #endif
        }
        .sheet(isPresented: $isShowingEffects) {
            NavigationStack { EffectsView() }
            #if os(macOS)
            .frame(minWidth: 620, minHeight: 520)
            #endif
        }
    }

    private var backgroundGradient: some View {
        let palette = scheme.muur
        return LinearGradient(
            colors: [palette.bg, palette.bgHighlight.opacity(0.6), palette.bg],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            #if os(iOS)
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close Now Playing")
            #endif
            Spacer()
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Image(systemName: pane.systemImage).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityLabel("Now playing pane")
            Spacer()
            Menu {
                Button {
                    isShowingEQ = true
                } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
                Button {
                    isShowingEffects = true
                } label: {
                    Label("Audio Effects", systemImage: "waveform.badge.plus")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Audio settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Player pane

    private var playerPane: some View {
        ScrollView {
            VStack(spacing: 18) {
                artworkArea
                    .frame(maxWidth: 380)
                    .padding(.top, 6)

                titleBlock

                seekBlock

                transportRow

                volumeRow

                extrasRow

                LevelMetersView()
                    .opacity(player.isPlaying ? 1 : 0.3)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var artworkArea: some View {
        switch model.settings.nowPlayingStyle {
        case .vinyl:
            VinylView(track: player.currentTrack, isPlaying: player.isPlaying)
        case .visualizer:
            VisualizerView(preset: model.settings.visualizerPreset)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: MuurTheme.radiusCard, style: .continuous))
        case .artwork:
            ArtworkImage(artworkKey: player.currentTrack?.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 800)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.displayTitle ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitleLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let track = player.currentTrack {
                    Button {
                        model.toggleFavorite(track)
                    } label: {
                        Image(systemName: track.favorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(track.favorite ? MuurTheme.accentAmber : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(track.favorite ? "Remove from favorites" : "Add to favorites")
                }
            }
            if let track = player.currentTrack {
                HStack {
                    RatingView(rating: track.rating, starSize: 13) { value in
                        model.setRating(value, for: track)
                    }
                    Spacer()
                    Text(MuurFormat.formatDetails(track))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitleLine: String {
        guard let track = player.currentTrack else { return "Pick something to play" }
        return "\(track.displayArtist) — \(track.displayAlbum)"
    }

    private var seekBlock: some View {
        VStack(spacing: 4) {
            Slider(value: sliderBinding, in: 0...max(player.duration, 1)) { editing in
                isSeeking = editing
                if !editing {
                    player.seek(to: seekPosition)
                }
            }
            .tint(Color(hex: model.settings.accent.hex))
            .disabled(player.currentTrack == nil)
            HStack {
                Text(MuurFormat.duration(isSeeking ? seekPosition : player.position))
                Spacer()
                if player.isCrossfading {
                    Text("Crossfading")
                        .font(.caption2)
                        .foregroundStyle(MuurTheme.accentViolet)
                }
                Text("-" + MuurFormat.duration(max(player.duration - (isSeeking ? seekPosition : player.position), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isSeeking ? seekPosition : player.position },
            set: { seekPosition = $0 }
        )
    }

    private var transportRow: some View {
        HStack(spacing: 26) {
            Button {
                player.setShuffle(player.shuffleMode == .on ? .off : .on)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffleMode == .on ? Color(hex: model.settings.accent.hex) : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous track")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(Color(hex: model.settings.accent.hex))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color(hex: model.settings.accent.hex))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Repeat")
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    @ViewBuilder
    private var volumeRow: some View {
        #if os(macOS)
        volumeSlider
        #else
        if case .dlna = player.output {
            volumeSlider
        } else {
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                SystemVolumeView()
                    .frame(height: 32)
            }
        }
        #endif
    }

    private var volumeSlider: some View {
        HStack {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var extrasRow: some View {
        HStack(spacing: 20) {
            OutputMenu()
            Spacer()
            skipButton(seconds: -model.settings.skipBackInterval, icon: "gobackward.\(Int(model.settings.skipBackInterval))")
            speedMenu
            sleepTimerMenu
            skipButton(seconds: model.settings.skipForwardInterval, icon: "goforward.\(Int(model.settings.skipForwardInterval))")
            Spacer()
            Button {
                pane = .lyrics
            } label: {
                Image(systemName: "quote.bubble")
            }
            .accessibilityLabel("Lyrics")
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private func skipButton(seconds: Double, icon: String) -> some View {
        Button {
            if seconds < 0 { player.skipBackward() } else { player.skipForward() }
        } label: {
            Image(systemName: icon)
        }
        .accessibilityLabel(seconds < 0 ? "Skip backward" : "Skip forward")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                Button {
                    player.setSpeed(speed)
                } label: {
                    if abs(model.settings.playbackSpeed - speed) < 0.01 {
                        Label(Self.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(Self.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(Self.speedLabel(model.settings.playbackSpeed))
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .accessibilityLabel("Playback speed")
    }

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    private static func speedLabel(_ speed: Double) -> String {
        speed == floor(speed) ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    private var sleepTimerMenu: some View {
        Menu {
            Button {
                player.setSleepTimer(.off)
            } label: {
                if player.sleepTimer == .off {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            Button {
                player.setSleepTimer(.endOfTrack)
            } label: {
                if player.sleepTimer == .endOfTrack {
                    Label("Stop After Current Track", systemImage: "checkmark")
                } else {
                    Text("Stop After Current Track")
                }
            }
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    player.setSleepTimer(.minutes(minutes))
                } label: {
                    if player.sleepTimer == .minutes(minutes) {
                        Label("\(minutes) minutes", systemImage: "checkmark")
                    } else {
                        Text("\(minutes) minutes")
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
                    .foregroundStyle(player.sleepTimer == .off ? .secondary : MuurTheme.accentAmber)
                if let remaining = player.sleepTimerRemaining, player.sleepTimer != .endOfTrack {
                    Text(MuurFormat.duration(remaining))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(MuurTheme.accentAmber)
                }
            }
        }
        .accessibilityLabel("Sleep timer")
    }
}

/// Spinning vinyl artwork.
struct VinylView: View {
    let track: Track?
    let isPlaying: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 12)
                .padding(10)
            ArtworkImage(artworkKey: track?.artworkKey, cornerRadius: 999, size: 600)
                .clipShape(Circle())
                .padding(52)
            Circle()
                .fill(Color(hex: "#17122B"))
                .frame(width: 18, height: 18)
        }
        .aspectRatio(1, contentMode: .fit)
        .rotationEffect(.degrees(isPlaying ? 360 : 0))
        .animation(
            isPlaying ? .linear(duration: 18).repeatForever(autoreverses: false) : .default,
            value: isPlaying
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .accessibilityLabel("Vinyl artwork")
    }
}
