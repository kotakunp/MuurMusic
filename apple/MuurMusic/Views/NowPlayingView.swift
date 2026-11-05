import SwiftUI
import MuurCore
import MuurAudio

/// Full Now Playing screen. Artwork-tinted backdrop, large artwork that settles back while
/// paused, and transport controls that stay put while Lyrics or Up Next take the top half.
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.dismiss) private var dismiss

    enum Pane: Hashable {
        case player, lyrics, queue
    }

    @Namespace private var artworkNamespace
    @State private var pane: Pane = .player
    @State private var isShowingEQ = false
    @State private var isShowingEffects = false
    @State private var trackSheet: TrackSheetRequest?

    private var track: Track? { player.currentTrack }

    var body: some View {
        ZStack {
            NowPlayingBackground(artworkKey: track?.artworkKey)

            VStack(spacing: 0) {
                #if os(iOS)
                grabber
                #endif

                if pane == .player {
                    Spacer(minLength: 12)
                    artworkArea
                        .padding(.horizontal, 28)
                        .gesture(dismissDrag)
                    Spacer(minLength: 12)
                    titleRow
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
                } else {
                    compactHeader
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    paneContent
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                }

                controls
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: 620)
        }
        .preferredColorScheme(.dark)
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
        .sheet(item: $trackSheet) { request in
            TrackSheetHost(request: request)
        }
    }

    // MARK: Header

    #if os(iOS)
    private var grabber: some View {
        Capsule()
            .fill(.secondary)
            .frame(width: 38, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .gesture(dismissDrag)
            .accessibilityLabel("Close Now Playing")
            .accessibilityAddTraits(.isButton)
    }
    #endif

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                #if os(iOS)
                if value.translation.height > 110, abs(value.translation.width) < value.translation.height {
                    dismiss()
                }
                #endif
            }
    }

    @ViewBuilder
    private var artworkArea: some View {
        switch model.settings.nowPlayingStyle {
        case .vinyl:
            VinylView(track: track, isPlaying: player.isPlaying)
                .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
        case .visualizer:
            VStack(spacing: 14) {
                VisualizerView(preset: model.settings.visualizerPreset)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: MuurTheme.radiusArtwork, style: .continuous))
                    .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
                LevelMetersView()
                    .opacity(player.isPlaying ? 1 : 0.3)
            }
        case .artwork:
            ArtworkImage(artworkKey: track?.artworkKey, cornerRadius: MuurTheme.radiusArtwork, size: 1000)
                .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
                .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: player.isPlaying ? 32 : 16, y: player.isPlaying ? 18 : 8)
                .scaleEffect(player.isPlaying ? 1 : 0.82)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.displayTitle ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(track?.displayArtist ?? "Pick something to play")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trackButtons
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkImage(artworkKey: track?.artworkKey, cornerRadius: 8, size: 200)
                .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .onTapGesture { setPane(.player) }
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.displayTitle ?? "Not Playing")
                    .font(.headline)
                    .lineLimit(1)
                Text(track?.displayArtist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trackButtons
        }
    }

    @ViewBuilder
    private var trackButtons: some View {
        if let track {
            Button {
                model.toggleFavorite(track)
            } label: {
                Image(systemName: track.favorite ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
                    .modifier(CircleIconStyle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.favorite ? "Remove from Liked Songs" : "Add to Liked Songs")
        }
        moreMenu
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .lyrics:
            LyricsView(track: track)
        case .queue:
            QueueView()
        case .player:
            EmptyView()
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 18) {
            NowPlayingScrubber(clock: player.clock, centerText: { statusText })
            transportRow
            volumeRow
            bottomBar
        }
        .tint(.white)
    }

    private var statusText: String {
        if player.isCrossfading { return "Crossfading" }
        if let remaining = player.sleepTimerRemaining, player.sleepTimer != .endOfTrack {
            return "Sleep in \(MuurFormat.duration(remaining))"
        }
        if player.sleepTimer == .endOfTrack { return "Stops after this track" }
        guard let track else { return "" }
        return MuurFormat.formatDetails(track)
    }

    private var transportRow: some View {
        HStack(spacing: 0) {
            modeToggle(isOn: player.shuffleMode == .on, systemImage: "shuffle", label: "Shuffle") {
                player.setShuffle(player.shuffleMode == .on ? .off : .on)
            }
            Spacer()
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous track")
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next track")
            Spacer()
            modeToggle(isOn: player.repeatMode != .off, systemImage: player.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat") {
                player.cycleRepeatMode()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(track == nil)
    }

    private func modeToggle(isOn: Bool, systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.black) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(isOn ? 0.85 : 0))
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    @ViewBuilder
    private var volumeRow: some View {
        #if os(macOS)
        volumeSlider
        #else
        if case .dlna = player.output {
            VolumeBar(value: player.volume) { player.volume = $0 }
        } else {
            SystemVolumeBar()
        }
        #endif
    }

    #if os(macOS)
    private var volumeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private var bottomBar: some View {
        HStack {
            paneToggle(.lyrics, systemImage: pane == .lyrics ? "quote.bubble.fill" : "quote.bubble", label: "Lyrics")
            Spacer()
            HStack(spacing: 22) {
                #if os(iOS)
                AirPlayButton()
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("AirPlay")
                #endif
                OutputMenu()
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            Spacer()
            paneToggle(.queue, systemImage: "list.bullet", label: "Up Next")
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func paneToggle(_ target: Pane, systemImage: String, label: String) -> some View {
        Button {
            setPane(pane == target ? .player : target)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(pane == target ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(pane == target ? 0.18 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(pane == target ? .isSelected : [])
    }

    private func setPane(_ newPane: Pane) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            pane = newPane
        }
    }

    // MARK: More menu

    private var moreMenu: some View {
        Menu {
            if let track {
                Section {
                    Button {
                        trackSheet = TrackSheetRequest(kind: .playlistPicker, tracks: [track])
                    } label: {
                        Label("Add to Playlist…", systemImage: "text.badge.plus")
                    }
                    Picker(selection: ratingBinding(track)) {
                        Text("No Rating").tag(0)
                        ForEach(1...5, id: \.self) { value in
                            Text(String(repeating: "★", count: value)).tag(value)
                        }
                    } label: {
                        Label("Rating", systemImage: "star")
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                Button {
                    player.skipBackward()
                } label: {
                    Label("Back \(Int(model.settings.skipBackInterval)) Seconds", systemImage: "gobackward.\(Int(model.settings.skipBackInterval))")
                }
                Button {
                    player.skipForward()
                } label: {
                    Label("Forward \(Int(model.settings.skipForwardInterval)) Seconds", systemImage: "goforward.\(Int(model.settings.skipForwardInterval))")
                }
            }
            Section {
                Picker(selection: speedBinding) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Text(Self.speedLabel(speed)).tag(speed)
                    }
                } label: {
                    Label("Speed: \(Self.speedLabel(model.settings.playbackSpeed))", systemImage: "gauge.with.dots.needle.67percent")
                }
                .pickerStyle(.menu)
                sleepTimerMenu
            }
            Section {
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
            }
        } label: {
            Image(systemName: "ellipsis")
                .modifier(CircleIconStyle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    private func ratingBinding(_ track: Track) -> Binding<Int> {
        Binding(get: { track.rating }, set: { model.setRating($0, for: track) })
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { model.settings.playbackSpeed }, set: { player.setSpeed($0) })
    }

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    private static func speedLabel(_ speed: Double) -> String {
        speed == floor(speed) ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    private var sleepTimerMenu: some View {
        Menu {
            sleepOption("Off", timer: .off)
            sleepOption("End of Track", timer: .endOfTrack)
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                sleepOption("\(minutes) Minutes", timer: .minutes(minutes))
            }
        } label: {
            Label(sleepLabel, systemImage: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
    }

    // No live countdown: a label that changes every second rebuilds the open menu and resets its scrolling.
    private var sleepLabel: String {
        switch player.sleepTimer {
        case .off: return "Sleep Timer"
        case .endOfTrack: return "Sleep: End of Track"
        default: return "Sleep Timer On"
        }
    }

    private func sleepOption(_ title: String, timer: SleepTimerMode) -> some View {
        Button {
            player.setSleepTimer(timer)
        } label: {
            if player.sleepTimer == timer {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Round translucent backing for the heart and ellipsis buttons.
private struct CircleIconStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.14), in: Circle())
            .contentShape(Circle())
    }
}

/// Apple Music style scrubber: a thin bar that thickens while dragging, times underneath.
struct NowPlayingScrubber: View {
    @EnvironmentObject var player: PlaybackController
    @ObservedObject var clock: PlaybackClock

    /// Re-read on every clock tick so countdowns like the sleep timer stay live.
    var centerText: () -> String

    @State private var dragPosition: Double?

    private var duration: Double { max(player.duration, 0) }

    /// MuurFormat shows "--:--" for zero, which reads as unknown on a running clock.
    private static func clock(_ seconds: Double) -> String {
        seconds > 0.5 ? MuurFormat.duration(seconds) : "0:00"
    }
    private var shownPosition: Double { dragPosition ?? clock.position }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let fraction = duration > 0 ? min(max(shownPosition / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white.opacity(dragPosition == nil ? 0.7 : 1))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: dragPosition == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, geometry.size.width > 0 else { return }
                            let x = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragPosition = x * duration
                        }
                        .onEnded { _ in
                            if let dragPosition { player.seek(to: dragPosition) }
                            dragPosition = nil
                        }
                )
            }
            .frame(height: 20)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragPosition == nil)

            HStack {
                Text(Self.clock(shownPosition))
                    .frame(width: 60, alignment: .leading)
                Spacer(minLength: 4)
                Text(centerText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("-" + Self.clock(max(duration - shownPosition, 0)))
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .disabled(player.currentTrack == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(MuurFormat.duration(shownPosition)) of \(MuurFormat.duration(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(to: min(player.position + 10, duration))
            case .decrement: player.seek(to: max(player.position - 10, 0))
            @unknown default: break
            }
        }
    }
}

/// Heavily blurred artwork behind the Now Playing screen, so every album tints its own page.
struct NowPlayingBackground: View {
    let artworkKey: String?

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height) * 1.25
            ArtworkImage(artworkKey: artworkKey, cornerRadius: 0, size: 200)
                .frame(width: side, height: side)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .blur(radius: 90, opaque: true)
                .saturation(1.35)
        }
        .clipped()
        .overlay(Color.black.opacity(0.4))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: artworkKey)
        .accessibilityHidden(true)
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
                .fill(Color.black.opacity(0.85))
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
