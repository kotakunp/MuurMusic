import XCTest
@testable import MuurCore

final class CueSheetTests: XCTestCase {

    func testSecondsFromIndexConvertsFramesAt75FPS() {
        XCTAssertEqual(CueSheet.seconds(fromIndex: "00:00:00"), 0)
        XCTAssertEqual(CueSheet.seconds(fromIndex: "00:00:75"), nil) // 75 frames is out of range
        XCTAssertEqual(CueSheet.seconds(fromIndex: "00:01:00"), 1.0)
        XCTAssertEqual(CueSheet.seconds(fromIndex: "01:02:37") ?? -1, 62 + 37.0 / 75.0, accuracy: 1e-9)
        // Minutes may exceed 59.
        XCTAssertEqual(CueSheet.seconds(fromIndex: "61:00:00"), 3660)
        XCTAssertNil(CueSheet.seconds(fromIndex: "00:60:00")) // seconds must be < 60
        XCTAssertNil(CueSheet.seconds(fromIndex: "00:00"))
        XCTAssertNil(CueSheet.seconds(fromIndex: "ab:cd:ef"))
    }

    func testIndexStringRoundTripsSeconds() {
        XCTAssertEqual(CueSheet.indexString(seconds: 0), "00:00:00")
        let seconds = 62 + 37.0 / 75.0
        XCTAssertEqual(CueSheet.indexString(seconds: seconds), "01:02:37")
        XCTAssertEqual(CueSheet.seconds(fromIndex: CueSheet.indexString(seconds: seconds)) ?? -1, seconds, accuracy: 1e-9)
        XCTAssertEqual(CueSheet.indexString(seconds: 3661.5), "61:01:37") // 274612.5 frames rounds to 274613
    }

    func testParseFullSheet() {
        let text = """
        PERFORMER "Sample Artist"
        TITLE "Sample Album"
        REM GENRE Rock
        REM DATE 2021
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            PERFORMER "Sample Artist"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 03:25:30
          TRACK 03 AUDIO
            TITLE "Third"
            INDEX 00 07:00:00
            INDEX 01 07:00:37
        """
        let sheet = CueSheet.parse(text)
        XCTAssertEqual(sheet.title, "Sample Album")
        XCTAssertEqual(sheet.performer, "Sample Artist")
        XCTAssertEqual(sheet.genre, "Rock")
        XCTAssertEqual(sheet.date, "2021")
        XCTAssertEqual(sheet.tracks.count, 3)
        XCTAssertEqual(sheet.files, ["album.flac"])

        XCTAssertEqual(sheet.tracks[0].start, 0)
        XCTAssertEqual(sheet.tracks[1].start, 205.4, accuracy: 1e-9) // 3*60 + 25 + 30/75
        XCTAssertEqual(sheet.tracks[2].title, "Third")
        XCTAssertEqual(sheet.tracks[2].pregapStart ?? -1, 420.0, accuracy: 1e-9) // INDEX 00
        XCTAssertEqual(sheet.tracks[2].start, 420 + 37.0 / 75.0, accuracy: 1e-9) // INDEX 01
    }

    func testTrackEndsAtNextTrackStartInSameFile() {
        let sheet = CueSheet(tracks: [
            CueTrack(number: 1, fileName: "a.wav", start: 0),
            CueTrack(number: 2, fileName: "a.wav", start: 100),
            CueTrack(number: 3, fileName: "b.wav", start: 0),
        ])
        XCTAssertEqual(sheet.end(ofTrackAt: 0), 100)
        XCTAssertNil(sheet.end(ofTrackAt: 1)) // next track is a different file
        XCTAssertNil(sheet.end(ofTrackAt: 2)) // last track of the file
        XCTAssertEqual(sheet.duration(ofTrackAt: 0, fileDuration: 500), 100)
        XCTAssertEqual(sheet.duration(ofTrackAt: 2, fileDuration: 180), 180)
        XCTAssertNil(sheet.duration(ofTrackAt: 1, fileDuration: nil))
    }

    func testSerializeParseRoundTrip() {
        let original = CueSheet(title: "Album", performer: "Artist", rem: ["GENRE": "Jazz"], tracks: [
            CueTrack(number: 1, title: "One", fileName: "disc.wav", start: 0),
            CueTrack(number: 2, title: "Two", fileName: "disc.wav", start: 63.5),
        ])
        let reparsed = CueSheet.parse(original.serialized())
        XCTAssertEqual(reparsed.title, original.title)
        XCTAssertEqual(reparsed.performer, original.performer)
        XCTAssertEqual(reparsed.rem["GENRE"], "Jazz")
        XCTAssertEqual(reparsed.tracks.count, 2)
        XCTAssertEqual(reparsed.tracks[1].title, "Two")
        XCTAssertEqual(reparsed.tracks[1].start, 63.5, accuracy: 1.0 / 75.0 + 1e-9)
    }
}
