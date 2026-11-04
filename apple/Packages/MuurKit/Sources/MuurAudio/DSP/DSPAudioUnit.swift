import AVFAudio
import Foundation
import MuurCore

/// In-process effect audio unit that runs the full MuurMusic DSP chain (filters, modulation,
/// dynamics, loudness contour) plus the final safety limiter and the master fade used by
/// crossfade and the sleep timer.
///
/// Parameter changes never touch the render thread: `apply(program:)` swaps an immutable
/// `DSPProgram` snapshot (holding a lock for a handful of nanoseconds). The fade state survives
/// program swaps.
public final class DSPAudioUnit: AUAudioUnit {
    public static let componentSubType: OSType = 0x6D757064 // "mupd"
    public static let componentManufacturer: OSType = 0x4D757572 // "Muur"
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: DSPAudioUnit.componentSubType,
        componentManufacturer: DSPAudioUnit.componentManufacturer,
        componentFlags: 0,
        componentFlagsMask: 0)

    private static var didRegister = false

    /// Registers the subclass with the AudioComponent system (call once before creating the node).
    public static func register() {
        guard !didRegister else { return }
        didRegister = true
        AUAudioUnit.registerSubclass(DSPAudioUnit.self, as: componentDescription, name: "MuurDSP", version: 1)
    }

    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private var renderFormat: AVAudioFormat
    private let programBox = LockedValue<DSPProgram?>(nil)
    private let fadeState = DSPFadeState()
    private var allocatedFrames: AVAudioFrameCount = 512

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        renderFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try super.init(componentDescription: componentDescription, options: options)
        let bus = try AUAudioUnitBus(format: renderFormat)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [bus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
    }

    // MARK: Buses

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    public override var channelCapabilities: [NSNumber]? { [2, 8] }

    public override var maximumFramesToRender: AVAudioFrameCount {
        get { allocatedFrames }
        set { allocatedFrames = newValue }
    }

    public override var shouldBypassEffect: Bool {
        get { programBox.get() == nil }
        set {
            if newValue { programBox.set(nil) }
        }
    }

    // MARK: Render resources

    public override func allocateRenderResources() throws {
        let format = outputBusses[0].format
        renderFormat = format
        try inputBusses[0].setFormat(format)
        try super.allocateRenderResources()
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    // MARK: Parameters

    /// Installs a new program. The program's fade state is replaced by the unit's persistent one,
    /// so fades keep running across parameter changes.
    public func apply(program: DSPProgram) {
        program.fadeState.snap(to: fadeState.currentValue)
        if fadeState.isFading { program.fadeState.setTarget(fadeState.targetValue) }
        programBox.set(program)
    }

    /// The fade used for crossfades, pauses and the sleep timer. Safe to call from any thread.
    public func fade(to value: Float, rampSeconds: Double = 0.05) {
        fadeState.setTarget(value, rampSeconds: rampSeconds)
        if let program = programBox.get() { program.fadeState.setTarget(value, rampSeconds: rampSeconds) }
    }

    public func snapFade(to value: Float) {
        fadeState.snap(to: value)
        if let program = programBox.get() { program.fadeState.snap(to: value) }
    }

    public var currentFade: Float { fadeState.currentValue }

    // MARK: Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let box = programBox
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            if let pullInputBlock = pullInputBlock {
                var pullFlags = actionFlags.pointee
                let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
                if status != noErr { return status }
            } else {
                let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            guard let program = box.get() else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
            var channelBuffers: [UnsafeMutablePointer<Float>] = []
            channelBuffers.reserveCapacity(ablPointer.count)
            for buffer in ablPointer {
                guard let data = buffer.mData else { continue }
                channelBuffers.append(data.assumingMemoryBound(to: Float.self))
            }
            if !channelBuffers.isEmpty {
                program.render(channelBuffers, frameCount: Int(frameCount))
            }
            return noErr
        }
    }
}

/// An `AVAudioUnitEffect` node hosting a `DSPAudioUnit`, for insertion into an `AVAudioEngine` graph.
public final class DSPAudioNode {
    public let effect: AVAudioUnitEffect
    public let unit: DSPAudioUnit

    public init() throws {
        DSPAudioUnit.register()
        let effect = AVAudioUnitEffect(audioComponentDescription: DSPAudioUnit.componentDescription)
        guard let unit = effect.auAudioUnit as? DSPAudioUnit else {
            throw MuurError.unsupported("DSP audio unit creation")
        }
        self.effect = effect
        self.unit = unit
    }

    /// Convenience: install a program built from settings values.
    public func applySettings(chainJSON: String, dspEnabled: Bool, preGainDb: Double,
                              loudnessEnabled: Bool, loudnessBoostDb: Double, format: AVAudioFormat) {
        let program = DSPProgramBuilder.program(chainJSON: chainJSON, dspEnabled: dspEnabled, preGainDb: preGainDb,
                                                loudnessEnabled: loudnessEnabled, loudnessBoostDb: loudnessBoostDb,
                                                channelCount: Int(format.channelCount), sampleRate: format.sampleRate)
        unit.apply(program: program)
    }
}
