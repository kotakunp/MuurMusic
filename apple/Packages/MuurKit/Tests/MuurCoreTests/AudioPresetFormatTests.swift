import XCTest
@testable import MuurCore

final class AudioPresetFormatTests: XCTestCase {

    func testBundledEQPresetsDecodeAndMatchSpec() throws {
        let data = try XCTUnwrap(AudioPresetStore.builtInPresetFileData(), "eq-presets.json must be bundled")
        let file = try EQPresetFile.decode(data)
        XCTAssertEqual(file.format, "muur-eq")
        XCTAssertEqual(file.presets.count, 13)
        XCTAssertEqual(file.presets.first?.name, "Flat")
        XCTAssertEqual(file.presets.first?.gains, Array(repeating: 0, count: 10))
        for preset in file.presets {
            XCTAssertEqual(preset.bands.count, 10, "\(preset.name) must define ten bands")
            XCTAssertEqual(preset.bands.map(\.frequencyHz), EQPreset.isoFrequencies)
            for band in preset.bands {
                XCTAssertTrue(EQPreset.gainRange.contains(band.gainDb))
            }
        }
        XCTAssertEqual(AudioPresetStore.builtInPresets.count, 13)
        XCTAssertEqual(AudioPresetStore.builtInPreset(named: "rock")?.name, "Rock")
    }

    func testEQPresetRoundTripThroughJSON() throws {
        let data = try XCTUnwrap(AudioPresetStore.builtInPresetFileData())
        let file = try EQPresetFile.decode(data)
        let reparsed = try EQPresetFile.decode(file.encoded())
        XCTAssertEqual(reparsed, file) // isBuiltIn is runtime-only and excluded from JSON
    }

    func testEQNormalizationClampsAndResnapsFrequencies() {
        let bands = [EQBand(frequencyHz: 60, gainDb: 30), EQBand(frequencyHz: 16000, gainDb: -30)]
        let normalized = EQPreset.normalized(bands)
        XCTAssertEqual(normalized.count, 10)
        XCTAssertEqual(normalized[1].gainDb, 12) // 60 Hz snaps to 62 Hz and clamps to +12
        XCTAssertEqual(normalized[9].gainDb, -12)
        XCTAssertEqual(normalized[0].gainDb, 0) // 60 Hz is not within half an octave of 31 Hz
    }

    func testDSPChainRoundTripPreservesUnknownNodes() throws {
        let json = """
        {
          "format": "muur-dsp",
          "version": 1,
          "name": "Test Chain",
          "preGainDb": -3.5,
          "nodes": [
            { "type": "reverb", "enabled": true, "params": { "mix": 0.4, "roomSize": 0.7 } },
            { "type": "futureEffect3000", "enabled": false, "params": { "magic": 42 } }
          ]
        }
        """
        let chain = try XCTUnwrap(DSPChain.decode(json: json))
        XCTAssertEqual(chain.name, "Test Chain")
        XCTAssertEqual(chain.nodes.count, 2)
        XCTAssertEqual(chain.nodes[0].nodeType, .reverb)
        XCTAssertTrue(chain.nodes[0].isSupported)
        XCTAssertNil(chain.nodes[1].nodeType)
        XCTAssertFalse(chain.nodes[1].isSupported)
        XCTAssertFalse(chain.nodes[1].enabled)

        let decoded = try DSPChain.decode(chain.encoded())
        XCTAssertTrue(decoded.isEquivalent(to: chain))
        XCTAssertEqual(decoded.nodes[1].type, "futureEffect3000")
        XCTAssertEqual(decoded.nodes[1].params["magic"], .number(42))
        XCTAssertEqual(decoded.nodes[0].clampedValue("mix"), 0.4, accuracy: 1e-9)
    }

    func testDSPChainRejectsForeignFormat() {
        XCTAssertNil(DSPChain.decode(json: #"{"format": "other", "nodes": []}"#))
    }

    func testDSPParameterClamping() {
        var node = DSPNode(type: .gain)
        node.set("gainDb", 100)
        let spec = DSPNodeType.gain.parameters.first { $0.key == "gainDb" }
        let limit = spec?.range.upperBound ?? 24
        XCTAssertEqual(node.clampedValue("gainDb"), limit, accuracy: 1e-9)
    }

    func testDSPNodeTypeCoverage() {
        XCTAssertEqual(DSPNodeType.allCases.count, 22)
        XCTAssertTrue(DSPNodeType.allCases.contains(.reverb))
        XCTAssertTrue(DSPNodeType.allCases.contains(.compressor))
        XCTAssertTrue(DSPNodeType.allCases.contains(.crossfeed))
    }
}
