import SwiftUI
import WidgetKit
import MuurWidgetKitSupport

/// Up Next queue widget (medium / large).
struct QueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.muur.music.queue", provider: MuurSnapshotProvider()) { entry in
            QueueWidgetView(entry: entry)
                .muurWidgetBackground()
        }
        .configurationDisplayName("Up Next")
        .description("The tracks coming up in your queue.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct QueueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuurWidgetEntry

    private var accent: Color { MuurWidgetColors.accent(entry.snapshot.accentHex) }

    var body: some View {
        let items = entry.snapshot.upNext
        if items.isEmpty {
            MuurEmptyWidget(message: "Queue is empty")
                .widgetURL(MuurDeepLink.nowPlaying)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("UP NEXT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                    Spacer()
                    Image(systemName: "list.bullet")
                        .font(.caption)
                        .foregroundStyle(MuurWidgetColors.textSecondary)
                }
                ForEach(items.prefix(family == .systemLarge ? 5 : 3)) { item in
                    HStack(spacing: 8) {
                        MuurArtworkView(fileName: item.artworkFileName, cornerRadius: 4)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(MuurWidgetColors.text)
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.caption2)
                                .foregroundStyle(MuurWidgetColors.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(MuurWidgetFormat.duration(item.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(MuurWidgetColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .widgetURL(MuurDeepLink.nowPlaying)
        }
    }
}

/// Resume widget: one-tap continue where you left off.
struct ResumeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.muur.music.resume", provider: MuurSnapshotProvider()) { entry in
            ResumeWidgetView(entry: entry)
                .muurWidgetBackground()
        }
        .configurationDisplayName("Resume")
        .description("Jump back into your last session.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ResumeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuurWidgetEntry

    private var accent: Color { MuurWidgetColors.accent(entry.snapshot.accentHex) }

    var body: some View {
        if entry.snapshot.canResume, let nowPlaying = entry.snapshot.nowPlaying {
            content(nowPlaying)
                .widgetURL(MuurDeepLink.resume)
        } else if let recent = entry.snapshot.recentlyPlayed.first {
            recentSmall(recent)
                .widgetURL(MuurDeepLink.nowPlaying)
        } else {
            MuurEmptyWidget(message: "Play something first")
                .widgetURL(MuurDeepLink.nowPlaying)
        }
    }

    private func content(_ nowPlaying: WidgetNowPlaying) -> some View {
        HStack(spacing: 10) {
            MuurArtworkView(fileName: nowPlaying.artworkFileName)
                .frame(width: family == .systemSmall ? 56 : 64, height: family == .systemSmall ? 56 : 64)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(accent)
                    Text("RESUME")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                }
                Text(nowPlaying.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuurWidgetColors.text)
                    .lineLimit(2)
                Text(nowPlaying.artist)
                    .font(.caption2)
                    .foregroundStyle(MuurWidgetColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(family == .systemSmall ? 10 : 14)
    }

    private func recentSmall(_ item: WidgetQueueItem) -> some View {
        HStack(spacing: 10) {
            MuurArtworkView(fileName: item.artworkFileName)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("LAST PLAYED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MuurWidgetColors.textSecondary)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuurWidgetColors.text)
                    .lineLimit(2)
                Text(item.artist)
                    .font(.caption2)
                    .foregroundStyle(MuurWidgetColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

/// Synced lyrics widget (medium / large).
struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.muur.music.lyrics", provider: MuurSnapshotProvider()) { entry in
            LyricsWidgetView(entry: entry)
                .muurWidgetBackground()
        }
        .configurationDisplayName("Lyrics")
        .description("Follow the words as the song plays.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct LyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuurWidgetEntry

    private var accent: Color { MuurWidgetColors.accent(entry.snapshot.accentHex) }

    var body: some View {
        let snapshot = entry.snapshot
        if snapshot.lyrics.isEmpty {
            MuurEmptyWidget(message: "No lyrics for this track")
                .widgetURL(MuurDeepLink.nowPlaying)
        } else {
            HStack(spacing: 12) {
                if let nowPlaying = snapshot.nowPlaying {
                    MuurArtworkView(fileName: nowPlaying.artworkFileName, cornerRadius: 8)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    lyricLines(snapshot)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .widgetURL(MuurDeepLink.nowPlaying)
        }
    }

    @ViewBuilder
    private func lyricLines(_ snapshot: WidgetSnapshot) -> some View {
        let elapsed = snapshot.nowPlaying?.estimatedElapsed(at: entry.date) ?? 0
        let currentIndex = snapshot.lyricsAreSynced ? snapshot.lyricIndex(at: elapsed) : nil
        let visible = visibleLines(snapshot, currentIndex: currentIndex)
        ForEach(Array(visible.enumerated()), id: \.offset) { offset, line in
            let isCurrent = line.index == currentIndex
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(isCurrent ? .subheadline.weight(.bold) : .caption)
                .foregroundStyle(isCurrent ? accent : MuurWidgetColors.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, offset == 0 ? 0 : 1)
        }
    }

    private func visibleLines(_ snapshot: WidgetSnapshot, currentIndex: Int?) -> [(index: Int, text: String)] {
        let maxLines = family == .systemLarge ? 6 : 3
        if let currentIndex {
            let start = max(currentIndex - 1, 0)
            return (start..<min(start + maxLines, snapshot.lyrics.count)).map { ($0, snapshot.lyrics[$0].text) }
        }
        return (0..<min(maxLines, snapshot.lyrics.count)).map { ($0, snapshot.lyrics[$0].text) }
    }
}
