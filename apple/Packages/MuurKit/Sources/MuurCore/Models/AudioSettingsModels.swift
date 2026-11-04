import Foundation
import GRDB

/// One band of the 10-band graphic EQ.
public struct EQBand: Codable, Hashable, Sendable {
    public var frequencyHz: Double
    public var gainDb: Double

    public init(frequencyHz: Double, gainDb: Double) {
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
    }
}

/// A 10-band EQ preset (SHARED_FORMATS `muur-eq`).
public struct EQPreset: Codable, Hashable, Identifiable, Sendable {
    /// The ISO band centers shared by both apps.
    public static let isoFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandQ: Double = 1.41
    public static let gainRange: ClosedRange<Double> = -12...12

    public var id: String { name }
    public var name: String
    public var preampDb: Double
    public var bands: [EQBand]
    /// `true` for presets shipped in eq-presets.json (not encoded to JSON).
    public var isBuiltIn: Bool

    public init(name: String, preampDb: Double, bands: [EQBand], isBuiltIn: Bool = false) {
        self.name = name
        self.preampDb = preampDb
        self.bands = EQPreset.normalized(bands)
        self.isBuiltIn = isBuiltIn
    }

    public init(name: String, preampDb: Double, gains: [Double], isBuiltIn: Bool = false) {
        let bands = EQPreset.isoFrequencies.enumerated().map { index, frequency in
            EQBand(frequencyHz: frequency, gainDb: index < gains.count ? gains[index] : 0)
        }
        self.init(name: name, preampDb: preampDb, bands: bands, isBuiltIn: isBuiltIn)
    }

    public static let flat = EQPreset(name: "Flat", preampDb: 0, gains: Array(repeating: 0, count: 10))

    public var gains: [Double] { bands.map(\.gainDb) }

    /// Clamps gains and maps bands onto the ten ISO frequencies (nearest match).
    public static func normalized(_ bands: [EQBand]) -> [EQBand] {
        isoFrequencies.map { frequency in
            let match = bands.min { abs(log2($0.frequencyHz / frequency)) < abs(log2($1.frequencyHz / frequency)) }
            let gain = match.map { abs(log2($0.frequencyHz / frequency)) < 0.5 ? $0.gainDb : 0 } ?? 0
            return EQBand(frequencyHz: frequency, gainDb: min(max(gain, gainRange.lowerBound), gainRange.upperBound))
        }
    }

    private enum CodingKeys: String, CodingKey { case name, preampDb, bands }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let preamp = try container.decodeIfPresent(Double.self, forKey: .preampDb) ?? 0
        let bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        self.init(name: name, preampDb: min(max(preamp, -24), 24), bands: bands)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(preampDb, forKey: .preampDb)
        try container.encode(bands, forKey: .bands)
    }
}

/// `*.muureq.json` file contents.
public struct EQPresetFile: Codable, Hashable, Sendable {
    public var format: String
    public var version: Int
    public var presets: [EQPreset]

    public init(presets: [EQPreset]) {
        self.format = "muur-eq"
        self.version = 1
        self.presets = presets
    }

    public static func decode(_ data: Data) throws -> EQPresetFile {
        let file = try JSONDecoder().decode(EQPresetFile.self, from: data)
        guard file.format == "muur-eq" else { throw MuurError.invalidData("Not a muur-eq file") }
        return file
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Database row for user EQ presets.
struct EQPresetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "eq_presets"
    var name: String
    var preampDb: Double
    var bandsJSON: String
    var sortIndex: Int
}

// MARK: - DSP chain (`muur-dsp`)

/// Known DSP node types (SHARED_FORMATS). Unknown types are preserved in `DSPNode.type`.
public enum DSPNodeType: String, CaseIterable, Codable, Sendable {
    case lowPass, highPass, bandPass, notch, peaking, lowShelf, highShelf
    case gain, softClip, bitCrusher, tremolo, delay, ringModulator, stereoWidth
    case reverb, chorus, flanger, phaser, autoWah, distortion, compressor, crossfeed

