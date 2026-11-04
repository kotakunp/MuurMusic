import Foundation
import MuurWidgetKitSupport

/// Where a set of lyrics came from.
public enum LyricsOrigin: String, Codable, Sendable {
    case embedded, sidecar, lrclib, user
}

/// One line of lyrics. `time` is nil for unsynced lyrics.
public struct LyricLine: Hashable, Sendable, Identifiable, Codable {
    public var id: Int
    public var time: Double?
    public var text: String

    public init(id: Int, time: Double?, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

/// Parsed lyrics (LRC synced or plain text).
public struct Lyrics: Hashable, Sendable, Codable {
    public var lines: [LyricLine]
    public var isSynced: Bool
    public var title: String?
    public var artist: String?
    public var album: String?
    /// The `[offset:]` tag in milliseconds (already applied to line times).
    public var offsetMs: Int
    public var origin: LyricsOrigin?

    public init(lines: [LyricLine], isSynced: Bool, title: String? = nil, artist: String? = nil, album: String? = nil,
                offsetMs: Int = 0, origin: LyricsOrigin? = nil) {
        self.lines = lines
        self.isSynced = isSynced
        self.title = title
        self.artist = artist
        self.album = album
        self.offsetMs = offsetMs
        self.origin = origin
    }

    public var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Lyrics text without timestamps.
    public var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// Index of the line active at `time` (synced lyrics only).
    public func index(at time: Double) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if let lineTime = lines[mid].time, lineTime <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Serializes to LRC (synced) or plain text.
    public func lrcString() -> String {
        var output: [String] = []
        if let title { output.append("[ti:\(title)]") }
        if let artist { output.append("[ar:\(artist)]") }
        if let album { output.append("[al:\(album)]") }
        for line in lines {
            if isSynced, let time = line.time {
                output.append("[\(LRCParser.timestamp(time))]\(line.text)")
            } else {
                output.append(line.text)
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// Lines in the widget snapshot format.
    public var widgetLines: [WidgetLyricLine] {
        lines.map { WidgetLyricLine(time: isSynced ? $0.time : nil, text: $0.text) }
    }
}

/// LRC parser supporting multiple timestamps per line, `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss:xx]`,
/// metadata tags, `[offset:±ms]` and enhanced word timestamps (`<mm:ss.xx>`, stripped).
public enum LRCParser {
    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let tagRegex = try! NSRegularExpression(pattern: #"^\[([A-Za-z]+):(.*)\]$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// Parses LRC text; text without any timestamps is returned as unsynced lyrics.
    public static func parse(_ text: String, origin: LyricsOrigin? = nil) -> Lyrics {
        var timed: [(Double, String)] = []
        var plain: [String] = []
        var title: String?
        var artist: String?
        var album: String?
        var offset = 0
        var sawTimestamp = false

        for rawLine in TextDecoding.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            var times: [Double] = []
            var cursor = 0
            while true {
                guard let match = timestampRegex.firstMatch(in: line, options: [.anchored], range: NSRange(location: cursor, length: ns.length - cursor)) else { break }
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                cursor = match.range.location + match.range.length
            }
            if !times.isEmpty {
                sawTimestamp = true
                var lyric = ns.substring(from: cursor)
                lyric = wordRegex.stringByReplacingMatches(in: lyric, range: NSRange(location: 0, length: (lyric as NSString).length), withTemplate: "")
                lyric = lyric.trimmingCharacters(in: .whitespaces)
                for time in times { timed.append((time, lyric)) }
                continue
            }
            if let tag = tagRegex.firstMatch(in: line, range: fullRange) {
                let key = ns.substring(with: tag.range(at: 1)).lowercased()
                let value = ns.substring(with: tag.range(at: 2)).trimmingCharacters(in: .whitespaces)
                switch key {
                case "ti": title = value
                case "ar": artist = value
                case "al": album = value
                case "offset": offset = Int(value.replacingOccurrences(of: "+", with: "")) ?? 0
                default: break
                }
                continue
            }
            plain.append(rawLine)
        }

        if sawTimestamp {
            let shift = Double(offset) / 1000
            let sorted = timed.enumerated().sorted { lhs, rhs in
                lhs.element.0 == rhs.element.0 ? lhs.offset < rhs.offset : lhs.element.0 < rhs.element.0
            }
            let lines = sorted.enumerated().map { index, item in
                LyricLine(id: index, time: max(0, item.element.0 - shift), text: item.element.1)
            }
            return Lyrics(lines: lines, isSynced: true, title: title, artist: artist, album: album, offsetMs: offset, origin: origin)
        }
        while let last = plain.last, last.trimmingCharacters(in: .whitespaces).isEmpty { plain.removeLast() }
        while let first = plain.first, first.trimmingCharacters(in: .whitespaces).isEmpty { plain.removeFirst() }
        let lines = plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
        return Lyrics(lines: lines, isSynced: false, title: title, artist: artist, album: album, offsetMs: offset, origin: origin)
    }

    /// `mm:ss.xx` timestamp text.
    public static func timestamp(_ time: Double) -> String {
        let centiseconds = Int((max(0, time) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }
}
