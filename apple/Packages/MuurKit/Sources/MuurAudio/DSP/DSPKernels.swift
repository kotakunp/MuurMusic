import Foundation
import MuurCore

/// Real-time audio processors for the `muur-dsp` chain. All processors run on deinterleaved
/// Float32 buffers on the audio render thread; they are created once per `(chain, format)` change
/// and swapped atomically by `DSPAudioUnit`, so they never allocate or lock while processing.
///
/// Buffers handed to `process` are one `UnsafeMutablePointer<Float>` per channel.
public enum DSPMath {
    @inline(__always)
    public static func softTanh(_ x: Double) -> Double {
        guard abs(x) < 18 else { return x > 0 ? 1 : -1 }
        let e = exp(2 * x)
        return (e - 1) / (e + 1)
    }
}

public class DSPProcessor {
    public let channelCount: Int
    public let sampleRate: Double

    public init(channelCount: Int, sampleRate: Double) {
        self.channelCount = max(1, channelCount)
        self.sampleRate = max(8_000, sampleRate)
    }

    public func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {}
    public func reset() {}
}

// MARK: - Biquad

/// RBJ audio-cookbook biquad used by all filter nodes.
public final class BiquadKernel {
    public enum Kind: Sendable {
        case lowPass, highPass, bandPass, notch, peaking, lowShelf, highShelf
    }

    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public init(kind: Kind, frequencyHz: Double, q: Double, gainDb: Double, sampleRate: Double) {
        configure(kind: kind, frequencyHz: frequencyHz, q: q, gainDb: gainDb, sampleRate: sampleRate)
    }

    public func configure(kind: Kind, frequencyHz: Double, q: Double, gainDb: Double, sampleRate: Double) {
        let clampedFrequency = min(max(frequencyHz, 10), sampleRate * 0.45)
        let w0 = 2 * Double.pi * clampedFrequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2 * max(0.05, q))
        let a = pow(10, gainDb / 40)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .lowPass:
            b0 = (1 - cosw0) / 2; b1 = 1 - cosw0; b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw0; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw0) / 2; b1 = -(1 + cosw0); b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw0; a2 = 1 - alpha
        case .bandPass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cosw0; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw0; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw0; a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cosw0; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw0; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw0 + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw0)
            b2 = a * ((a + 1) - (a - 1) * cosw0 - s)
            a0 = (a + 1) + (a - 1) * cosw0 + s
            a1 = -2 * ((a - 1) + (a + 1) * cosw0)
            a2 = (a + 1) + (a - 1) * cosw0 - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw0 + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw0)
            b2 = a * ((a + 1) + (a - 1) * cosw0 - s)
            a0 = (a + 1) - (a - 1) * cosw0 + s
            a1 = 2 * ((a - 1) - (a + 1) * cosw0)
            a2 = (a + 1) - (a - 1) * cosw0 - s
        }
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    @inline(__always)
    public func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    public func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
}

public final class BiquadProcessor: DSPProcessor {
    private var kernels: [BiquadKernel]
    private let kind: BiquadKernel.Kind
    private let frequencyHz: Double
    private let q: Double
    private let gainDb: Double

    public init(kind: BiquadKernel.Kind, frequencyHz: Double, q: Double, gainDb: Double,
                channelCount: Int, sampleRate: Double) {
        self.kind = kind
        self.frequencyHz = frequencyHz
        self.q = q
        self.gainDb = gainDb
        self.kernels = (0..<max(1, channelCount)).map { _ in
            BiquadKernel(kind: kind, frequencyHz: frequencyHz, q: q, gainDb: gainDb, sampleRate: sampleRate)
        }
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in 0..<min(buffers.count, kernels.count) {
            let kernel = kernels[channel]
            let buffer = buffers[channel]
            for frame in 0..<frameCount {
                buffer[frame] = Float(kernel.process(Double(buffer[frame])))
            }
        }
    }

    public override func reset() { kernels.forEach { $0.reset() } }
}

// MARK: - Gain

public final class GainProcessor: DSPProcessor {
    private let linear: Float
    public init(gainDb: Double, channelCount: Int, sampleRate: Double) {
        self.linear = Float(pow(10, gainDb / 20))
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard linear != 1 else { return }
        for buffer in buffers {
            for frame in 0..<frameCount { buffer[frame] *= linear }
        }
    }
}

