import XCTest
@testable import MuurCore

final class PlaylistFormatTests: XCTestCase {

    func testM3UParsesExtendedEntries() {
        let text = """
        #EXTM3U
        #EXTINF:243,Artist Name - Song Title
        subfolder/song.flac
        #EXTINF:-1,Stream Only Title
        https://example.com/stream.mp3
        plain.aac
        """
        let entries = M3UPlaylist.parse(text, baseURI: nil)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].duration, 243)
        XCTAssertEqual(entries[0].artist, "Artist Name")
        XCTAssertEqual(entries[0].title, "Song Title")
        XCTAssertEqual(entries[0].location, "subfolder/song.flac")
        XCTAssertNil(entries[1].duration) // -1 means unknown
        XCTAssertEqual(entries[1].title, "Stream Only Title")
        XCTAssertNil(entries[1].artist)
        XCTAssertEqual(entries[2].location, "plain.aac")
        XCTAssertNil(entries[2].title)
    }

    func testM3URelativePathsResolveAgainstFileBase() {
        let base = "file:///Music/Mix/playlist.m3u"
        let text = "subfolder/song.flac\n../shared/other.wav\n/disk/abs.mp3\n"
        let entries = M3UPlaylist.parse(text, baseURI: base)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].resolvedURI, "file:///Music/Mix/subfolder/song.flac")
        XCTAssertEqual(entries[1].resolvedURI, "file:///Music/shared/other.wav")
        XCTAssertEqual(entries[2].resolvedURI, "file:///disk/abs.mp3")
    }

    func testM3URelativePathsResolveAgainstRemoteBase() {
        let base = "smb://nas/music/playlists/chill.m3u"
        let entries = M3UPlaylist.parse("tracks/a.flac\n", baseURI: base)
        XCTAssertEqual(entries[0].resolvedURI, "smb://nas/music/playlists/tracks/a.flac")
    }

    func testM3UWindowsAndRemotePathsStayUnresolvable() {
        let text = "C:\\Music\\song.mp3\n"
        let entries = M3UPlaylist.parse(text, baseURI: "file:///Music/Mix/playlist.m3u")
        XCTAssertNil(entries[0].resolvedURI) // Windows-absolute paths cannot map to the local filesystem
        let remote = M3UPlaylist.parse("https://example.com/a.mp3\n", baseURI: nil)
        XCTAssertEqual(remote[0].resolvedURI, "https://example.com/a.mp3")
    }

    func testM3UWriteRoundTripsWithRelativeLocations() {
        let playlistURI = "file:///Music/Mix/playlist.m3u"
        let items = [
            PlaylistWriteItem(uri: "file:///Music/Mix/sub/a.flac", duration: 243.4, artist: "Artist", title: "Song"),
            PlaylistWriteItem(uri: "file:///Other/b.mp3", duration: 60, artist: "", title: "Outside"),
        ]
        let text = M3UPlaylist.write(items, playlistURI: playlistURI)
        XCTAssertTrue(text.hasPrefix("#EXTM3U"))
        XCTAssertTrue(text.contains("#EXTINF:243,Artist - Song"))
        let entries = M3UPlaylist.parse(text, baseURI: playlistURI)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].resolvedURI, "file:///Music/Mix/sub/a.flac") // written relative, resolved back
        XCTAssertEqual(entries[0].artist, "Artist")
        XCTAssertEqual(entries[0].duration, 243)
        XCTAssertEqual(entries[1].resolvedURI, "file:///Other/b.mp3") // outside the playlist folder: absolute path
    }

    func testPLSParsesEntries() {
        let text = """
        [playlist]
        NumberOfEntries=2
        File1=track one.mp3
        Title1=First Song
        Length1=120
        File2=https://example.com/live
        Title2=Live Stream
        Length2=-1
        """
        let entries = PLSPlaylist.parse(text, baseURI: "file:///Music/Mix/list.pls")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "First Song")
        XCTAssertEqual(entries[0].duration, 120)
        XCTAssertEqual(entries[0].resolvedURI, "file:///Music/Mix/track%20one.mp3") // file URLs percent-encode spaces
        XCTAssertEqual(entries[1].resolvedURI, "https://example.com/live")
        XCTAssertNil(entries[1].duration)
    }

    func testNormalizeRemovesDotComponents() {
        XCTAssertEqual(PlaylistPathResolver.normalize("/a/b/../c/./d"), "/a/c/d")
        XCTAssertEqual(PlaylistPathResolver.normalize("a//b/"), "/a/b")
        XCTAssertEqual(PlaylistPathResolver.normalize("/../../x"), "/x")
    }
}
