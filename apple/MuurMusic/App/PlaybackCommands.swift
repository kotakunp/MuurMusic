import SwiftUI
import MuurCore
import MuurAudio

/// Menu bar commands (macOS) and keyboard shortcuts (both platforms).
struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(model.player.isPlaying ? "Pause" : "Play") {
                model.player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Next Track") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Skip Forward") { model.player.skipForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Skip Backward") { model.player.skipBackward() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Divider()

            Button("Volume Up") { model.player.volume = min(1, model.player.volume + 0.05) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { model.player.volume = max(0, model.player.volume - 0.05) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Toggle("Shuffle", isOn: shuffleBinding)
                .keyboardShortcut("s", modifiers: .command)
            Button(repeatTitle) { model.player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Stop After Current Track") {
                model.player.setSleepTimer(model.player.sleepTimer == .endOfTrack ? .off : .endOfTrack)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Now Playing") {
                model.isShowingNowPlaying = true
                model.nowPlayingWindowRequest += 1
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            #if os(macOS)
            Button("Mini Player") {
                NotificationCenter.default.post(name: .muurOpenMiniPlayer, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            #endif
        }

        CommandGroup(replacing: .sidebar) {
            Button("Search") {
                model.navigate(to: .search)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(get: { model.player.shuffleMode == .on },
                set: { model.player.setShuffle($0 ? .on : .off) })
    }

    private var repeatTitle: String {
        switch model.player.repeatMode {
        case .off: return "Repeat: Off"
        case .all: return "Repeat: All"
        case .one: return "Repeat: One"
        }
    }
}

extension Notification.Name {
    static let muurOpenMiniPlayer = Notification.Name("app.muur.music.openMiniPlayer")
}
