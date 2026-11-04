import Foundation
import AVFoundation
import SFBAudioEngine

/// Tags and audio properties read from a file.
public struct AudioFileMetadata: Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var bpm: Int?
    /// 0...5 stars.
    public var rating: Int?
    public var comment: String?
    public var lyrics: String?
    public var isrc: String?
    public var isCompilation: Bool
    public var musicBrainzRecordingID: String?
    public var musicBrainzReleaseID: String?
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int
    /// kbit/s.
    public var bitrate: Int
    public var codec: String
    public var frontCover: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, composer: String? = nil, year: Int? = nil, trackNumber: Int? = nil,
                trackTotal: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil, bpm: Int? = nil, rating: Int? = nil,
                comment: String? = nil, lyrics: String? = nil, isrc: String? = nil, isCompilation: Bool = false,
                musicBrainzRecordingID: String? = nil, musicBrainzReleaseID: String? = nil,
                replayGainTrackGain: Double? = nil, replayGainTrackPeak: Double? = nil,
                replayGainAlbumGain: Double? = nil, replayGainAlbumPeak: Double? = nil, duration: Double = 0,
                sampleRate: Double = 0, bitDepth: Int = 0, channels: Int = 0, bitrate: Int = 0, codec: String = "",
                frontCover: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.bpm = bpm
        self.rating = rating
        self.comment = comment
        self.lyrics = lyrics
        self.isrc = isrc
        self.isCompilation = isCompilation
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.bitrate = bitrate
        self.codec = codec
        self.frontCover = frontCover
    }

    /// Copies the tag values onto a track (keeping user data and identity).
    public func apply(to track: inout Track) {
        track.title = (title?.isEmpty == false ? title : nil) ?? PathUtils.titleFromFileName(track.fileName)
        track.artist = artist ?? ""
        track.album = album ?? ""
        track.albumArtist = albumArtist ?? (isCompilation ? "Various Artists" : "")
        track.genre = genre ?? ""
        track.composer = composer ?? ""
        track.year = year
        track.trackNumber = trackNumber
        track.trackTotal = trackTotal
        track.discNumber = discNumber
        track.discTotal = discTotal
        track.bpm = bpm
        if let rating, rating > 0 { track.rating = rating }
        track.comment = comment ?? ""
        track.lyrics = lyrics
        track.hasLyrics = track.hasLyrics || !(lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        track.musicBrainzRecordingID = musicBrainzRecordingID
        track.musicBrainzReleaseID = musicBrainzReleaseID
        track.replayGainTrackGain = replayGainTrackGain
        track.replayGainTrackPeak = replayGainTrackPeak
        track.replayGainAlbumGain = replayGainAlbumGain
        track.replayGainAlbumPeak = replayGainAlbumPeak
        if duration > 0 { track.duration = duration }
        track.sampleRate = sampleRate
        track.bitDepth = bitDepth
        track.channels = channels
        track.bitrate = bitrate
        track.codec = codec
    }
}

