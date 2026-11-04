import SwiftUI
import WidgetKit
import MuurWidgetKitSupport

// MARK: - Brand colors (kept local: the widget target links only MuurWidgetKitSupport)

enum MuurWidgetColors {
    static let bg = Color(hex: "#17122B")
    static let bgElevated = Color(hex: "#211A3D")
    static let text = Color(hex: "#F5F2FF")
    static let textSecondary = Color(hex: "#A79FC7")

    static func accent(_ hex: String) -> Color {
        hex.isEmpty ? Color(hex: "#FFB23F") : Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

// MARK: - Deep links (must match the app's muurmusic:// scheme)

enum MuurDeepLink {
    static let nowPlaying = URL(string: "muurmusic://nowplaying")!
    static let playPause = URL(string: "muurmusic://playpause")!
    static let next = URL(string: "muurmusic://next")!
    static let previous = URL(string: "muurmusic://previous")!
    static let resume = URL(string: "muurmusic://resume")!
}

// MARK: - Artwork

enum MuurWidgetArtwork {
    static func image(_ fileName: String?) -> Image? {
        guard let url = WidgetSharedStore().artworkURL(fileName: fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - Timeline

struct MuurWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Reads the shared snapshot written by the app (works with the app not running).
struct MuurSnapshotProvider: TimelineProvider {
    let store = WidgetSharedStore()

    func placeholder(in context: Context) -> MuurWidgetEntry {
        MuurWidgetEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (MuurWidgetEntry) -> Void) {
        completion(MuurWidgetEntry(date: .now, snapshot: store.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MuurWidgetEntry>) -> Void) {
        let snapshot = store.read()
        let now = Date()
        var reloadDate = now.addingTimeInterval(30 * 60)
        if let nowPlaying = snapshot.nowPlaying, nowPlaying.isPlaying {
            let remaining = nowPlaying.duration - nowPlaying.estimatedElapsed(at: now)
            if remaining > 5 {
                reloadDate = now.addingTimeInterval(min(remaining + 2, 30 * 60))
            } else if snapshot.lyricsAreSynced {
                reloadDate = now.addingTimeInterval(30)
            }
        }
        completion(Timeline(entries: [MuurWidgetEntry(date: now, snapshot: snapshot)], policy: .after(reloadDate)))
    }
}

// MARK: - Shared subviews

struct MuurWidgetBackground: View {
    var body: some View {
        MuurWidgetColors.bg
    }
}

struct MuurArtworkView: View {
    let fileName: String?
    var cornerRadius: CGFloat = 8

    var body: some View {
        if let image = MuurWidgetArtwork.image(fileName) {
            image
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            Image("DefaultArtwork")
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct MuurEmptyWidget: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            Text(message)
                .font(.caption)
                .foregroundStyle(MuurWidgetColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Widget container background with the brand color.
    @ViewBuilder
    func muurWidgetBackground() -> some View {
        containerBackground(for: .widget) {
            MuurWidgetBackground()
        }
    }
}

/// Small time formatter for widgets.
enum MuurWidgetFormat {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
