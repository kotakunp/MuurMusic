import XCTest
@testable import MuurCore

final class LibrarySafetyTests: XCTestCase {
    func testLikeSavesSourceTrackAndUnlikeUsesTheSameLibraryRecord() async throws {
        let database = try MuurDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let sourceTrack = Track(sourceURI: "sftp://music.example/song.flac", title: "Source Song")

        let liked = try await repository.updateFavorite(for: sourceTrack)
        XCTAssertTrue(liked.favorite)
        XCTAssertNotNil(liked.id)

        let unliked = try await repository.updateFavorite(for: sourceTrack, to: false)
        XCTAssertFalse(unliked.favorite)
        XCTAssertEqual(unliked.id, liked.id)
        let count = try await repository.trackCount()
        XCTAssertEqual(count, 1)
    }

    func testUnavailableFolderPreservesRowsUntilACompleteScanConfirmsRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MuurDatabase.inMemory()
        let paths = AppPaths()
        let repository = LibraryRepository(database: database)
        let engine = LibraryScanEngine(database: database, artwork: ArtworkCache(paths: paths), paths: paths)
        let folder = WatchedFolder(name: "Files Provider", path: root.path, bookmark: nil)
        try await repository.save(watchedFolder: folder)
        let uri = SourceURI.file(root.appendingPathComponent("Song.flac"))
        var track = Track(libraryKey: uri, sourceURI: uri, fileName: "Song.flac", title: "Song")
        track.favorite = true
        _ = try await repository.upsert([track])

        let partial = try await engine.scan(folder: folder, full: false, valid: LockedValue(true)) { _ in }
        let preserved = try await repository.track(libraryKey: uri)
        XCTAssertEqual(partial.removed, 0)
        XCTAssertEqual(preserved?.favorite, true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let complete = try await engine.scan(folder: folder, full: false, valid: LockedValue(true)) { _ in }
        let removed = try await repository.track(libraryKey: uri)
        XCTAssertEqual(complete.removed, 1)
        XCTAssertNil(removed)
    }

    @MainActor
    func testDeletingSharedAudioRequiresConfirmationOfEveryTrack() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let database = try MuurDatabase.inMemory()
        let paths = AppPaths()
        let scanner = LibraryScanner(database: database, artwork: ArtworkCache(paths: paths), paths: paths)
        let uri = SourceURI.file(file)
        let tracks = (1...2).map { index in
            Track(libraryKey: "\(uri)#cue=\(index)", sourceURI: uri, fileName: file.lastPathComponent, title: "Track \(index)")
        }
        let stored = try await scanner.repository.upsert(tracks)
        do {
            try await scanner.delete([stored[0]])
            XCTFail("Deleting a shared file requires confirmation for every affected track.")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        let affected = try await scanner.tracksAffectedByDeletion([stored[0]])
        XCTAssertEqual(Set(affected.map(\.libraryKey)), Set(stored.map(\.libraryKey)))
        try await scanner.delete(affected)
        let remaining = try await scanner.repository.tracks(sourceURI: uri)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
