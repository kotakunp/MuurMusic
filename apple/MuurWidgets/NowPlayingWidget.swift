import SwiftUI
import WidgetKit
import MuurWidgetKitSupport

/// Now Playing widget (small / medium / large).
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.muur.music.nowplaying", provider: MuurSnapshotProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .muurWidgetBackground()
        }
        .configurationDisplayName("Now Playing")
        .description("Current track, progress and playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuurWidgetEntry

    private var accent: Color { MuurWidgetColors.accent(entry.snapshot.accentHex) }

    var body: some View {
        if let nowPlaying = entry.snapshot.nowPlaying {
            switch family {
            case .systemSmall:
                small(nowPlaying)
                    .widgetURL(MuurDeepLink.nowPlaying)
            case .systemMedium:
                medium(nowPlaying)
            default:
                large(nowPlaying)
            }
        } else {
            MuurEmptyWidget(message: "Nothing playing")
                .widgetURL(MuurDeepLink.nowPlaying)
        }
    }

    private func small(_ nowPlaying: WidgetNowPlaying) -> some View {
        ZStack(alignment: .bottomLeading) {
            MuurArtworkView(fileName: nowPlaying.artworkFileName, cornerRadius: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: nowPlaying.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(accent)
                Text(nowPlaying.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying.artist)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(10)
        }
    }

    private func medium(_ nowPlaying: WidgetNowPlaying) -> some View {
        HStack(spacing: 12) {
            MuurArtworkView(fileName: nowPlaying.artworkFileName)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(nowPlaying.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MuurWidgetColors.text)
                    .lineLimit(1)
                Text(nowPlaying.artist)
                    .font(.caption)
                    .foregroundStyle(MuurWidgetColors.textSecondary)
                    .lineLimit(1)
                if let badge = nowPlaying.formatBadge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                ProgressView(value: progress(nowPlaying))
                    .tint(accent)
                HStack {
                    Text(MuurWidgetFormat.duration(nowPlaying.estimatedElapsed(at: entry.date)))
                    Spacer()
                    Text(MuurWidgetFormat.duration(nowPlaying.duration))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(MuurWidgetColors.textSecondary)
            }
            controlButtons(nowPlaying)
        }
        .padding(12)
    }

    private func controlButtons(_ nowPlaying: WidgetNowPlaying) -> some View {
        VStack(spacing: 10) {
            Link(destination: MuurDeepLink.previous) {
                Image(systemName: "backward.fill")
            }
            Link(destination: MuurDeepLink.playPause) {
                Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(accent, in: Circle())
            }
            Link(destination: MuurDeepLink.next) {
                Image(systemName: "forward.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(MuurWidgetColors.textSecondary)
    }

    private func large(_ nowPlaying: WidgetNowPlaying) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                MuurArtworkView(fileName: nowPlaying.artworkFileName, cornerRadius: 12)
                    .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nowPlaying.title)
                        .font(.headline)
                        .foregroundStyle(MuurWidgetColors.text)
                        .lineLimit(2)
                    Text(nowPlaying.artist)
                        .font(.subheadline)
                        .foregroundStyle(MuurWidgetColors.textSecondary)
                        .lineLimit(1)
                    if !nowPlaying.album.isEmpty {
                        Text(nowPlaying.album)
                            .font(.caption)
                            .foregroundStyle(MuurWidgetColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    ProgressView(value: progress(nowPlaying))
                        .tint(accent)
                }
                controlButtons(nowPlaying)
            }
            if !entry.snapshot.upNext.isEmpty {
                Divider().overlay(MuurWidgetColors.textSecondary.opacity(0.3))
                VStack(alignment: .leading, spacing: 6) {
                    Text("UP NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MuurWidgetColors.textSecondary)
                    ForEach(entry.snapshot.upNext.prefix(2)) { item in
                        HStack(spacing: 8) {
                            MuurArtworkView(fileName: item.artworkFileName, cornerRadius: 4)
                                .frame(width: 28, height: 28)
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
                }
            }
        }
        .padding(14)
    }

    private func progress(_ nowPlaying: WidgetNowPlaying) -> Double {
        guard nowPlaying.duration > 0 else { return 0 }
        return min(max(nowPlaying.estimatedElapsed(at: entry.date) / nowPlaying.duration, 0), 1)
    }
}
