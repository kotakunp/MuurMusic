import Foundation
import MuurCore

/// Shared display formatters.
enum MuurFormat {
    /// `m:ss` or `h:mm:ss`.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "3 h 12 min" style.
    static func longDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "44.1 kHz" / "96 kHz".
    static func sampleRate(_ hz: Double) -> String {
        guard hz > 0 else { return "" }
        let khz = hz / 1000
        if khz == khz.rounded() { return "\(Int(khz)) kHz" }
        return String(format: "%.1f kHz", khz)
    }

    /// Full sample-rate/bit-depth description for track info: "24-bit / 96 kHz".
    static func formatDetails(bitDepth: Int, sampleRate: Double, bitrate: Int) -> String {
        var parts: [String] = []
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        let rate = MuurFormat.sampleRate(sampleRate)
        if !rate.isEmpty { parts.append(rate) }
        if parts.isEmpty, bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " / ")
    }

    /// Track format line: "FLAC • 24-bit / 96 kHz • 2 304 kbps".
    static func formatDetails(_ track: Track) -> String {
        var parts: [String] = []
        if !track.codec.isEmpty { parts.append(track.codec.uppercased()) }
        let details = formatDetails(bitDepth: track.bitDepth, sampleRate: track.sampleRate, bitrate: track.bitrate)
        if !details.isEmpty { parts.append(details) }
        if track.channels > 0 { parts.append(track.channels == 1 ? "Mono" : track.channels == 2 ? "Stereo" : "\(track.channels) ch") }
        return parts.joined(separator: " • ")
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// "247 songs · 14 albums · 16 h"
    static func librarySummary(trackCount: Int, albumCount: Int, artistCount: Int, duration: Double) -> String {
        "\(trackCount) songs · \(albumCount) albums · \(artistCount) artists · \(longDuration(duration))"
    }
}
