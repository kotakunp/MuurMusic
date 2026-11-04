#if os(macOS)
import CoreAudio
import Foundation
import MuurCore

/// A Core Audio output device selectable in settings.
public struct AudioOutputDevice: Hashable, Sendable, Identifiable {
    public var id: AudioObjectID
    public var name: String
    /// Persistent UID for settings (`MuurSettings.outputDeviceUID`).
    public var uid: String
    public var sampleRate: Double
    /// `true` when the device accepts DSD over PCM at `rate` (DoP).
    public var supportsDoP: Bool

    public init(id: AudioObjectID, name: String, uid: String, sampleRate: Double, supportsDoP: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.supportsDoP = supportsDoP
    }
}

/// Enumerates macOS output devices, applies the selected device to the player's output node and
/// (optionally) matches the device sample rate to the source (exclusive "bit-perfect" rate switching).
public enum AudioOutputDevices {

    private static func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isOutputDevice(_ id: AudioObjectID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// All output devices (excludes aggregate "virtual" devices without streams).
    public static func outputDevices() -> [AudioOutputDevice] {
        deviceIDs().filter(isOutputDevice).compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: id, name: name, uid: uid, sampleRate: nominalSampleRate(of: id) ?? 44_100,
                                     supportsDoP: supportsDoP(id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func device(forUID uid: String) -> AudioOutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    public static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    public static func nominalSampleRate(of id: AudioObjectID) -> Double? {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    /// Supported nominal sample rates of the device.
    public static func availableSampleRates(of id: AudioObjectID) -> [Double] {
        var address = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        var rates: Set<Double> = []
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for standard in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] where standard >= range.mMinimum && standard <= range.mMaximum {
                    rates.insert(standard)
                }
            }
        }
        return rates.sorted()
    }

    /// Heuristic DoP support: the device handles 176.4/352.8 kHz PCM (the rates DoP needs).
    public static func supportsDoP(_ id: AudioObjectID) -> Bool {
        availableSampleRates(of: id).contains(176_400)
    }

    /// Switches the device's nominal sample rate (used by `OutputSampleRateMode.matchSource`).
    public static func setNominalSampleRate(_ rate: Double, of id: AudioObjectID) throws {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw MuurError.io("Setting the output sample rate failed (\(status))") }
    }
}
#endif
