#if !os(macOS)
import AVFAudio
import Foundation
import MuurCore

/// Owns the `AVAudioSession` for playback: category, route-change and interruption handling.
@MainActor
public final class AudioSessionManager: ObservableObject {
    /// Published for the UI: headphones/speaker/AirPlay...
    @Published public private(set) var currentRouteName: String = ""
    @Published public private(set) var isOtherAudioPlaying = false

    /// Called when playback should pause (unplugged headphones with `pauseOnRouteLoss`, phone call...).
    public var onShouldPause: (@MainActor () -> Void)?
    /// Called when an interruption ended and playback may resume.
    public var onShouldResume: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var configured = false

    public init() {}

    /// Configures and activates the session. `mixWithOthers` lowers other apps instead of stopping them.
    public func activate(mixWithOthers: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = []
        if mixWithOthers { options.insert(.mixWithOthers) }
        try session.setCategory(.playback, mode: .default, options: options)
        try session.setActive(true)
        configured = true
        updateRoute()
        startObserving()
        Log.audio.info("Audio session active (route: \(session.currentRoute.outputs.first?.portName ?? "unknown", privacy: .public))")
    }

    public func deactivate() {
        guard configured else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        configured = false
    }

    public var sampleRate: Double { AVAudioSession.sharedInstance().sampleRate }

    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        currentRouteName = session.currentRoute.outputs.first?.portName ?? ""
        isOtherAudioPlaying = session.isOtherAudioPlaying
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                try? self.activate(mixWithOthers: false)
            }
        })
    }

    private func handleRouteChange(_ note: Notification) {
        updateRoute()
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            onShouldPause?()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onShouldPause?()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                onShouldResume?()
            }
        @unknown default:
            break
        }
    }
}
#endif
