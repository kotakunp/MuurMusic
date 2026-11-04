import Foundation
import GRDB

/// Persistence of EQ presets (`muur-eq`) and DSP chains (`muur-dsp`). Built-in presets come from the bundled
/// `eq-presets.json`; user presets and chains are stored in the library database.
public final class AudioPresetStore: Sendable {
    public let database: MuurDatabase

    public init(database: MuurDatabase) {
        self.database = database
    }

    // MARK: Built-ins

    /// Raw contents of the bundled `eq-presets.json`.
    public static func builtInPresetFileData() -> Data? {
        guard let url = Bundle.module.url(forResource: "eq-presets", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The 13 presets shipped with the app (shared with the Windows app).
    public static let builtInPresets: [EQPreset] = {
        guard let data = AudioPresetStore.builtInPresetFileData(), let file = try? EQPresetFile.decode(data) else {
            Log.dsp.error("Bundled eq-presets.json is missing or invalid")
            return [EQPreset.flat]
        }
        return file.presets.map { EQPreset(name: $0.name, preampDb: $0.preampDb, bands: $0.bands, isBuiltIn: true) }
    }()

    public static func builtInPreset(named name: String) -> EQPreset? {
        builtInPresets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: EQ presets

    static func decodeUserPresets(_ db: Database) throws -> [EQPreset] {
        try EQPresetRecord.fetchAll(db, sql: "SELECT * FROM eq_presets ORDER BY sortIndex, name COLLATE NOCASE").map { record in
            let bands = (try? JSONDecoder().decode([EQBand].self, from: Data(record.bandsJSON.utf8))) ?? EQPreset.flat.bands
            return EQPreset(name: record.name, preampDb: record.preampDb, bands: bands)
        }
    }

    public func userPresets() async throws -> [EQPreset] {
        try await database.read { db in try AudioPresetStore.decodeUserPresets(db) }
    }

    /// Built-in presets followed by user presets.
    public func allPresets() async throws -> [EQPreset] {
        AudioPresetStore.builtInPresets + (try await userPresets())
    }

    public func observeUserPresets() -> AsyncValueObservation<[EQPreset]> {
        database.observe { db in try AudioPresetStore.decodeUserPresets(db) }
    }

    /// Looks up a preset by name (built-ins first).
    public func preset(named name: String) async throws -> EQPreset? {
        if let builtIn = AudioPresetStore.builtInPreset(named: name) { return builtIn }
        return try await userPresets().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves (inserting or replacing) a user preset. Built-in names cannot be overwritten.
    public func save(preset: EQPreset) async throws {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MuurError.invalidData("Preset name is empty") }
        guard AudioPresetStore.builtInPreset(named: name) == nil else {
            throw MuurError.invalidData("\"\(name)\" is a built-in preset name")
        }
        let bandsData = try JSONEncoder().encode(EQPreset.normalized(preset.bands))
        let bandsJSON = String(decoding: bandsData, as: UTF8.self)
        let preamp = preset.preampDb
        try await database.write { db in
            let existingIndex = try Int.fetchOne(db, sql: "SELECT sortIndex FROM eq_presets WHERE name = ?", arguments: [name])
            let index = try existingIndex ?? ((Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM eq_presets") ?? -1) + 1)
            try EQPresetRecord(name: name, preampDb: preamp, bandsJSON: bandsJSON, sortIndex: index).save(db)
        }
    }

    public func deletePreset(named name: String) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM eq_presets WHERE name = ?", arguments: [name]) }
    }

    public func renamePreset(from oldName: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AudioPresetStore.builtInPreset(named: trimmed) == nil else {
            throw MuurError.invalidData("Invalid preset name")
        }
        try await database.write { db in
            try db.execute(sql: "UPDATE eq_presets SET name = ? WHERE name = ?", arguments: [trimmed, oldName])
        }
    }

    /// Imports presets from a `*.muureq.json` file; returns the imported presets (renamed on conflicts).
    @discardableResult
    public func importPresets(from data: Data) async throws -> [EQPreset] {
        let file = try EQPresetFile.decode(data)
        var imported: [EQPreset] = []
        let existing = Set(try await allPresets().map { $0.name.lowercased() })
        for preset in file.presets {
            var candidate = preset
            var name = preset.name
            var counter = 2
            while existing.contains(name.lowercased()) || imported.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                name = "\(preset.name) \(counter)"
                counter += 1
            }
            candidate.name = name
            candidate.isBuiltIn = false
            try await save(preset: candidate)
            imported.append(candidate)
        }
        return imported
    }

    /// Encodes presets as a `*.muureq.json` file.
    public func exportPresets(_ presets: [EQPreset]) throws -> Data {
        try EQPresetFile(presets: presets).encoded()
    }

    // MARK: DSP chains

    static func decodeChains(_ db: Database) throws -> [DSPChain] {
        try DSPChainRecord.fetchAll(db, sql: "SELECT * FROM dsp_chains ORDER BY name COLLATE NOCASE").compactMap { record in
            DSPChain.decode(json: record.json)
        }
    }

    public func dspChains() async throws -> [DSPChain] {
        try await database.read { db in try AudioPresetStore.decodeChains(db) }
    }

    public func observeDSPChains() -> AsyncValueObservation<[DSPChain]> {
        database.observe { db in try AudioPresetStore.decodeChains(db) }
    }

    public func save(chain: DSPChain) async throws {
        let name = chain.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MuurError.invalidData("Chain name is empty") }
        var named = chain
        named.name = name
        let json = named.jsonString()
        try await database.write { db in
            try DSPChainRecord(name: name, json: json, updatedAt: Date().timeIntervalSince1970).save(db)
        }
    }

    public func deleteChain(named name: String) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM dsp_chains WHERE name = ?", arguments: [name]) }
    }

    /// Imports a `*.muurdsp.json` chain (unknown node types are preserved).
    @discardableResult
    public func importChain(from data: Data) async throws -> DSPChain {
        let chain = try DSPChain.decode(data)
        try await save(chain: chain)
        return chain
    }

    public func exportChain(_ chain: DSPChain) throws -> Data {
        try chain.encoded()
    }
}