// MARK: - Soft clip & distortion

public final class SoftClipProcessor: DSPProcessor {
    private let drive: Double
    private let normalization: Double
    public init(drive: Double, channelCount: Int, sampleRate: Double) {
        self.drive = 1 + drive * 15
        self.normalization = DSPMath.softTanh(1 + drive * 15)
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let k = drive, norm = normalization
        for buffer in buffers {
            for frame in 0..<frameCount {
                buffer[frame] = Float(DSPMath.softTanh(Double(buffer[frame]) * k) / norm)
            }
        }
    }
}

public final class DistortionProcessor: DSPProcessor {
    private let drive: Double
    private let toneAlpha: [Double]
    private var toneState: [Double]
    private let mix: Double
    public init(drive: Double, tone: Double, mix: Double, channelCount: Int, sampleRate: Double) {
        self.drive = 1 + drive * 40
        let cutoff = 800 + tone * 9000
        let rc = 1 / (2 * Double.pi * cutoff)
        let dt = 1 / sampleRate
        self.toneAlpha = (0..<max(1, channelCount)).map { _ in dt / (rc + dt) }
        self.toneState = [Double](repeating: 0, count: max(1, channelCount))
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let k = drive, mixAmount = mix, dry = 1 - mix
        for channel in 0..<min(buffers.count, toneState.count) {
            let buffer = buffers[channel]
            let alpha = toneAlpha[channel]
            var state = toneState[channel]
            for frame in 0..<frameCount {
                let x = Double(buffer[frame])
                let shaped = 2 / Double.pi * atan(x * k)
                state += alpha * (shaped - state)
                buffer[frame] = Float(dry * x + mixAmount * state)
            }
            toneState[channel] = state
        }
    }
    public override func reset() { toneState = [Double](repeating: 0, count: toneState.count) }
}

// MARK: - Bit crusher

public final class BitCrusherProcessor: DSPProcessor {
    private let levels: Double
    private let hold: Int
    private var counters: [Int]
    private var held: [Float]
    public init(bits: Double, downsample: Double, channelCount: Int, sampleRate: Double) {
        self.levels = pow(2, max(1, bits) - 1)
        self.hold = max(1, Int(downsample))
        let count = max(1, channelCount)
        self.counters = [Int](repeating: 0, count: count)
        self.held = [Float](repeating: 0, count: count)
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in 0..<min(buffers.count, counters.count) {
            let buffer = buffers[channel]
            var counter = counters[channel]
            var current = held[channel]
            for frame in 0..<frameCount {
                if counter == 0 {
                    current = Float((Double(buffer[frame]) * levels).rounded() / levels)
                    counter = hold - 1
                } else {
                    counter -= 1
                }
                buffer[frame] = current
            }
            counters[channel] = counter
            held[channel] = current
        }
    }
    public override func reset() {
        counters = [Int](repeating: 0, count: counters.count)
        held = [Float](repeating: 0, count: held.count)
    }
}

// MARK: - LFO based modulation

public final class TremoloProcessor: DSPProcessor {
    private let rate: Double
    private let depth: Double
    private var phase: Double = 0
    public init(rateHz: Double, depth: Double, channelCount: Int, sampleRate: Double) {
        self.rate = rateHz
        self.depth = depth
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let step = 2 * Double.pi * rate / sampleRate
        let amount = depth * 0.5
        var currentPhase = phase
        for frame in 0..<frameCount {
            let gain = Float(1 - amount * (1 + sin(currentPhase)))
            for buffer in buffers { buffer[frame] *= gain }
            currentPhase += step
            if currentPhase > 2 * Double.pi { currentPhase -= 2 * Double.pi }
        }
        phase = currentPhase
    }
    public override func reset() { phase = 0 }
}

public final class RingModulatorProcessor: DSPProcessor {
    private let frequency: Double
    private let mix: Double
    private var phase: Double = 0
    public init(frequencyHz: Double, mix: Double, channelCount: Int, sampleRate: Double) {
        self.frequency = frequencyHz
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let step = 2 * Double.pi * frequency / sampleRate
        let wet = mix, dryAmount = 1 - mix
        var currentPhase = phase
        for frame in 0..<frameCount {
            let carrier = sin(currentPhase)
            for buffer in buffers {
                let x = Double(buffer[frame])
                buffer[frame] = Float(dryAmount * x + wet * x * carrier)
            }
            currentPhase += step
            if currentPhase > 2 * Double.pi { currentPhase -= 2 * Double.pi }
        }
        phase = currentPhase
    }
    public override func reset() { phase = 0 }
}

