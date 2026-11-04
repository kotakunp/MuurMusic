import SwiftUI
import MuurCore
import MuurAudio

/// Synced lyrics with auto-scroll and tap-to-seek, plus a comments/notes tab.
struct LyricsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    let track: Track?

    enum Tab: String, CaseIterable, Identifiable {
        case lyrics = "Lyrics"
        case about = "About"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .lyrics
    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var activeIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .lyrics:
                    lyricsPane
                case .about:
                    aboutPane
                }
            }
        }
        .task(id: track?.libraryKey) { await load() }
    }

    @ViewBuilder
    private var lyricsPane: some View {
        if let lyrics, !lyrics.isEmpty {
            if lyrics.isSynced {
                syncedLyrics(lyrics)
            } else {
                plainLyrics(lyrics)
            }
        } else if isLoading {
            LoadingView(message: "Chasing lyrics…")
        } else {
            EmptyStateView(
                illustration: .search,
                title: "No lyrics found",
                message: model.settings.fetchLyricsOnline
                    ? "The cat looked everywhere — no lyrics for this one."
                    : "Enable “Fetch lyrics online” in Settings to look them up."
            )
        }
    }

    private func syncedLyrics(_ lyrics: Lyrics) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let index = lyrics.index(at: player.position)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title3.weight(line.id == index ? .bold : .regular))
                                .foregroundStyle(line.id == index ? Color(hex: model.settings.accent.hex) : .secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(line.id)
                                .onTapGesture {
                                    if let time = line.time {
                                        player.seek(to: time)
                                    }
                                }
                                .muurPointer()
                        }
                    }
                    .padding(.vertical, 120)
                    .padding(.horizontal, 24)
                }
                .onChange(of: index) { _, newIndex in
                    if let newIndex {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let index {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                // TimelineView re-renders on a clock; silence the unused-date warning by referencing it.
                .accessibilityLabel("Lyrics, synced, \(context.date.formatted(.dateTime.hour().minute()))")
            }
        }
    }

    private func plainLyrics(_ lyrics: Lyrics) -> some View {
        ScrollView {
            Text(lyrics.plainText)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private var aboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let track {
                    LabeledContent("Title", value: track.displayTitle)
                    LabeledContent("Artist", value: track.displayArtist)
                    LabeledContent("Album", value: track.displayAlbum)
                    if let year = track.year {
                        LabeledContent("Year", value: String(year))
                    }
                    if !track.genre.isEmpty {
                        LabeledContent("Genre", value: track.genre)
                    }
                    LabeledContent("Format", value: MuurFormat.formatDetails(track))
                    if !track.comment.isEmpty {
                        Text("Comment")
                            .font(.headline)
                        Text(track.comment)
                            .foregroundStyle(.secondary)
                    }
                    if !track.notes.isEmpty {
                        Text("Notes")
                            .font(.headline)
                        Text(track.notes)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing playing.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard let track else {
            lyrics = nil
            return
        }
        isLoading = true
        let allowOnline = model.settings.fetchLyricsOnline
        lyrics = await model.environment.lyrics.lyrics(for: track, allowOnline: allowOnline)
        isLoading = false
    }
}
