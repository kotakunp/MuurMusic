import SwiftUI
#if os(iOS)
import AVFAudio
import MediaPlayer
#endif

/// Volume control styled like `NowPlayingScrubber`: a thin bar between two speaker icons that
/// thickens while dragging. Dragging moves the volume relative to where it was, so touching the
/// bar never jumps it to a new level.
struct VolumeBar: View {
    var value: Float
    var onChange: (Float) -> Void

    @State private var dragStart: Float?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .frame(width: 20, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white.opacity(dragStart == nil ? 0.7 : 1))
                        .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
                }
                .frame(height: dragStart == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard geometry.size.width > 0 else { return }
                            let start = dragStart ?? value
                            if dragStart == nil { dragStart = start }
                            let delta = Float(drag.translation.width / geometry.size.width)
                            onChange(min(max(start + delta, 0), 1))
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
            .frame(height: 20)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragStart == nil)
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 20, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 0.0625, 1))
            case .decrement: onChange(max(value - 0.0625, 0))
            @unknown default: break
            }
        }
    }
}

#if os(iOS)
/// Follows and sets the device volume. iOS only lets apps change it through `MPVolumeView`'s
/// slider, so `SystemVolumeBar` keeps an invisible one in the hierarchy and drives that.
@MainActor
final class SystemVolumeModel: ObservableObject {
    @Published private(set) var volume: Float
    fileprivate weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?

    init() {
        let session = AVAudioSession.sharedInstance()
        volume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volume = value }
        }
    }

    func set(_ value: Float) {
        volume = value
        guard let slider = volumeView?.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

/// The device volume as a `VolumeBar`. While it is on screen the system volume HUD stays hidden,
/// as it does in other music apps.
struct SystemVolumeBar: View {
    @StateObject private var model = SystemVolumeModel()

    var body: some View {
        VolumeBar(value: model.volume) { model.set($0) }
            .background(HiddenVolumeView(model: model).frame(width: 1, height: 1))
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    let model: SystemVolumeModel

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // Hidden or zero-alpha volume views stop working, so it stays nearly transparent instead.
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        model.volumeView = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        model.volumeView = uiView
    }
}
#endif