/// Reads tags and audio properties with SFBAudioEngine (TagLib), falling back to AVFoundation.
public enum MetadataReader {
    /// Reads metadata; returns nil when neither SFBAudioEngine nor AVFoundation can open the file.
    public static func read(url: URL) async -> AudioFileMetadata? {
        if let metadata = readWithSFB(url: url) { return metadata }
        return await readWithAVFoundation(url: url)
    }

    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: ""),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Reads via SFBAudioEngine.
    public static func readWithSFB(url: URL) -> AudioFileMetadata? {
        let file: AudioFile
        do {
            file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        } catch {
            Log.metadata.debug("SFB could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let tags = file.metadata
        let properties = file.properties
        var result = AudioFileMetadata()
        result.title = clean(tags.title)
        result.artist = clean(tags.artist)
        result.album = clean(tags.albumTitle)
        result.albumArtist = clean(tags.albumArtist)
        result.genre = clean(tags.genre)
        result.composer = clean(tags.composer)
        result.year = DateParsing.year(from: tags.releaseDate)
        result.trackNumber = tags.trackNumber.flatMap { $0 > 0 ? $0 : nil }
        result.trackTotal = tags.trackTotal.flatMap { $0 > 0 ? $0 : nil }
        result.discNumber = tags.discNumber.flatMap { $0 > 0 ? $0 : nil }
        result.discTotal = tags.discTotal.flatMap { $0 > 0 ? $0 : nil }
        result.bpm = tags.bpm.flatMap { $0 > 0 ? $0 : nil }
        result.rating = tags.rating.map(normalizeRating)
        result.comment = clean(tags.comment)
        result.lyrics = clean(tags.lyrics)
        result.isrc = clean(tags.isrc)
        result.isCompilation = tags.isCompilation ?? false
        result.musicBrainzRecordingID = clean(tags.musicBrainzRecordingID)
        result.musicBrainzReleaseID = clean(tags.musicBrainzReleaseID)
        result.replayGainTrackGain = tags.replayGainTrackGain
        result.replayGainTrackPeak = tags.replayGainTrackPeak
        result.replayGainAlbumGain = tags.replayGainAlbumGain
        result.replayGainAlbumPeak = tags.replayGainAlbumPeak
        result.duration = properties.duration ?? 0
        result.sampleRate = properties.sampleRate ?? 0
        result.bitDepth = properties.bitDepth ?? 0
        result.channels = properties.channelCount.map { Int($0) } ?? 0
        let ext = PathUtils.fileExtension(url.lastPathComponent)
        result.codec = normalizeCodec(properties.formatName, fileExtension: ext, bitDepth: result.bitDepth)
        if let bitrate = properties.bitrate, bitrate > 0 {
            result.bitrate = Int(bitrate.rounded())
        } else if result.duration > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            result.bitrate = Int(Double(size) * 8 / 1000 / result.duration)
        }
        if result.codec == "DSD" { result.bitDepth = 1 }
        let pictures = tags.attachedPictures(ofType: .frontCover)
        result.frontCover = pictures.first?.imageData ?? tags.attachedPictures.first?.imageData
        return result
    }

    /// Converts ratings stored as 0-5, 0-10, 0-100 or 0-255 (POPM) to stars.
    static func normalizeRating(_ raw: Int) -> Int {
        switch raw {
        case ...0: return 0
        case 1...5: return raw
        case 6...10: return Int((Double(raw) / 2).rounded())
        case 11...100: return Int((Double(raw) / 20).rounded())
        default: return min(5, Int((Double(raw) / 51).rounded()))
        }
    }

    /// Short codec names shared with the Windows app ("FLAC", "ALAC", "AAC", "MP3", "WAV", "AIFF", "DSD", ...).
    public static func normalizeCodec(_ formatName: String?, fileExtension ext: String, bitDepth: Int = 0) -> String {
        let name = (formatName ?? "").lowercased()
        if name.contains("flac") || ext == "flac" { return "FLAC" }
        if name.contains("lossless") || name.contains("alac") || ext == "alac" { return "ALAC" }
        if name.contains("dsd") || name.contains("dsf") || name.contains("dsdiff") || ["dsf", "dff", "dsd"].contains(ext) { return "DSD" }
        if name.contains("layer 3") || name.contains("mp3") || ext == "mp3" { return "MP3" }
        if name.contains("layer 2") || ext == "mp2" { return "MP2" }
        if name.contains("opus") || ext == "opus" { return "OPUS" }
        if name.contains("vorbis") || ext == "ogg" || ext == "oga" { return "OGG" }
        if name.contains("monkey") || ext == "ape" { return "APE" }
        if name.contains("wavpack") || ext == "wv" { return "WV" }
        if name.contains("musepack") || ext == "mpc" { return "MPC" }
        if name.contains("true audio") || ext == "tta" { return "TTA" }
        if name.contains("shorten") || ext == "shn" { return "SHN" }
        if name.contains("aac") { return "AAC" }
        if name.contains("wav") || ["wav", "wave", "w64", "rf64"].contains(ext) { return "WAV" }
        if name.contains("aif") || ["aif", "aiff", "aifc"].contains(ext) { return "AIFF" }
        if ["mod", "xm", "it", "s3m", "mtm", "669", "amf"].contains(ext) { return ext.uppercased() }
        if ["m4a", "m4b", "mp4", "m4p"].contains(ext) { return bitDepth > 0 ? "ALAC" : "AAC" }
        if ext == "caf" { return "CAF" }
        return ext.isEmpty ? (formatName ?? "") : ext.uppercased()
    }

    /// Reads via AVFoundation (used for files SFBAudioEngine cannot open, e.g. some MP4 variants).
    public static func readWithAVFoundation(url: URL) async -> AudioFileMetadata? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            var result = AudioFileMetadata()
            result.duration = duration.seconds.isFinite ? duration.seconds : 0
            let items = try await asset.load(.commonMetadata)
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: result.title = clean(try? await item.load(.stringValue))
                case .commonKeyArtist: result.artist = clean(try? await item.load(.stringValue))
                case .commonKeyAlbumName: result.album = clean(try? await item.load(.stringValue))
                case .commonKeyCreator: result.composer = clean(try? await item.load(.stringValue))
                case .commonKeyType: result.genre = clean(try? await item.load(.stringValue))
                case .commonKeyCreationDate: result.year = DateParsing.year(from: try? await item.load(.stringValue))
                case .commonKeyDescription: result.comment = clean(try? await item.load(.stringValue))
                case .commonKeyArtwork:
                    if result.frontCover == nil { result.frontCover = try? await item.load(.dataValue) }
                default: break
                }
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let rate = try await track.load(.estimatedDataRate)
                result.bitrate = Int((Double(rate) / 1000).rounded())
                let descriptions = try await track.load(.formatDescriptions)
                if let description = descriptions.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    result.sampleRate = asbd.mSampleRate
                    result.channels = Int(asbd.mChannelsPerFrame)
                    result.bitDepth = Int(asbd.mBitsPerChannel)
                    let subtype = CMFormatDescriptionGetMediaSubType(description)
                    switch subtype {
                    case kAudioFormatAppleLossless: result.codec = "ALAC"
                    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: result.codec = "AAC"
                    case kAudioFormatMPEGLayer3: result.codec = "MP3"
                    case kAudioFormatFLAC: result.codec = "FLAC"
                    case kAudioFormatOpus: result.codec = "OPUS"
                    case kAudioFormatLinearPCM: result.codec = normalizeCodec(nil, fileExtension: PathUtils.fileExtension(url.lastPathComponent))
                    case kAudioFormatAC3, kAudioFormatEnhancedAC3: result.codec = "AC3"
                    default: result.codec = normalizeCodec(nil, fileExtension: PathUtils.fileExtension(url.lastPathComponent))
                    }
                }
            }
            if result.codec.isEmpty {
                result.codec = normalizeCodec(nil, fileExtension: PathUtils.fileExtension(url.lastPathComponent), bitDepth: result.bitDepth)
            }
            return result
        } catch {
            Log.metadata.debug("AVFoundation could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Duration in seconds using the cheapest available reader.
    public static func duration(of url: URL) async -> Double? {
        if let file = try? AudioFile(readingPropertiesAndMetadataFrom: url), let duration = file.properties.duration, duration > 0 {
            return duration
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return nil }
        return duration.seconds
    }
}
