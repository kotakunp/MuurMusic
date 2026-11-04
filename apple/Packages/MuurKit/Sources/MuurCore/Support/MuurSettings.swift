import Foundation
import Combine

public enum ThemePreference: String, Codable, CaseIterable, Sendable { case system, dark, light }
public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case amber, violet, mint, rose, sky
    public var hex: String {
        switch self {
        case .amber: return "#FFB23F"
        case .violet: return "#8B6CFF"
        case .mint: return "#5EE0C0"
        case .rose: return "#FF7BA9"
        case .sky: return "#5CB8FF"
        }
    }
}
public enum NowPlayingStyle: String, Codable, CaseIterable, Sendable { case artwork, vinyl, visualizer }
public enum ReplayGainMode: String, Codable, CaseIterable, Sendable { case off, track, album }
public enum DSDPlaybackMode: String, Codable, CaseIterable, Sendable {
    /// Convert DSD to PCM (works everywhere).
    case pcm
    /// DSD over PCM for DACs that support DoP (macOS, USB DACs).
    case dop
}
public enum OutputSampleRateMode: String, Codable, CaseIterable, Sendable {
    /// Leave the device at its current rate (system mixer resamples).
    case system
    /// Switch the output device to the source sample rate when possible (macOS).
    case matchSource
    /// Use `fixedOutputSampleRate`.
    case fixed
}
public enum VisualizerPreset: String, Codable, CaseIterable, Sendable {
    case spectrumBars, mirrorBars, circleSpectrum, waveform, particles, catEyes, starfield, vinyl
}
public enum LibraryTab: String, Codable, CaseIterable, Sendable {
    case songs, albums, artists, albumArtists, genres, composers, folders, playlists, sources, files, search
}

/// UserDefaults-backed settings observable from SwiftUI. Must be used on the main actor; background code
/// reads values through `MuurSettings.Snapshot.current`.
@MainActor
public final class MuurSettings: ObservableObject {
    public static let shared = MuurSettings()

    public enum Key: String, CaseIterable {
        case theme, accent, nowPlayingStyle, tabOrder, haptics
        case crossfadeSeconds, crossfadeSkipsSameAlbum, gapless, replayGainMode, replayGainPreampDb, preventClipping
        case playbackSpeed, skipBackInterval, skipForwardInterval, mixWithOthers, pauseOnRouteLoss
        case dsdMode, outputDeviceUID, outputSampleRateMode, fixedOutputSampleRate
        case audioCacheLimitMB, offlineMode, prefetchNext, downloadOverCellular
        case fetchLyricsOnline, autoTagOnline, watchFolders
        case eqEnabled, eqPresetName, eqPreampDb, eqBandGains, loudnessEnabled, loudnessBoostDb, dspEnabled, dspChainJSON
        case visualizerPreset, visualizerAutoCycle, visualizerCycleSeconds
        case sleepFadeOut, wifiTransferPort, wifiTransferPIN, wifiTransferRequirePIN
        case resumeOnLaunch, showHiResBadges
    }

    public let defaults: UserDefaults

    @Published public var theme: ThemePreference { didSet { save(.theme, theme.rawValue) } }
    @Published public var accent: AccentChoice { didSet { save(.accent, accent.rawValue) } }
    @Published public var nowPlayingStyle: NowPlayingStyle { didSet { save(.nowPlayingStyle, nowPlayingStyle.rawValue) } }
    @Published public var tabOrder: [LibraryTab] { didSet { save(.tabOrder, tabOrder.map(\.rawValue)) } }
    @Published public var haptics: Bool { didSet { save(.haptics, haptics) } }

    @Published public var crossfadeSeconds: Double { didSet { save(.crossfadeSeconds, crossfadeSeconds) } }
    @Published public var crossfadeSkipsSameAlbum: Bool { didSet { save(.crossfadeSkipsSameAlbum, crossfadeSkipsSameAlbum) } }
    @Published public var gapless: Bool { didSet { save(.gapless, gapless) } }
    @Published public var replayGainMode: ReplayGainMode { didSet { save(.replayGainMode, replayGainMode.rawValue) } }
    @Published public var replayGainPreampDb: Double { didSet { save(.replayGainPreampDb, replayGainPreampDb) } }
    @Published public var preventClipping: Bool { didSet { save(.preventClipping, preventClipping) } }
    @Published public var playbackSpeed: Double { didSet { save(.playbackSpeed, playbackSpeed) } }
    @Published public var skipBackInterval: Double { didSet { save(.skipBackInterval, skipBackInterval) } }
    @Published public var skipForwardInterval: Double { didSet { save(.skipForwardInterval, skipForwardInterval) } }
    @Published public var mixWithOthers: Bool { didSet { save(.mixWithOthers, mixWithOthers) } }
    @Published public var pauseOnRouteLoss: Bool { didSet { save(.pauseOnRouteLoss, pauseOnRouteLoss) } }
    @Published public var dsdMode: DSDPlaybackMode { didSet { save(.dsdMode, dsdMode.rawValue) } }
    @Published public var outputDeviceUID: String? { didSet { save(.outputDeviceUID, outputDeviceUID) } }
    @Published public var outputSampleRateMode: OutputSampleRateMode { didSet { save(.outputSampleRateMode, outputSampleRateMode.rawValue) } }
    @Published public var fixedOutputSampleRate: Double { didSet { save(.fixedOutputSampleRate, fixedOutputSampleRate) } }

