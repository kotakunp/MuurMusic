import XCTest
@testable import MuurCore

final class LRCParserTests: XCTestCase {

    func testParsesSyncedLyricsWithMetadata() {
        let text = """
        [ti:Song Title]
        [ar:Artist Name]
        [al:Album Name]
        [00:12.50]Hello there
        [00:15.00][00:20.00]Repeated line
        [01:02.37]Fractional
        """
        let lyrics = LRCParser.parse(text)
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.title, "Song Title")
        XCTAssertEqual(lyrics.artist, "Artist Name")
        XCTAssertEqual(lyrics.album, "Album Name")
        XCTAssertEqual(lyrics.lines.count, 4) // the double timestamp produces two entries
        XCTAssertEqual(lyrics.lines[0].text, "Hello there")
        XCTAssertEqual(lyrics.lines[0].time ?? -1, 12.5, accuracy: 1e-9)
        XCTAssertEqual(lyrics.lines[1].time ?? -1, 15.0, accuracy: 1e-9)
        XCTAssertEqual(lyrics.lines[2].time ?? -1, 20.0, accuracy: 1e-9)
        XCTAssertEqual(lyrics.lines[1].text, "Repeated line")
        XCTAssertEqual(lyrics.lines[3].time ?? -1, 62.37, accuracy: 1e-9)
    }

    func testOutOfOrderTimestampsAreSortedStably() {
        let text = "[00:20.00]Second\n[00:10.00]First\n[00:20.00]Also second\n"
        let lyrics = LRCParser.parse(text)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second", "Also second"])
    }

    func testOffsetTagShiftsTimesEarlier() {
        let text = "[offset:+250]\n[00:12.50]Hello\n"
        let lyrics = LRCParser.parse(text)
        XCTAssertEqual(lyrics.offsetMs, 250)
        XCTAssertEqual(lyrics.lines[0].time ?? -1, 12.25, accuracy: 1e-9)
    }

    func testUnsyncedTextFallsBackToPlainLines() {
        let text = "First line\n\nSecond line\n"
        let lyrics = LRCParser.parse(text)
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertNil(lyrics.lines[0].time)
        // Interior blank lines are stanza breaks and are kept; only leading/trailing ones are trimmed.
        XCTAssertEqual(lyrics.plainText, "First line\n\nSecond line")
    }

    func testIndexAtTimeUsesLastLineAtOrBefore() {
        let lyrics = LRCParser.parse("[00:05.00]A\n[00:10.00]B\n[00:15.00]C\n")
        XCTAssertNil(lyrics.index(at: 4.9))
        XCTAssertEqual(lyrics.index(at: 5.0), 0)
        XCTAssertEqual(lyrics.index(at: 12.0), 1)
        XCTAssertEqual(lyrics.index(at: 999), 2)
    }

    func testTimestampFormatting() {
        XCTAssertEqual(LRCParser.timestamp(0), "00:00.00")
        XCTAssertEqual(LRCParser.timestamp(62.37), "01:02.37")
        XCTAssertEqual(LRCParser.timestamp(12.499), "00:12.50") // rounds to centiseconds
    }

    func testLRCStringRoundTrip() {
        let original = LRCParser.parse("[ti:Title]\n[ar:Artist]\n[00:05.00]A\n[00:10.00]B\n")
        let reparsed = LRCParser.parse(original.lrcString())
        XCTAssertTrue(reparsed.isSynced)
        XCTAssertEqual(reparsed.title, "Title")
        XCTAssertEqual(reparsed.artist, "Artist")
        XCTAssertEqual(reparsed.lines.map(\.text), ["A", "B"])
        XCTAssertEqual(reparsed.lines[0].time ?? -1, 5.0, accuracy: 0.01)
        XCTAssertEqual(reparsed.lines[1].time ?? -1, 10.0, accuracy: 0.01)
    }
}