// MARK: - Delay / chorus / flanger

/// Circular delay line, one per channel.
final class DelayLine {
    private var buffer: [Float]
    private var index = 0
    let capacity: Int

    init(delaySeconds: Double, sampleRate: Double) {
        capacity = max(2, Int(delaySeconds * sampleRate) + 1)
        buffer = [Float](repeating: 0, count: capacity)
    }

    @inline(__always) func read(offset: Int) -> Float {
        buffer[(index - offset + capacity * 2) % capacity]
    }

    /// Fractional read with linear interpolation.
    @inline(__always) func read(fractionalOffset: Double) -> Float {
        let whole = Int(fractionalOffset)
        let fraction = Float(fractionalOffset - Double(whole))
        let a = read(offset: whole)
        let b = read(offset: whole + 1)
        return a + (b - a) * fraction
    }

    @inline(__always) func write(_ value: Float) {
        buffer[index] = value
        index = (index + 1) % capacity
    }

    func reset() { buffer = [Float](repeating: 0, count: capacity); index = 0 }
}

public final class DelayProcessor: DSPProcessor {
    private var lines: [DelayLine]
    private let offset: Int
    private let feedback: Float
    private let mix: Double
    public init(timeMs: Double, feedback: Double, mix: Double, channelCount: Int, sampleRate: Double) {
        let seconds = timeMs / 1000
        self.lines = (0..<max(1, channelCount)).map { _ in DelayLine(delaySeconds: seconds, sampleRate: sampleRate) }
        self.offset = max(1, Int(seconds * sampleRate))
        self.feedback = Float(feedback)
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let wet = Float(mix), dryAmount = Float(1 - mix), fb = feedback, off = offset
        for channel in 0..<min(buffers.count, lines.count) {
            let buffer = buffers[channel]
            let line = lines[channel]
            for frame in 0..<frameCount {
                let x = buffer[frame]
                let delayed = line.read(offset: off)
                line.write(x + delayed * fb)
                buffer[frame] = dryAmount * x + wet * delayed
            }
        }
    }
    public override func reset() { lines.forEach { $0.reset() } }
}

/// Shared implementation for chorus and flanger: an LFO-modulated delay with feedback and mix.
public final class ModulatedDelayProcessor: DSPProcessor {
    public enum Flavor { case chorus, flanger }
    private var lines: [DelayLine]
    private let baseOffset: Double
    private let depthSamples: Double
    private let rate: Double
    private let feedback: Float
    private let mix: Double
    private var phase: Double = 0

    public init(flavor: Flavor, rateHz: Double, depth: Double, feedback: Double, mix: Double,
                channelCount: Int, sampleRate: Double) {
        let baseMs: Double = flavor == .chorus ? 18 : 4
        let depthMs: Double = flavor == .chorus ? 7 : 3
        self.baseOffset = baseMs / 1000 * sampleRate
        self.depthSamples = depth * depthMs / 1000 * sampleRate
        self.lines = (0..<max(1, channelCount)).map { _ in
            DelayLine(delaySeconds: (baseMs + depthMs) / 1000 + 0.01, sampleRate: sampleRate)
        }
        self.rate = rateHz
        self.feedback = Float(feedback)
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let step = 2 * Double.pi * rate / sampleRate
        let wet = Float(mix), dryAmount = Float(1 - mix)
        var currentPhase = phase
        for frame in 0..<frameCount {
            let offset = baseOffset + depthSamples * (0.5 + 0.5 * sin(currentPhase))
            currentPhase += step
            if currentPhase > 2 * Double.pi { currentPhase -= 2 * Double.pi }
            for channel in 0..<min(buffers.count, lines.count) {
                let line = lines[channel]
                let x = buffers[channel][frame]
                let delayed = line.read(fractionalOffset: offset)
                line.write(x + delayed * feedback)
                buffers[channel][frame] = dryAmount * x + wet * delayed
            }
        }
        phase = currentPhase
    }