    @Published public var audioCacheLimitMB: Int { didSet { save(.audioCacheLimitMB, audioCacheLimitMB) } }
    @Published public var offlineMode: Bool { didSet { save(.offlineMode, offlineMode) } }
    @Published public var prefetchNext: Bool { didSet { save(.prefetchNext, prefetchNext) } }
    @Published public var downloadOverCellular: Bool { didSet { save(.downloadOverCellular, downloadOverCellular) } }
    @Published public var fetchLyricsOnline: Bool { didSet { save(.fetchLyricsOnline, fetchLyricsOnline) } }
    @Published public var autoTagOnline: Bool { didSet { save(.autoTagOnline, autoTagOnline) } }
    @Published public var watchFolders: Bool { didSet { save(.watchFolders, watchFolders) } }

    @Published public var eqEnabled: Bool { didSet { save(.eqEnabled, eqEnabled) } }
    @Published public var eqPresetName: String { didSet { save(.eqPresetName, eqPresetName) } }
    @Published public var eqPreampDb: Double { didSet { save(.eqPreampDb, eqPreampDb) } }
    /// Ten gains in dB for the ISO bands 31 Hz ... 16 kHz.
    @Published public var eqBandGains: [Double] { didSet { save(.eqBandGains, eqBandGains) } }
    @Published public var loudnessEnabled: Bool { didSet { save(.loudnessEnabled, loudnessEnabled) } }
    @Published public var loudnessBoostDb: Double { didSet { save(.loudnessBoostDb, loudnessBoostDb) } }
    @Published public var dspEnabled: Bool { didSet { save(.dspEnabled, dspEnabled) } }
    /// The active DSP chain in `muur-dsp` JSON.
    @Published public var dspChainJSON: String { didSet { save(.dspChainJSON, dspChainJSON) } }

