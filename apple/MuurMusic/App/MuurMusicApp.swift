import SwiftUI
import MuurCore
import MuurAudio
import AuthenticationServices
#if os(macOS)
import AppKit
#endif

@main
struct MuurMusicApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(MuurAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MuurMacAppDelegate.self) private var appDelegate
    #endif

    @StateObject private var model = AppModel()

    init() {
        // OAuth (ASWebAuthenticationSession) needs a presentation anchor.
        #if os(iOS)
        OAuthManager.shared.presentationAnchorProvider = {
            let scenes = UIApplication.shared.connectedScenes
            let windows = scenes.compactMap { ($0 as? UIWindowScene)?.windows }.flatMap { $0 }
            return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
        }
        #elseif os(macOS)
        OAuthManager.shared.presentationAnchorProvider = {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .defaultPosition(.center)
        #endif
        .commands {
            PlaybackCommands(model: model)
        }

        #if os(macOS)
        Window("Now Playing", id: MuurWindowID.nowPlaying.rawValue) {
            NowPlayingView()
                .environmentObject(model)
                .environmentObject(model.player)
                .frame(minWidth: 400, minHeight: 600)
        }
        .defaultSize(width: 460, height: 740)
        .defaultPosition(.center)

        Window("MuurMusic", id: MuurWindowID.miniPlayer.rawValue) {
            MiniPlayerWindowView(clock: model.player.clock)
                .environmentObject(model)
                .environmentObject(model.player)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        #endif
    }
}

/// Window scene identifiers (macOS).
enum MuurWindowID: String {
    case nowPlaying = "now-playing"
    case miniPlayer = "mini-player"
}
