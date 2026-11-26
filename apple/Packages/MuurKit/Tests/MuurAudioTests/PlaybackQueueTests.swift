import XCTest
import MuurCore
@testable import MuurAudio

final class PlaybackQueueTests: XCTestCase {

    private func items(_ count: Int) -> [QueueItem] {
        (0..<count).map { QueueItem(track: Track(sourceURI: "file:///song\($0).m4a", title: "Song \($0)")) }
    }

    func testStartIndexPicksTheTappedSongWithoutShuffle() {
        let list = items(5)
        var queue = PlaybackQueue(items: list, startIndex: 3, shuffleMode: .off)
        XCTAssertEqual(queue.currentItem?.id, list[3].id)
        XCTAssertEqual(queue.nextItem?.id, list[4].id)
        XCTAssertTrue(queue.back())
        XCTAssertEqual(queue.currentItem?.id, list[2].id)
    }

    func testStartIndexPicksTheTappedSongWithShuffle() {
        let list = items(5)
        let queue = PlaybackQueue(items: list, startIndex: 3, shuffleMode: .on)
        XCTAssertEqual(queue.currentItem?.id, list[3].id)
        XCTAssertEqual(queue.upNext().count, 4)
    }

    func testTurningShuffleOffKeepsTheCurrentSong() {
        let list = items(5)
        var queue = PlaybackQueue(items: list, startIndex: 2, shuffleMode: .on)
        queue.setShuffle(.off)
        XCTAssertEqual(queue.currentItem?.id, list[2].id)
        XCTAssertEqual(queue.nextItem?.id, list[3].id)
    }

    func testFavoriteUpdatesDuplicateEntriesWithoutMovingPlayback() {
        var track = items(1)[0].track
        let other = items(2)[1]
        let list = [QueueItem(track: track), other, QueueItem(track: track)]
        var queue = PlaybackQueue(items: list, startIndex: 2, shuffleMode: .on)
        let order = queue.order
        track.id = 42
        track.favorite = true

        XCTAssertTrue(queue.updateFavorite(from: track, matching: track.libraryKey))
        XCTAssertEqual(queue.items.map(\.track.favorite), [true, false, true])
        XCTAssertEqual(queue.currentTrack?.id, 42)
        XCTAssertEqual(queue.currentItem?.id, list[2].id)
        XCTAssertEqual(queue.order, order)
        XCTAssertFalse(queue.updateFavorite(from: track, matching: track.libraryKey))
    }
}