    @Published public var visualizerPreset: VisualizerPreset { didSet { save(.visualizerPreset, visualizerPreset.rawValue) } }
    @Published public var visualizerAutoCycle: Bool { didSet { save(.visualizerAutoCycle, visualizerAutoCycle) } }
    @Published public var visualizerCycleSeconds: Double { didSet { save(.visualizerCycleSeconds, visualizerCycleSeconds) } }
    @Published public var sleepFadeOut: Bool { didSet { save(.sleepFadeOut, sleepFadeOut) } }
    @Published public var wifiTransferPort: Int { didSet { save(.wifiTransferPort, wifiTransferPort) } }
    @Published public var wifiTransferRequirePIN: Bool { didSet { save(.wifiTransferRequirePIN, wifiTransferRequirePIN) } }
    @Published public var wifiTransferPIN: String { didSet { save(.wifiTransferPIN, wifiTransferPIN) } }
    @Published public var resumeOnLaunch: Bool { didSet { save(.resumeOnLaunch, resumeOnLaunch) } }
    @Published public var showHiResBadges: Bool { didSet { save(.showHiResBadges, showHiResBadges) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        func string(_ key: Key) -> String? { d.string(forKey: key.rawValue) }
        func double(_ key: Key, _ fallback: Double) -> Double { d.object(forKey: key.rawValue) == nil ? fallback : d.double(forKey: key.rawValue) }
        func bool(_ key: Key, _ fallback: Bool) -> Bool { d.object(forKey: key.rawValue) == nil ? fallback : d.bool(forKey: key.rawValue) }
        func int(_ key: Key, _ fallback: Int) -> Int { d.object(forKey: key.rawValue) == nil ? fallback : d.integer(forKey: key.rawValue) }

        theme = ThemePreference(rawValue: string(.theme) ?? "") ?? .system
        accent = AccentChoice(rawValue: string(.accent) ?? "") ?? .amber
        nowPlayingStyle = NowPlayingStyle(rawValue: string(.nowPlayingStyle) ?? "") ?? .artwork
        let storedTabs = (d.stringArray(forKey: Key.tabOrder.rawValue) ?? []).compactMap { LibraryTab(rawValue: $0) }
        tabOrder = storedTabs.isEmpty ? [.songs, .albums, .artists, .playlists, .sources, .search] : storedTabs
        haptics = bool(.haptics, true)

        crossfadeSeconds = double(.crossfadeSeconds, 0)
        crossfadeSkipsSameAlbum = bool(.crossfadeSkipsSameAlbum, true)
        gapless = bool(.gapless, true)
        replayGainMode = ReplayGainMode(rawValue: string(.replayGainMode) ?? "") ?? .off
        replayGainPreampDb = double(.replayGainPreampDb, 0)
        preventClipping = bool(.preventClipping, true)
        playbackSpeed = double(.playbackSpeed, 1)
        skipBackInterval = double(.skipBackInterval, 15)
        skipForwardInterval = double(.skipForwardInterval, 30)
        mixWithOthers = bool(.mixWithOthers, false)
        pauseOnRouteLoss = bool(.pauseOnRouteLoss, true)
        dsdMode = DSDPlaybackMode(rawValue: string(.dsdMode) ?? "") ?? .pcm
        outputDeviceUID = string(.outputDeviceUID)
        outputSampleRateMode = OutputSampleRateMode(rawValue: string(.outputSampleRateMode) ?? "") ?? .system
        fixedOutputSampleRate = double(.fixedOutputSampleRate, 48_000)

        audioCacheLimitMB = int(.audioCacheLimitMB, 2048)
        offlineMode = bool(.offlineMode, false)
        prefetchNext = bool(.prefetchNext, true)
        downloadOverCellular = bool(.downloadOverCellular, true)
        fetchLyricsOnline = bool(.fetchLyricsOnline, true)
        autoTagOnline = bool(.autoTagOnline, true)
        watchFolders = bool(.watchFolders, true)

        eqEnabled = bool(.eqEnabled, false)
        eqPresetName = string(.eqPresetName) ?? "Flat"
        eqPreampDb = double(.eqPreampDb, 0)
        let gains = (d.array(forKey: Key.eqBandGains.rawValue) as? [Double]) ?? []
        eqBandGains = gains.count == 10 ? gains : Array(repeating: 0, count: 10)
        loudnessEnabled = bool(.loudnessEnabled, false)
        loudnessBoostDb = double(.loudnessBoostDb, 6)
        dspEnabled = bool(.dspEnabled, false)
        dspChainJSON = string(.dspChainJSON) ?? ""

        visualizerPreset = VisualizerPreset(rawValue: string(.visualizerPreset) ?? "") ?? .spectrumBars
        visualizerAutoCycle = bool(.visualizerAutoCycle, false)
        visualizerCycleSeconds = double(.visualizerCycleSeconds, 20)
        sleepFadeOut = bool(.sleepFadeOut, true)
        wifiTransferPort = int(.wifiTransferPort, 8080)
        wifiTransferRequirePIN = bool(.wifiTransferRequirePIN, false)
        wifiTransferPIN = string(.wifiTransferPIN) ?? String(format: "%04d", Int.random(in: 0...9999))
        resumeOnLaunch = bool(.resumeOnLaunch, true)
        showHiResBadges = bool(.showHiResBadges, true)
        // didSet does not run in init; the transfer server reads the PIN straight from defaults.
        if string(.wifiTransferPIN) == nil { save(.wifiTransferPIN, wifiTransferPIN) }
    }

    private func save(_ key: Key, _ value: Any?) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    /// Thread-safe read-only view of the persisted settings for background services.
    public struct Snapshot: Sendable {
        public var offlineMode: Bool
        public var fetchLyricsOnline: Bool
        public var autoTagOnline: Bool
        public var audioCacheLimitMB: Int
        public var prefetchNext: Bool
        public var downloadOverCellular: Bool

        public static func current(defaults: UserDefaults = .standard) -> Snapshot {
            func bool(_ key: Key, _ fallback: Bool) -> Bool {
                defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.bool(forKey: key.rawValue)
            }
            let limit = defaults.object(forKey: Key.audioCacheLimitMB.rawValue) == nil ? 2048 : defaults.integer(forKey: Key.audioCacheLimitMB.rawValue)
            return Snapshot(offlineMode: bool(.offlineMode, false), fetchLyricsOnline: bool(.fetchLyricsOnline, true),
                            autoTagOnline: bool(.autoTagOnline, true), audioCacheLimitMB: limit,
                            prefetchNext: bool(.prefetchNext, true), downloadOverCellular: bool(.downloadOverCellular, true))
        }
    }
}
