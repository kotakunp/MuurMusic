import Foundation
import SFBAudioEngine

/// What to do with embedded artwork when saving tags.
public enum ArtworkChange: Sendable, Hashable {
    case keep
    case remove
    case replace(Data)
}

/// Fields applied to many tracks at once; nil fields are left unchanged.
public struct BatchTagChanges: Sendable, Hashable {
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var year: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var trackTotal: Int?
    public var rating: Int?
    public var comment: String?
    public var artwork: ArtworkChange

    public init(artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil,
                composer: String? = nil, year: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil,
                trackTotal: Int? = nil, rating: Int? = nil, comment: String? = nil, artwork: ArtworkChange = .keep) {
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.year = year
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.trackTotal = trackTotal
        self.rating = rating
        self.comment = comment
        self.artwork = artwork
    }

    public func apply(to track: inout Track) {
        if let artist { track.artist = artist }
        if let album { track.album = album }
        if let albumArtist { track.albumArtist = albumArtist }
        if let genre { track.genre = genre }
        if let composer { track.composer = composer }
        if let year { track.year = year > 0 ? year : nil }
        if let discNumber { track.discNumber = discNumber > 0 ? discNumber : nil }
        if let discTotal { track.discTotal = discTotal > 0 ? discTotal : nil }
        if let trackTotal { track.trackTotal = trackTotal > 0 ? trackTotal : nil }
        if let rating { track.rating = min(max(rating, 0), 5) }
        if let comment { track.comment = comment }
    }
}

/// Writes tags to local files with SFBAudioEngine (TagLib) and keeps the database in sync.
///
/// Remote tracks and CUE virtual tracks are updated in the database only (their audio files are not
/// rewritten); everything else is written to the file first, then saved.
public final class TagEditor: Sendable {
    public let repository: LibraryRepository
    public let artwork: ArtworkCache
    public let paths: AppPaths

    public init(repository: LibraryRepository, artwork: ArtworkCache, paths: AppPaths) {
        self.repository = repository
        self.artwork = artwork
        self.paths = paths
    }

    /// `true` when the track's file can be rewritten.
    public func canWriteFile(for track: Track) -> Bool {
        guard track.isLocal, !track.isCueTrack, let url = fileURL(for: track) else { return false }
        return AudioFile.handlesPaths(withExtension: url.pathExtension) && FileManager.default.isWritableFile(atPath: url.path)
    }

    func fileURL(for track: Track) -> URL? {
        guard track.isLocal, let url = URL(string: track.sourceURI) else { return nil }
        return paths.resolveStoredFileURL(url)
    }

    /// Saves a track (all editable fields). Returns the stored track.
    @discardableResult
    public func save(_ track: Track, artwork change: ArtworkChange = .keep) async throws -> Track {
        var updated = track
        switch change {
        case .keep: break
        case .remove: updated.artworkKey = nil
        case .replace(let data): updated.artworkKey = artwork.store(data) ?? updated.artworkKey
        }
        if canWriteFile(for: updated), let url = fileURL(for: updated) {
            let snapshot = updated
            try await Task.detached(priority: .userInitiated) {
                try TagEditor.writeTags(snapshot, artwork: change, to: url)
            }.value
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            updated.fileModified = values?.contentModificationDate ?? Date()
            if let size = values?.fileSize { updated.fileSize = Int64(size) }
        }
        try await repository.update(updated)
        return updated
    }

    /// Applies batch changes to several tracks. Returns the updated tracks.
    @discardableResult
    public func apply(_ changes: BatchTagChanges, to tracks: [Track]) async throws -> [Track] {
        var result: [Track] = []
        for track in tracks {
            var updated = track
            changes.apply(to: &updated)
            result.append(try await save(updated, artwork: changes.artwork))
        }
        return result
    }

    /// Writes the track's tag fields into the file at `url`.
    public static func writeTags(_ track: Track, artwork change: ArtworkChange, to url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AudioFile(url: url)
        try file.readPropertiesAndMetadata()
        let metadata = file.metadata
        func value(_ string: String) -> String? { string.isEmpty ? nil : string }
        metadata.title = value(track.title)
        metadata.artist = value(track.artist)
        metadata.albumTitle = value(track.album)
        metadata.albumArtist = value(track.albumArtist)
        metadata.genre = value(track.genre)
        metadata.composer = value(track.composer)
        metadata.releaseDate = track.year.map { String($0) }
        metadata.trackNumber = track.trackNumber
        metadata.trackTotal = track.trackTotal
        metadata.discNumber = track.discNumber
        metadata.discTotal = track.discTotal
        metadata.bpm = track.bpm
        metadata.rating = track.rating > 0 ? track.rating : nil
        metadata.comment = value(track.comment)
        metadata.lyrics = track.lyrics.flatMap(value)
        metadata.musicBrainzRecordingID = track.musicBrainzRecordingID
        metadata.musicBrainzReleaseID = track.musicBrainzReleaseID
        metadata.replayGainTrackGain = track.replayGainTrackGain
        metadata.replayGainTrackPeak = track.replayGainTrackPeak
        metadata.replayGainAlbumGain = track.replayGainAlbumGain
        metadata.replayGainAlbumPeak = track.replayGainAlbumPeak
        switch change {
        case .keep:
            break
        case .remove:
            metadata.removeAllAttachedPictures()
        case .replace(let data):
            metadata.removeAttachedPicturesOfType(.frontCover)
            metadata.attachPicture(AttachedPicture(imageData: data, type: .frontCover))
        }
        file.metadata = metadata
        try file.writeMetadata()
    }
}
