import AVFAudio
import Accelerate
import Combine

/// Render-thread ring buffer fed by an `AVAudioNode` tap. Monitors read snapshots from any thread.
public final class AudioTapBuffer: @unchecked Sendable {
    public static let capacity = 16384
    private var ring = [Float](repeating: 0, count: AudioTapBuffer.capacity)
    private var writeIndex = 0
    private var droppedCount = 0
    private let lock = NSLock()
    /// Frames per second of the tapped stream (used to map spectrum bins to frequencies).
    public private(set) var sampleRate: Double = 44_100

    public init() {}

    /// Tap callback (render thread): copies mono-mixed samples into the ring. Never allocates.
    public func push(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        lock.lock()
        sampleRate = buffer.format.sampleRate
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels { sum += channelData[channel][frame] }
            ring[writeIndex] = sum / Float(max(1, channels))
            writeIndex = (writeIndex + 1) & (AudioTapBuffer.capacity - 1)
        }
        lock.unlock()
    }

    /// The most recent `count` samples, oldest first.
    public func latest(_ count: Int) -> [Float] {
        let amount = min(count, AudioTapBuffer.capacity)
        lock.lock()
        var result = [Float](repeating: 0, count: amount)
        for index in 0..<amount {
            result[index] = ring[(writeIndex - amount + index + AudioTapBuffer.capacity) & (AudioTapBuffer.capacity - 1)]
        }
        let rate = sampleRate
        lock.unlock()
        _ = rate
        return result
    }
}

/// Peak/RMS levels and an FFT spectrum published to SwiftUI at a configurable rate (default ~30 fps).
/// Attach to an `AVAudioNode` inside the player's `modifyProcessingGraph` block.
@MainActor
public final class AudioLevelMonitor: ObservableObject {
    /// Per-channel smoothed peak levels in dB (left, right), -60 ... 0.
    @Published public private(set) var levels: [Float] = [-60, -60]
    /// Spectrum magnitudes in dB, one value per bin (~512 bins from a 2048-point FFT).
    @Published public private(set) var spectrum: [Float] = []
    @Published public private(set) var spectrumFrequencies: [Float] = []
    /// `true` while a tap is installed.
    @Published public private(set) var isActive = false

    /// Frames per second of published updates (clamped to 10...60).
    public var framesPerSecond: Double = 30 {
        didSet { restartTimerIfNeeded() }
    }

    public let tapBuffer = AudioTapBuffer()
    private let fftSize = 2048
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var timer: Timer?
    private weak var tappedNode: AVAudioNode?
    private var smoothLevels: [Float] = [-60, -60]

    public init() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Installs (or moves) the tap. Call inside `modifyProcessingGraph`; safe on any thread.
    nonisolated func attach(to node: AVAudioNode) {
        let buffer = tapBuffer
        Task { @MainActor in
            self.installTap(on: node, buffer: buffer)
        }
    }

    private func installTap(on node: AVAudioNode, buffer: AudioTapBuffer) {
        tappedNode?.removeTap(onBus: 0)
        tappedNode = node
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { pcmBuffer, _ in
            buffer.push(pcmBuffer)
        }
        isActive = true
        startTimer()
    }

    /// Removes the tap and stops publishing.
    public func detach() {
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        isActive = false
        timer?.invalidate()
        timer = nil
        levels = [-60, -60]
        spectrum = []
    }

    /// Starts or stops publishing from `tapBuffer` when something else (the playback engine) owns the tap.
    /// Stopping resets the meters so a paused player does not show frozen levels.
    public func setPublishing(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            isActive = true
            startTimer()
        } else {
            guard timer != nil else { return }
            timer?.invalidate()
            timer = nil
            isActive = false
            smoothLevels = [-60, -60]
            levels = smoothLevels
            spectrum = []
        }
    }

    private func restartTimerIfNeeded() {
        guard timer != nil else { return }
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = 1 / min(60, max(10, framesPerSecond))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func publish() {
        let samples = tapBuffer.latest(fftSize)
        publishLevels(samples)
        publishSpectrum(samples)
    }

    private func publishLevels(_ samples: [Float]) {
        guard !samples.isEmpty else {
            smoothLevels = smoothLevels.map { max(-60, $0 - 6) }
            levels = smoothLevels
            return
        }
        var peak: Float = 0
        var sumSquares: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        let rms = sqrt(sumSquares / Float(samples.count))
        let peakDb = max(-60, 20 * log10(max(peak, 1e-7)))
        _ = rms
        for index in 0..<smoothLevels.count {
            smoothLevels[index] = max(peakDb, smoothLevels[index] - 4)
        }
        levels = smoothLevels
    }

    private func publishSpectrum(_ samples: [Float]) {
        guard let fftSetup, samples.count == fftSize else { return }
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                let binCount = 512
                let step = (fftSize / 2) / binCount
                var bins = [Float](repeating: -80, count: binCount)
                for bin in 0..<binCount {
                    var peak: Float = 0
                    vDSP_maxv(Array(magnitudes[(bin * step)..<((bin + 1) * step)]), 1, &peak, vDSP_Length(step))
                    bins[bin] = max(-80, 10 * log10(max(peak, 1e-10)) - 10)
                }
                spectrum = bins
                if spectrumFrequencies.count != binCount {
                    let rate = Float(tapBuffer.sampleRate)
                    spectrumFrequencies = (0..<binCount).map { Float($0 * step) * rate / Float(self.fftSize) }
                }
            }
        }
    }
}