    public override func reset() { lines.forEach { $0.reset() }; phase = 0 }
}

// MARK: - Phaser & auto-wah

/// First-order allpass stage.
final class AllpassStage {
    private var a: Double = 0.5
    private var x1 = 0.0, y1 = 0.0
    func setFrequency(_ hz: Double, sampleRate: Double) {
        let t = tan(Double.pi * min(hz, sampleRate * 0.45) / sampleRate)
        a = (t - 1) / (t + 1)
    }
    @inline(__always) func process(_ x: Double) -> Double {
        let y = -a * x + x1 + a * y1
        x1 = x; y1 = y
        return y
    }
    func reset() { x1 = 0; y1 = 0 }
}

public final class PhaserProcessor: DSPProcessor {
    private var stages: [[AllpassStage]]
    private let rate: Double
    private let depth: Double
    private let feedback: Float
    private let mix: Double
    private var phase: Double = 0
    private var feedbackState: [Float]

    public init(rateHz: Double, depth: Double, stageCount: Int, feedback: Double, mix: Double,
                channelCount: Int, sampleRate: Double) {
        let channels = max(1, channelCount)
        let count = max(2, min(12, stageCount))
        self.stages = (0..<channels).map { _ in (0..<count).map { _ in AllpassStage() } }
        self.rate = rateHz
        self.depth = depth
        self.feedback = Float(feedback)
        self.mix = mix
        self.feedbackState = [Float](repeating: 0, count: channels)
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let step = 2 * Double.pi * rate / sampleRate
        let wet = mix, dryAmount = 1 - mix
        var currentPhase = phase
        for frame in 0..<frameCount {
            let sweep = 0.5 + 0.5 * sin(currentPhase)
            currentPhase += step
            if currentPhase > 2 * Double.pi { currentPhase -= 2 * Double.pi }
            let frequency = 200 * pow(20, sweep * depth) // 200 Hz ... 4 kHz
            for channel in 0..<min(buffers.count, stages.count) {
                var y = Double(buffers[channel][frame]) + Double(feedbackState[channel]) * Double(feedback)
                for stage in stages[channel] {
                    stage.setFrequency(frequency, sampleRate: sampleRate)
                    y = stage.process(y)
                }
                feedbackState[channel] = Float(y)
                buffers[channel][frame] = Float(dryAmount * Double(buffers[channel][frame]) + wet * y)
            }
        }
        phase = currentPhase
    }

    public override func reset() {
        stages.forEach { $0.forEach { $0.reset() } }
        phase = 0
        feedbackState = [Float](repeating: 0, count: feedbackState.count)
    }
}

public final class AutoWahProcessor: DSPProcessor {
    private var envelope: [Double]
    private var filters: [BiquadKernel]
    private let sensitivity: Double
    private let minHz: Double
    private let maxHz: Double
    private let q: Double
    private let mix: Double

    public init(sensitivity: Double, minHz: Double, maxHz: Double, q: Double, mix: Double,
                channelCount: Int, sampleRate: Double) {
        let channels = max(1, channelCount)
        self.envelope = [Double](repeating: 0, count: channels)
        self.filters = (0..<channels).map { _ in BiquadKernel(kind: .bandPass, frequencyHz: minHz, q: q, gainDb: 0, sampleRate: sampleRate) }
        self.sensitivity = sensitivity
        self.minHz = minHz
        self.maxHz = maxHz
        self.q = q
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let release = exp(-1 / (0.05 * sampleRate))
        let attack = exp(-1 / (0.002 * sampleRate))
        let wet = mix, dryAmount = 1 - mix
        var frame = 0
        while frame < frameCount {
            let blockEnd = min(frame + 32, frameCount)
            for channel in 0..<min(buffers.count, filters.count) {
                let buffer = buffers[channel]
                var env = envelope[channel]
                let filter = filters[channel]
                for index in frame..<blockEnd {
                    let x = Double(buffer[index])
                    let magnitude = abs(x)
                    env = magnitude > env ? attack * env + (1 - attack) * magnitude : release * env
                    let filtered = filter.process(x)
                    buffer[index] = Float(dryAmount * x + wet * filtered)
                }
                envelope[channel] = env
            }
            let peak = envelope.prefix(min(buffers.count, envelope.count)).max() ?? 0
            let target = minHz + (maxHz - minHz) * min(1, peak * (0.2 + sensitivity * 2))
            for filter in filters {
                filter.configure(kind: .bandPass, frequencyHz: target, q: q, gainDb: 0, sampleRate: sampleRate)
            }
            frame = blockEnd
        }
    }

