import Foundation

/// A track inside a CUE sheet.
public struct CueTrack: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var performer: String
    public var songwriter: String
    public var isrc: String?
    /// The audio file this track belongs to (as written in the `FILE` command).
    public var fileName: String
    /// `INDEX 00` (pre-gap start) in seconds, if present.
    public var pregapStart: Double?
    /// `INDEX 01` in seconds from the start of `fileName`.
    public var start: Double
    /// Track-level `REM` entries (upper-cased keys).
    public var rem: [String: String]

    public init(number: Int, title: String = "", performer: String = "", songwriter: String = "", isrc: String? = nil,
                fileName: String, pregapStart: Double? = nil, start: Double, rem: [String: String] = [:]) {
        self.number = number
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.isrc = isrc
        self.fileName = fileName
        self.pregapStart = pregapStart
        self.start = start
        self.rem = rem
    }
}

/// CUE sheet parser / writer (SHARED_FORMATS: 75 frames per second; a track ends at the next track's
/// `INDEX 01` in the same file or at the end of the file).
public struct CueSheet: Hashable, Sendable {
    public static let framesPerSecond = 75.0

    public var title: String
    public var performer: String
    public var songwriter: String
    public var catalog: String?
    /// Disc-level `REM` entries (upper-cased keys), e.g. `GENRE`, `DATE`, `COMMENT`, `REPLAYGAIN_ALBUM_GAIN`.
    public var rem: [String: String]
    public var tracks: [CueTrack]

    public init(title: String = "", performer: String = "", songwriter: String = "", catalog: String? = nil,
                rem: [String: String] = [:], tracks: [CueTrack] = []) {
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.catalog = catalog
        self.rem = rem
        self.tracks = tracks
    }

    public var genre: String? { rem["GENRE"] }
    public var date: String? { rem["DATE"] }

    /// Distinct audio files in order of appearance.
    public var files: [String] {
        var seen = Set<String>()
        return tracks.compactMap { seen.insert($0.fileName).inserted ? $0.fileName : nil }
    }

    // MARK: Time conversion

    /// Seconds for an `mm:ss:ff` index (minutes may exceed 59). Returns nil for malformed input.
    public static func seconds(fromIndex text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frames = Int(parts[2]),
              minutes >= 0, (0..<60).contains(seconds), (0..<75).contains(frames) else { return nil }
        return Double(minutes) * 60 + Double(seconds) + Double(frames) / framesPerSecond
    }

    /// `mm:ss:ff` for a time in seconds (rounded to the nearest frame).
    public static func indexString(seconds: Double) -> String {
        let totalFrames = Int((max(0, seconds) * framesPerSecond).rounded())
        let frames = totalFrames % 75
        let totalSeconds = totalFrames / 75
        return String(format: "%02d:%02d:%02d", totalSeconds / 60, totalSeconds % 60, frames)
    }

    /// End time (seconds) of the track at `index`: the next track's start in the same file, or nil (end of file).
    public func end(ofTrackAt index: Int) -> Double? {
        guard tracks.indices.contains(index) else { return nil }
        let next = index + 1
        guard tracks.indices.contains(next), tracks[next].fileName == tracks[index].fileName else { return nil }
        return tracks[next].start
    }

    /// Duration of the track at `index`, using `fileDuration` for the last track of a file.
    public func duration(ofTrackAt index: Int, fileDuration: Double?) -> Double? {
        guard tracks.indices.contains(index) else { return nil }
        if let end = self.end(ofTrackAt: index) { return max(0, end - tracks[index].start) }
        guard let fileDuration else { return nil }
        return max(0, fileDuration - tracks[index].start)
    }

    // MARK: Parsing

    public static func parse(data: Data) -> CueSheet {
        parse(TextDecoding.decode(data))
    }

    public static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        var currentFile = ""
        var current: CueTrack?

        func flush() {
            if let track = current { sheet.tracks.append(track) }
            current = nil
        }

