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
}