    public override func reset() {
        envelope = [Double](repeating: 0, count: envelope.count)
        filters.forEach { $0.reset() }
    }
}

// MARK: - Stereo tools

public final class StereoWidthProcessor: DSPProcessor {
    private let width: Double
    public init(width: Double, channelCount: Int, sampleRate: Double) {
        self.width = width
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard buffers.count >= 2 else { return }
        let left = buffers[0], right = buffers[1]
        let sideGain = Float(width)
        for frame in 0..<frameCount {
            let mid = (left[frame] + right[frame]) * 0.5
            let side = (left[frame] - right[frame]) * 0.5 * sideGain
            left[frame] = mid + side
            right[frame] = mid - side
        }
    }
}

/// Headphone crossfeed: blends a low-passed copy of the opposite channel.
public final class CrossfeedProcessor: DSPProcessor {
    private let amount: Double
    private var lowState: [Double]
    private let alpha: Double
    public init(amount: Double, channelCount: Int, sampleRate: Double) {
        self.amount = amount * 0.35
        let rc = 1 / (2 * Double.pi * 700)
        let dt = 1 / sampleRate
        self.alpha = dt / (rc + dt)
        self.lowState = [Double](repeating: 0, count: max(2, channelCount))
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard buffers.count >= 2, amount > 0 else { return }
        let left = buffers[0], right = buffers[1]
        let a = alpha, level = amount
        var lowL = lowState[0], lowR = lowState[1]
        for frame in 0..<frameCount {
            let l = Double(left[frame])
            let r = Double(right[frame])
            lowL += a * (l - lowL)
            lowR += a * (r - lowR)
            left[frame] = Float(l + lowR * level)
            right[frame] = Float(r + lowL * level)
        }
        lowState[0] = lowL; lowState[1] = lowR
    }
    public override func reset() { lowState = [Double](repeating: 0, count: lowState.count) }
}

// MARK: - Reverb (Schroeder: 4 combs + 2 allpasses per channel)

public final class ReverbProcessor: DSPProcessor {
    private struct CombTuning { static let delays: [Double] = [0.0297, 0.0371, 0.0411, 0.0437] }
    private struct AllpassTuning { static let delays: [Double] = [0.005, 0.0017] }

    private var combBuffers: [[DelayLine]]
    private var combState: [[Double]]
    private var allpassBuffers: [[DelayLine]]
    private let roomSize: Double
    private let damping: Double
    private let mix: Double

    public init(roomSize: Double, damping: Double, mix: Double, channelCount: Int, sampleRate: Double) {
        let channels = max(1, channelCount)
        self.combBuffers = (0..<channels).map { _ in CombTuning.delays.map { DelayLine(delaySeconds: $0 * 2, sampleRate: sampleRate) } }
        self.combState = (0..<channels).map { _ in [Double](repeating: 0, count: CombTuning.delays.count) }
        self.allpassBuffers = (0..<channels).map { _ in AllpassTuning.delays.map { DelayLine(delaySeconds: $0 * 2, sampleRate: sampleRate) } }
        self.roomSize = roomSize
        self.damping = damping
        self.mix = mix
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let feedbackBase = 0.7 + roomSize * 0.28
        let damp = damping * 0.4
        let wet = Float(mix), dryAmount = Float(1 - mix)
        for channel in 0..<min(buffers.count, combBuffers.count) {
            let buffer = buffers[channel]
            for frame in 0..<frameCount {
                let x = Double(buffer[frame])
                var wetSample = 0.0
                for comb in 0..<combBuffers[channel].count {
                    let line = combBuffers[channel][comb]
                    let delayed = Double(line.read(offset: line.capacity / 2))
                    var state = combState[channel][comb]
                    state = delayed * (1 - damp) + state * damp
                    combState[channel][comb] = state
                    line.write(Float(x + state * feedbackBase))
                    wetSample += delayed
                }
                for allpass in allpassBuffers[channel] {
                    let delayed = Double(allpass.read(offset: allpass.capacity / 2))
                    let y = -wetSample + delayed
                    allpass.write(Float(wetSample + delayed * 0.5))
                    wetSample = y
                }
                buffer[frame] = dryAmount * Float(x) + wet * Float(wetSample * 0.25)
            }
        }
    }

