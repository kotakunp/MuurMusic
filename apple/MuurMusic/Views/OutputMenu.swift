import SwiftUI
import MuurCore
import MuurAudio
#if os(iOS)
import MediaPlayer
import AVKit
#endif

/// Output picker: this device or a discovered DLNA renderer.
struct OutputMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    @State private var renderers: [DLNARenderer] = []
    @State private var isSearching = false

    var body: some View {
        Menu {
            Button {
                player.setLocalOutput()
            } label: {
                if case .local = player.output {
                    Label("This Device", systemImage: "checkmark")
                } else {
                    Label("This Device", systemImage: "iphone")
                }
            }

            if !renderers.isEmpty {
                Divider()
                Section("DLNA / UPnP") {
                    ForEach(renderers, id: \.id) { renderer in
                        Button {
                            player.setRenderer(renderer)
                        } label: {
                            if isCurrent(renderer) {
                                Label(renderer.displayName, systemImage: "checkmark")
                            } else {
                                Text(renderer.displayName)
                            }
                        }
                    }
                }
            }

            Divider()
            Button {
                refresh()
            } label: {
                Label(isSearching ? "Searching…" : "Search for Devices", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(isSearching)
        } label: {
            Image(systemName: outputIcon)
        }
        .accessibilityLabel("DLNA output")
        .task { refresh() }
    }

    private var outputIcon: String {
        // Not the AirPlay glyph: this menu only switches between this device and DLNA renderers.
        if case .dlna = player.output {
            return "hifispeaker.2.fill"
        }
        return "hifispeaker.2"
    }

    private func isCurrent(_ renderer: DLNARenderer) -> Bool {
        if case .dlna(let id, _) = player.output {
            return id == renderer.id
        }
        return false
    }

    private func refresh() {
        isSearching = true
        Task {
            renderers = await player.discoverRenderers()
            isSearching = false
        }
    }
}

#if os(iOS)
/// The system volume slider with its AirPlay / Bluetooth route button. iOS apps cannot change the
/// device volume directly, so local playback uses this instead of a SwiftUI slider.
/// The Simulator renders it empty; it only appears on a device.
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// The system AirPlay / Bluetooth route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.6)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
