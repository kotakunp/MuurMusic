import AVFAudio
import Foundation
import MuurCore
import SFBAudioEngine

/// Events from one playback engine, forwarded from the SFBAudioEngine delegate (unspecified thread).
public enum EngineEvent: Sendable {
    case renderingStarted
    /// The current decoder rendered its final frame (natural track end).
    case renderingComplete
    case playbackStateChanged(isPlaying: Bool)
    /// The player's decoder queue ran dry.
    case endOfAudio
    case decodingAborted(message: String)
    case asynchronousError(message: String)
    case seekCompleted(frame: Int64)
    case configurationChange
}

/// One playback engine: an SFBAudioEngine `AudioPlayer` with time-pitch, EQ and the DSP unit
/// inserted between the player's source node and main mixer:
///
/// `sourceNode -> timePitch -> EQ -> DSP -> mainMixerNode -> outputNode`
///
/// Two engines are alternated by `PlaybackController` for crossfades. All methods that touch the
/// graph go through `AudioPlayer.modifyProcessingGraph`. Delegate callbacks are forwarded as
/// `EngineEvent`s on an unspecified thread; consumers must hop to the main actor.
final class PlaybackEngine: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    let player = AudioPlayer()
    private(set) var timePitch: AVAudioUnitTimePitch!
    private(set) var equalizer: AVAudioUnitEQ!
    private(set) var dspNode: DSPAudioNode!
    let tapBuffer: AudioTapBuffer
    let onEvent: @Sendable (EngineEvent) -> Void
    /// The track currently loaded (set by the controller; used to map delegate callbacks).
    let loadedTrackID = LockedValue<String?>(nil)
    private var graphInstalled = false

    /// ISO band frequencies of the 10-band EQ.
    public static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]

    init(tapBuffer: AudioTapBuffer, onEvent: @escaping @Sendable (EngineEvent) -> Void) throws {
        self.tapBuffer = tapBuffer
        self.onEvent = onEvent
        super.init()
        player.delegate = self
        try installGraph()
    }

    // MARK: Graph

    /// Attaches and connects the processing nodes. Safe to call again after a configuration change.
    func installGraph() throws {
        let dsp = try DSPAudioNode()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: PlaybackEngine.eqFrequencies.count)
        for (index, frequency) in PlaybackEngine.eqFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        let buffer = tapBuffer
        let audioPlayer = player
        audioPlayer.modifyProcessingGraph { engine in
            engine.attach(pitch)
            engine.attach(eq)
            engine.attach(dsp.effect)
            // The player initially connects sourceNode straight to the mixer; remove that connection
            // before inserting the chain, or the source would fan out to both paths.
            engine.disconnectNodeOutput(audioPlayer.sourceNode)
            engine.connect(audioPlayer.sourceNode, to: pitch, format: nil)
            engine.connect(pitch, to: eq, format: nil)
            engine.connect(eq, to: dsp.effect, format: nil)
            engine.connect(dsp.effect, to: audioPlayer.mainMixerNode, format: nil)
            audioPlayer.mainMixerNode.removeTap(onBus: 0)
            audioPlayer.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { pcmBuffer, _ in
                buffer.push(pcmBuffer)
            }
        }
        dspNode = dsp
        timePitch = pitch
        equalizer = eq
        graphInstalled = true
    }

    /// Reconnects the chain after the player rebuilds the graph for a new format.
    private func reconnectChain(engine: AVAudioEngine, format: AVAudioFormat) {
        guard let pitch = timePitch, let eq = equalizer, let dsp = dspNode else { return }
        engine.connect(pitch, to: eq, format: format)
        engine.connect(eq, to: dsp.effect, format: format)
        engine.connect(dsp.effect, to: player.mainMixerNode, format: format)
    }

    // MARK: Decoders

    /// Builds a decoder for a track: DSD files are converted (or wrapped in DoP), CUE tracks become
    /// audio regions of the shared file, everything else is a plain decoder.
    static func makeDecoder(for track: Track, url: URL, dsdMode: DSDPlaybackMode) throws -> any PCMDecoding {
        let ext = PathUtils.fileExtension(url.pathExtension.isEmpty ? track.fileName : url.lastPathComponent)
        if ["dsf", "dff", "dsd"].contains(ext) {
            #if os(macOS)
            if dsdMode == .dop { return try DoPDecoder(url: url) }
            #endif
            return try DSDPCMDecoder(url: url)
        }
        if let start = track.cueStart {
            let rate = track.sampleRate > 0 ? track.sampleRate : 44_100
            let startFrame = AVAudioFramePosition((start * rate).rounded())
            let length: AVAudioFramePosition
            if let end = track.cueEnd, end > start {
                length = AVAudioFramePosition(((end - start) * rate).rounded())
            } else {
                length = -1 // to the end of the file
            }
            return try AudioRegionDecoder(url: url, startFrame: startFrame, frameLength: length)
        }
        return try AudioDecoder(url: url)
    }

    // MARK: Transport

    func play(track: Track, url: URL, dsdMode: DSDPlaybackMode, at position: Double = 0) throws {
        let decoder = try PlaybackEngine.makeDecoder(for: track, url: url, dsdMode: dsdMode)
        loadedTrackID.set(track.libraryKey)
        _ = try player.play(decoder)
        if position > 0.5, player.supportsSeeking {
            _ = player.seek(time: position)
        }
    }

    /// Enqueues a decoder for gapless playback (same engine, no fade).
    func enqueueNext(track: Track, url: URL, dsdMode: DSDPlaybackMode) throws {
        let decoder = try PlaybackEngine.makeDecoder(for: track, url: url, dsdMode: dsdMode)
        _ = try player.enqueue(decoder)
    }

    /// True when a decoder for the next track is already queued.
    var queueIsEmpty: Bool { player.queueIsEmpty }

    func play() throws { _ = try player.play() }
    func pause() { _ = player.pause() }
    func resume() { _ = player.resume() }
    func stop() { player.stop() }

    func togglePlayPause() throws { _ = try player.togglePlayPause() }

    var isPlaying: Bool { player.isPlaying }
    var supportsSeeking: Bool { player.supportsSeeking }
    var currentTime: Double? { player.currentTime }
    var totalTime: Double? { player.totalTime }

    @discardableResult
    func seek(to seconds: Double) -> Bool { player.seek(time: seconds) }
    @discardableResult
    func seek(forward seconds: Double) -> Bool { player.seek(forward: seconds) }
    @discardableResult
    func seek(backward seconds: Double) -> Bool { player.seek(backward: seconds) }

    // MARK: Parameters

    /// 0.25 ... 4 (bypassed at 1).
    func setSpeed(_ speed: Double) {
        let clamped = min(max(speed, 0.25), 4)
        timePitch.rate = Float(clamped)
        timePitch.bypass = abs(clamped - 1) < 0.001
    }

    /// Applies the 10-band EQ (dB gains at the ISO frequencies) and preamp.
    func applyEQ(gains: [Double], preampDb: Double, enabled: Bool) {
        guard let eq = equalizer else { return }
        for (index, band) in eq.bands.enumerated() {
            band.gain = enabled && index < gains.count ? Float(min(max(gains[index], -24), 24)) : 0
        }
        eq.globalGain = enabled ? Float(min(max(preampDb, -24), 24)) : 0
        eq.bypass = !enabled
    }

    func fade(to value: Float, rampSeconds: Double) {
        dspNode?.unit.fade(to: value, rampSeconds: rampSeconds)
    }

    func snapFade(to value: Float) {
        dspNode?.unit.snapFade(to: value)
    }

    var currentFade: Float { dspNode?.unit.currentFade ?? 1 }

    /// Applies a DSP program built from the current settings.
    func applyDSP(chainJSON: String, dspEnabled: Bool, preGainDb: Double, loudnessEnabled: Bool, loudnessBoostDb: Double) {
        guard let dsp = dspNode else { return }
        let mixerFormat = player.mainMixerNode.outputFormat(forBus: 0)
        dsp.applySettings(chainJSON: chainJSON, dspEnabled: dspEnabled, preGainDb: preGainDb,
                          loudnessEnabled: loudnessEnabled, loudnessBoostDb: loudnessBoostDb, format: mixerFormat)
    }

    // MARK: AudioPlayer.Delegate (unspecified thread)

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingStarted decoder: any PCMDecoding) {
        onEvent(.renderingStarted)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: any PCMDecoding) {
        onEvent(.renderingComplete)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        onEvent(.playbackStateChanged(isPlaying: playbackState == .playing))
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        onEvent(.endOfAudio)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: any PCMDecoding, error: any Error, framesRendered: AVAudioFramePosition) {
        onEvent(.decodingAborted(message: error.localizedDescription))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: any Error) {
        onEvent(.asynchronousError(message: error.localizedDescription))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, didSeek decoder: any PCMDecoding, toFrame frame: AVAudioFramePosition) {
        onEvent(.seekCompleted(frame: frame))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, audioEngineConfigurationChange userInfo: [AnyHashable: Any]?) {
        // The player rebuilt the graph; reconnect our chain and re-install the tap.
        player.modifyProcessingGraph { [weak self] engine in
            self?.reconnectChain(engine: engine, format: engine.mainMixerNode.outputFormat(forBus: 0))
        }
        onEvent(.configurationChange)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        reconnectChain(engine: engine, format: format)
        return timePitch ?? player.mainMixerNode
    }

    #if !os(macOS)
    func audioPlayer(_ audioPlayer: AudioPlayer, audioSessionInterruption userInfo: [AnyHashable: Any]?) {
        onEvent(.asynchronousError(message: "Audio session interruption"))
    }
    #endif
}