    public override func reset() {
        combBuffers.forEach { $0.forEach { $0.reset() } }
        allpassBuffers.forEach { $0.forEach { $0.reset() } }
        combState = combState.map { $0.map { _ in 0 } }
    }
}

// MARK: - Dynamics

public final class CompressorProcessor: DSPProcessor {
    private let thresholdDb: Double
    private let ratio: Double
    private let attackCoef: Double
    private let releaseCoef: Double
    private let makeup: Float
    private var envelope = 0.0
    private var gain = 1.0

    public init(thresholdDb: Double, ratio: Double, attackMs: Double, releaseMs: Double, makeupDb: Double,
                channelCount: Int, sampleRate: Double) {
        self.thresholdDb = thresholdDb
        self.ratio = max(1, ratio)
        self.attackCoef = exp(-1 / (max(0.1, attackMs) / 1000 * sampleRate))
        self.releaseCoef = exp(-1 / (max(5, releaseMs) / 1000 * sampleRate))
        self.makeup = Float(pow(10, makeupDb / 20))
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        var env = envelope
        var currentGain = gain
        for frame in 0..<frameCount {
            var peak = 0.0
            for buffer in buffers { peak = max(peak, abs(Double(buffer[frame]))) }
            env = peak > env ? attackCoef * env + (1 - attackCoef) * peak : releaseCoef * env
            let levelDb = 20 * log10(max(env, 1e-7))
            let overDb = levelDb - thresholdDb
            let targetGainDb = overDb > 0 ? -(overDb - overDb / ratio) : 0
            let targetGain = pow(10, targetGainDb / 20)
            currentGain = targetGain < currentGain
                ? attackCoef * currentGain + (1 - attackCoef) * targetGain
                : releaseCoef * currentGain + (1 - releaseCoef) * targetGain
            let total = Float(currentGain) * makeup
            for buffer in buffers { buffer[frame] *= total }
        }
        envelope = env
        gain = currentGain
    }

    public override func reset() { envelope = 0; gain = 1 }
}

/// Safety peak limiter placed at the end of the chain (and after loudness boost).
public final class DSPLimiter: DSPProcessor {
    private let ceiling: Double
    private let releaseCoef: Double
    private var envelope = 0.0
    private var gain = 1.0

    public init(ceiling: Double = 0.98, releaseMs: Double = 120, channelCount: Int, sampleRate: Double) {
        self.ceiling = ceiling
        self.releaseCoef = exp(-1 / (releaseMs / 1000 * sampleRate))
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }

    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        var env = envelope
        var currentGain = gain
        let attackCoef = exp(-1 / (0.001 * sampleRate))
        for frame in 0..<frameCount {
            var peak = 0.0
            for buffer in buffers { peak = max(peak, abs(Double(buffer[frame]))) }
            env = max(peak, env * releaseCoef)
            let target = env > ceiling ? ceiling / env : 1
            currentGain = target < currentGain
                ? attackCoef * currentGain + (1 - attackCoef) * target
                : releaseCoef * currentGain + (1 - releaseCoef) * target
            let applied = Float(currentGain)
            for buffer in buffers { buffer[frame] *= applied }
        }
        envelope = env
        gain = currentGain
    }

    public override func reset() { envelope = 0; gain = 1 }
}

/// Loudness contour (Fletcher-Munson inspired low/high boost) used by the "Loudness" feature.
public final class LoudnessContourProcessor: DSPProcessor {
    private var lowShelf: [BiquadKernel]
    private var highShelf: [BiquadKernel]
    public init(boostDb: Double, channelCount: Int, sampleRate: Double) {
        let channels = max(1, channelCount)
        lowShelf = (0..<channels).map { _ in BiquadKernel(kind: .lowShelf, frequencyHz: 100, q: 0.707, gainDb: boostDb * 0.8, sampleRate: sampleRate) }
        highShelf = (0..<channels).map { _ in BiquadKernel(kind: .highShelf, frequencyHz: 8_000, q: 0.707, gainDb: boostDb * 0.5, sampleRate: sampleRate) }
        super.init(channelCount: channelCount, sampleRate: sampleRate)
    }
    public override func process(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in 0..<min(buffers.count, lowShelf.count) {
            let low = lowShelf[channel]
            let high = highShelf[channel]
            let buffer = buffers[channel]
            for frame in 0..<frameCount {
                buffer[frame] = Float(high.process(low.process(Double(buffer[frame]))))
            }
        }
    }
    public override func reset() {
        lowShelf.forEach { $0.reset() }
        highShelf.forEach { $0.reset() }
    }
}

