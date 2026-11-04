import SwiftUI
import MuurCore
import MuurAudio
#if os(iOS)
import AVKit
#endif

/// Output picker: system route picker (iOS) plus DLNA renderer discovery.
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
        .accessibilityLabel("Audio output")
        .task { refresh() }
    }

    private var outputIcon: String {
        if case .dlna = player.output {
            return "hifispeaker.fill"
        }
        return "airplayaudio"
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
/// Wraps AVRoutePickerView for AirPlay / Bluetooth output selection.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(Color.secondary)
        picker.activeTintColor = UIColor(MuurTheme.accentAmber)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