        for rawLine in TextDecoding.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let tokens = tokenize(line)
            guard let command = tokens.first?.uppercased() else { continue }
            let args = Array(tokens.dropFirst())
            switch command {
            case "REM":
                guard let key = args.first?.uppercased() else { break }
                let value = args.dropFirst().joined(separator: " ")
                if current != nil { current?.rem[key] = value } else { sheet.rem[key] = value }
            case "CATALOG":
                sheet.catalog = args.first
            case "TITLE":
                let value = args.joined(separator: " ")
                if current != nil { current?.title = value } else { sheet.title = value }
            case "PERFORMER":
                let value = args.joined(separator: " ")
                if current != nil { current?.performer = value } else { sheet.performer = value }
            case "SONGWRITER":
                let value = args.joined(separator: " ")
                if current != nil { current?.songwriter = value } else { sheet.songwriter = value }
            case "ISRC":
                current?.isrc = args.first
            case "FILE":
                flush()
                if args.count >= 2 {
                    currentFile = args.dropLast().joined(separator: " ")
                } else {
                    currentFile = args.first ?? ""
                }
            case "TRACK":
                flush()
                let number = args.first.flatMap { Int($0) } ?? (sheet.tracks.count + 1)
                if args.count < 2 || args[1].uppercased() == "AUDIO" {
                    current = CueTrack(number: number, fileName: currentFile, start: -1)
                }
            case "INDEX":
                guard args.count >= 2, let indexNumber = Int(args[0]), let time = seconds(fromIndex: args[1]) else { break }
                if indexNumber == 1 { current?.start = time }
                if indexNumber == 0 { current?.pregapStart = time }
            default:
                break
            }
        }
        flush()
        sheet.tracks = sheet.tracks.compactMap { track in
            var fixed = track
            if fixed.start < 0 {
                guard let pregap = fixed.pregapStart else { return nil }
                fixed.start = pregap
            }
            return fixed
        }
        return sheet
    }

    /// Splits a CUE line into tokens, honouring double quotes.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hadQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                hadQuotes = true
                continue
            }
            if character.isWhitespace && !inQuotes {
                if !current.isEmpty || hadQuotes { tokens.append(current) }
                current = ""
                hadQuotes = false
                continue
            }
            current.append(character)
        }
        if !current.isEmpty || hadQuotes { tokens.append(current) }
        return tokens
    }

    // MARK: Writing

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    /// Serializes the sheet in standard CUE syntax.
    public func serialized() -> String {
        var lines: [String] = []
        for key in rem.keys.sorted() {
            let value = rem[key] ?? ""
            let needsQuotes = value.contains(" ") && !(key.hasPrefix("REPLAYGAIN"))
            lines.append("REM \(key) \(needsQuotes ? CueSheet.quoted(value) : value)")
        }
        if let catalog { lines.append("CATALOG \(catalog)") }
        if !performer.isEmpty { lines.append("PERFORMER \(CueSheet.quoted(performer))") }
        if !songwriter.isEmpty { lines.append("SONGWRITER \(CueSheet.quoted(songwriter))") }
        if !title.isEmpty { lines.append("TITLE \(CueSheet.quoted(title))") }
        var lastFile: String?
        for track in tracks {
            if track.fileName != lastFile {
                let type = ["mp3"].contains(PathUtils.fileExtension(track.fileName)) ? "MP3" : "WAVE"
                lines.append("FILE \(CueSheet.quoted(track.fileName)) \(type)")
                lastFile = track.fileName
            }
            lines.append(String(format: "  TRACK %02d AUDIO", track.number))
            if !track.title.isEmpty { lines.append("    TITLE \(CueSheet.quoted(track.title))") }
            if !track.performer.isEmpty { lines.append("    PERFORMER \(CueSheet.quoted(track.performer))") }
            if !track.songwriter.isEmpty { lines.append("    SONGWRITER \(CueSheet.quoted(track.songwriter))") }
            if let isrc = track.isrc { lines.append("    ISRC \(isrc)") }
            for key in track.rem.keys.sorted() {
                lines.append("    REM \(key) \(track.rem[key] ?? "")")
            }
            if let pregap = track.pregapStart { lines.append("    INDEX 00 \(CueSheet.indexString(seconds: pregap))") }
            lines.append("    INDEX 01 \(CueSheet.indexString(seconds: track.start))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