    public var displayName: String {
        switch self {
        case .lowPass: return "Low-pass"
        case .highPass: return "High-pass"
        case .bandPass: return "Band-pass"
        case .notch: return "Notch"
        case .peaking: return "Peaking EQ"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .gain: return "Gain"
        case .softClip: return "Soft Clip"
        case .bitCrusher: return "Bit Crusher"
        case .tremolo: return "Tremolo"
        case .delay: return "Delay / Echo"
        case .ringModulator: return "Ring Modulator"
        case .stereoWidth: return "Stereo Width"
        case .reverb: return "Reverb"
        case .chorus: return "Chorus"
        case .flanger: return "Flanger"
        case .phaser: return "Phaser"
        case .autoWah: return "Auto-wah"
        case .distortion: return "Distortion"
        case .compressor: return "Compressor"
        case .crossfeed: return "Crossfeed"
        }
    }

    /// Parameter definitions (name, default, range) for editors.
    public var parameters: [DSPParameterSpec] {
        func p(_ key: String, _ value: Double, _ range: ClosedRange<Double>, _ unit: String = "") -> DSPParameterSpec {
            DSPParameterSpec(key: key, defaultValue: value, range: range, unit: unit)
        }
        switch self {
        case .lowPass: return [p("frequencyHz", 8000, 20...20000, "Hz"), p("q", 0.707, 0.1...18)]
        case .highPass: return [p("frequencyHz", 40, 20...20000, "Hz"), p("q", 0.707, 0.1...18)]
        case .bandPass: return [p("frequencyHz", 1000, 20...20000, "Hz"), p("q", 1, 0.1...18)]
        case .notch: return [p("frequencyHz", 50, 20...20000, "Hz"), p("q", 10, 0.1...40)]
        case .peaking: return [p("frequencyHz", 1000, 20...20000, "Hz"), p("gainDb", 0, -24...24, "dB"), p("q", 1, 0.1...18)]
        case .lowShelf: return [p("frequencyHz", 120, 20...20000, "Hz"), p("gainDb", 0, -24...24, "dB"), p("q", 0.707, 0.1...4)]
        case .highShelf: return [p("frequencyHz", 8000, 20...20000, "Hz"), p("gainDb", 0, -24...24, "dB"), p("q", 0.707, 0.1...4)]
        case .gain: return [p("gainDb", 0, -48...24, "dB")]
        case .softClip: return [p("drive", 0.3, 0...1)]
        case .bitCrusher: return [p("bits", 8, 1...16), p("downsample", 4, 1...32)]
        case .tremolo: return [p("rateHz", 5, 0.1...20, "Hz"), p("depth", 0.5, 0...1)]
        case .delay: return [p("timeMs", 350, 1...2000, "ms"), p("feedback", 0.35, 0...0.95), p("mix", 0.3, 0...1)]
        case .ringModulator: return [p("frequencyHz", 440, 1...5000, "Hz"), p("mix", 0.5, 0...1)]
        case .stereoWidth: return [p("width", 1, 0...2)]
        case .reverb: return [p("roomSize", 0.5, 0...1), p("damping", 0.5, 0...1), p("mix", 0.25, 0...1)]
        case .chorus: return [p("rateHz", 0.8, 0.05...10, "Hz"), p("depth", 0.5, 0...1), p("mix", 0.5, 0...1), p("feedback", 0.1, 0...0.95)]
        case .flanger: return [p("rateHz", 0.25, 0.05...10, "Hz"), p("depth", 0.7, 0...1), p("mix", 0.5, 0...1), p("feedback", 0.5, 0...0.95)]
        case .phaser: return [p("rateHz", 0.5, 0.05...10, "Hz"), p("depth", 0.7, 0...1), p("stages", 6, 2...12), p("feedback", 0.5, 0...0.95), p("mix", 0.5, 0...1)]
        case .autoWah: return [p("sensitivity", 0.5, 0...1), p("minHz", 300, 50...2000, "Hz"), p("maxHz", 2500, 500...8000, "Hz"), p("q", 3, 0.5...10), p("mix", 0.8, 0...1)]
        case .distortion: return [p("drive", 0.5, 0...1), p("tone", 0.5, 0...1), p("mix", 1, 0...1)]
        case .compressor: return [p("thresholdDb", -18, -60...0, "dB"), p("ratio", 4, 1...20), p("attackMs", 10, 0.1...200, "ms"), p("releaseMs", 120, 5...2000, "ms"), p("makeupDb", 0, 0...24, "dB")]
        case .crossfeed: return [p("amount", 0.3, 0...1)]
        }
    }