// MARK: - Program compilation

/// An immutable, render-ready DSP program: pre-gain (ReplayGain / EQ preamp / crossfade safety),
/// the node chain, optional loudness contour and a final limiter. Swapped atomically by `DSPAudioUnit`.
public final class DSPProgram: @unchecked Sendable {
    public let preGainLinear: Float
    public let processors: [DSPProcessor]
    public let limiter: DSPLimiter
    public let sampleRate: Double
    /// Master fade state (crossfade / pause / sleep-timer ramps).
    public let fadeState = DSPFadeState()

    public init(chain: DSPChain?, preGainDb: Double, loudnessBoostDb: Double?, channelCount: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        preGainLinear = Float(pow(10, preGainDb / 20))
        var built: [DSPProcessor] = []
        for node in chain?.nodes ?? [] where node.enabled {
            guard let type = node.nodeType else { continue }
            let channels = channelCount
            let rate = sampleRate
            switch type {
            case .lowPass: built.append(BiquadProcessor(kind: .lowPass, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: 0, channelCount: channels, sampleRate: rate))
            case .highPass: built.append(BiquadProcessor(kind: .highPass, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: 0, channelCount: channels, sampleRate: rate))
            case .bandPass: built.append(BiquadProcessor(kind: .bandPass, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: 0, channelCount: channels, sampleRate: rate))
            case .notch: built.append(BiquadProcessor(kind: .notch, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: 0, channelCount: channels, sampleRate: rate))
            case .peaking: built.append(BiquadProcessor(kind: .peaking, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: node.clampedValue("gainDb"), channelCount: channels, sampleRate: rate))
            case .lowShelf: built.append(BiquadProcessor(kind: .lowShelf, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: node.clampedValue("gainDb"), channelCount: channels, sampleRate: rate))
            case .highShelf: built.append(BiquadProcessor(kind: .highShelf, frequencyHz: node.clampedValue("frequencyHz"), q: node.clampedValue("q"), gainDb: node.clampedValue("gainDb"), channelCount: channels, sampleRate: rate))
            case .gain: built.append(GainProcessor(gainDb: node.clampedValue("gainDb"), channelCount: channels, sampleRate: rate))
            case .softClip: built.append(SoftClipProcessor(drive: node.clampedValue("drive"), channelCount: channels, sampleRate: rate))
            case .bitCrusher: built.append(BitCrusherProcessor(bits: node.clampedValue("bits"), downsample: node.clampedValue("downsample"), channelCount: channels, sampleRate: rate))
            case .tremolo: built.append(TremoloProcessor(rateHz: node.clampedValue("rateHz"), depth: node.clampedValue("depth"), channelCount: channels, sampleRate: rate))
            case .delay: built.append(DelayProcessor(timeMs: node.clampedValue("timeMs"), feedback: node.clampedValue("feedback"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .ringModulator: built.append(RingModulatorProcessor(frequencyHz: node.clampedValue("frequencyHz"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .stereoWidth: built.append(StereoWidthProcessor(width: node.clampedValue("width"), channelCount: channels, sampleRate: rate))
            case .reverb: built.append(ReverbProcessor(roomSize: node.clampedValue("roomSize"), damping: node.clampedValue("damping"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .chorus: built.append(ModulatedDelayProcessor(flavor: .chorus, rateHz: node.clampedValue("rateHz"), depth: node.clampedValue("depth"), feedback: node.clampedValue("feedback"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .flanger: built.append(ModulatedDelayProcessor(flavor: .flanger, rateHz: node.clampedValue("rateHz"), depth: node.clampedValue("depth"), feedback: node.clampedValue("feedback"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .phaser: built.append(PhaserProcessor(rateHz: node.clampedValue("rateHz"), depth: node.clampedValue("depth"), stageCount: Int(node.clampedValue("stages")), feedback: node.clampedValue("feedback"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .autoWah: built.append(AutoWahProcessor(sensitivity: node.clampedValue("sensitivity"), minHz: node.clampedValue("minHz"), maxHz: node.clampedValue("maxHz"), q: node.clampedValue("q"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .distortion: built.append(DistortionProcessor(drive: node.clampedValue("drive"), tone: node.clampedValue("tone"), mix: node.clampedValue("mix"), channelCount: channels, sampleRate: rate))
            case .compressor: built.append(CompressorProcessor(thresholdDb: node.clampedValue("thresholdDb"), ratio: node.clampedValue("ratio"), attackMs: node.clampedValue("attackMs"), releaseMs: node.clampedValue("releaseMs"), makeupDb: node.clampedValue("makeupDb"), channelCount: channels, sampleRate: rate))
            case .crossfeed: built.append(CrossfeedProcessor(amount: node.clampedValue("amount"), channelCount: channels, sampleRate: rate))
            }
        }
        if let loudnessBoostDb, loudnessBoostDb > 0 {
            built.append(LoudnessContourProcessor(boostDb: loudnessBoostDb, channelCount: channelCount, sampleRate: sampleRate))
        }
        processors = built
        limiter = DSPLimiter(channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Processes one render cycle of deinterleaved Float32 buffers in place.
    public func render(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let fade = fadeState.render(frameCount: frameCount, sampleRate: sampleRate)
        let preGain = preGainLinear
        if preGain != 1 || fade != nil {
            for buffer in buffers {
                if let fade {
                    for frame in 0..<frameCount { buffer[frame] *= preGain * fade[frame] }
                } else {
                    for frame in 0..<frameCount { buffer[frame] *= preGain }
                }
            }
        }
        for processor in processors { processor.process(buffers, frameCount: frameCount) }
        limiter.process(buffers, frameCount: frameCount)
    }
}

/// Master fade (crossfade / sleep fade / pause ramp). Lives outside the program so program swaps
/// (parameter changes) do not reset a running fade.
public final class DSPFadeState: @unchecked Sendable {
    private var current: Float = 1
    private var target: Float = 1
    private var remainingSeconds: Double = 0
    private var scratch: [Float] = []

    public init() {}

    /// Sets the fade target; the render loop ramps toward it over `rampSeconds`.
    public func setTarget(_ value: Float, rampSeconds: Double = 0.05) {
        target = min(max(value, 0), 1)
        remainingSeconds = max(0, rampSeconds)
    }

    /// Snaps to a value without ramping.
    public func snap(to value: Float) { current = min(max(value, 0), 1); target = current; remainingSeconds = 0 }

    public var targetValue: Float { target }
    public var currentValue: Float { current }
    public var isFading: Bool { current != target }

    /// Returns per-frame gains when a fade (or a non-unity hold) is active, otherwise nil.
    func render(frameCount: Int, sampleRate: Double) -> [Float]? {
        guard current != target else { return current < 1 ? [Float](repeating: current, count: frameCount) : nil }
        if scratch.count < frameCount { scratch = [Float](repeating: 1, count: frameCount) }
        let rampFrames = max(1, Int(remainingSeconds * sampleRate))
        let step = (target - current) / Float(rampFrames)
        var value = current
        for frame in 0..<frameCount {
            value += step
            scratch[frame] = value
        }
        current = value
        remainingSeconds -= Double(frameCount) / sampleRate
        if remainingSeconds <= 0 || (step > 0 && current >= target) || (step < 0 && current <= target) {
            current = target
            remainingSeconds = 0
        }
        return Array(scratch[0..<frameCount])
    }
}

/// Builds a `DSPProgram` from settings values.
public enum DSPProgramBuilder {
    public static func program(chainJSON: String, dspEnabled: Bool, preGainDb: Double,
                               loudnessEnabled: Bool, loudnessBoostDb: Double,
                               channelCount: Int, sampleRate: Double) -> DSPProgram {
        let chain = dspEnabled ? DSPChain.decode(json: chainJSON) : nil
        return DSPProgram(chain: chain, preGainDb: preGainDb,
                          loudnessBoostDb: loudnessEnabled ? loudnessBoostDb : nil,
                          channelCount: channelCount, sampleRate: sampleRate)
    }
}