    public var defaultParams: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for spec in parameters { result[spec.key] = .number(spec.defaultValue) }
        return result
    }
}

public struct DSPParameterSpec: Hashable, Sendable {
    public var key: String
    public var defaultValue: Double
    public var range: ClosedRange<Double>
    public var unit: String
}

/// One node of a DSP chain. `id` is runtime-only (not part of the JSON format).
public struct DSPNode: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Raw node type; may be an unknown type from a newer app version.
    public var type: String
    public var enabled: Bool
    public var params: [String: JSONValue]

    public init(id: UUID = UUID(), type: DSPNodeType, enabled: Bool = true, params: [String: JSONValue]? = nil) {
        self.id = id
        self.type = type.rawValue
        self.enabled = enabled
        self.params = params ?? type.defaultParams
    }

    public init(id: UUID = UUID(), rawType: String, enabled: Bool, params: [String: JSONValue]) {
        self.id = id
        self.type = rawType
        self.enabled = enabled
        self.params = params
    }

    public var nodeType: DSPNodeType? { DSPNodeType(rawValue: type) }
    public var isSupported: Bool { nodeType != nil }

    public func value(_ key: String, default fallback: Double) -> Double {
        params[key]?.doubleValue ?? fallback
    }

    /// Value clamped to the parameter's documented range.
    public func clampedValue(_ key: String) -> Double {
        guard let spec = nodeType?.parameters.first(where: { $0.key == key }) else { return value(key, default: 0) }
        let raw = value(key, default: spec.defaultValue)
        return min(max(raw, spec.range.lowerBound), spec.range.upperBound)
    }

    public mutating func set(_ key: String, _ value: Double) {
        params[key] = .number(value)
    }

    private enum CodingKeys: String, CodingKey { case type, enabled, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        type = try container.decode(String.self, forKey: .type)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(params, forKey: .params)
    }

    /// Equality ignoring the runtime id (used for round-trip comparisons).
    public func isEquivalent(to other: DSPNode) -> Bool {
        type == other.type && enabled == other.enabled && params == other.params
    }
}

/// A named DSP chain (`*.muurdsp.json`).
public struct DSPChain: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var format: String
    public var version: Int
    public var name: String
    public var nodes: [DSPNode]

    public init(name: String, nodes: [DSPNode] = []) {
        self.format = "muur-dsp"
        self.version = 1
        self.name = name
        self.nodes = nodes
    }

    public static let empty = DSPChain(name: "Default")

    private enum CodingKeys: String, CodingKey { case format, version, name, nodes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "muur-dsp"
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        nodes = try container.decodeIfPresent([DSPNode].self, forKey: .nodes) ?? []
    }

    public static func decode(_ data: Data) throws -> DSPChain {
        let chain = try JSONDecoder().decode(DSPChain.self, from: data)
        guard chain.format == "muur-dsp" else { throw MuurError.invalidData("Not a muur-dsp file") }
        return chain
    }

    public static func decode(json: String) -> DSPChain? {
        guard !json.isEmpty else { return nil }
        return try? decode(Data(json.utf8))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString() -> String {
        (try? encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public func isEquivalent(to other: DSPChain) -> Bool {
        format == other.format && version == other.version && name == other.name && nodes.count == other.nodes.count
            && zip(nodes, other.nodes).allSatisfy { $0.isEquivalent(to: $1) }
    }
}

/// Database row for saved DSP chains.
struct DSPChainRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dsp_chains"
    var name: String
    var json: String
    var updatedAt: Double
}
