import SwiftUI
import MuurCore

/// Online tag lookup: MusicBrainz candidates for a track, apply with one tap.
struct MusicBrainzLookupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let track: Track?

    @State private var candidates: [MusicBrainzRecordingMatch] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var overwrite = false
    @State private var appliedID: String?

    var body: some View {
        NavigationStack {
            Group {
                if track == nil {
                    EmptyStateView(illustration: .search, title: "No track", message: "Pick a single track to look up.")
                } else {
                    content
                }
            }
            .navigationTitle("Look Up Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
        #endif
        .task { await autoSearch() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section("Search") {
                TextField("Title", text: $searchTitle)
                TextField("Artist", text: $searchArtist)
                Button("Search MusicBrainz") {
                    manualSearch()
                }
                .disabled(searchTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("Overwrite existing tags", isOn: $overwrite)
            }

            Section("Matches") {
                if isLoading {
                    HStack {
                        PawProgressView(pawSize: 12)
                        Text("Asking MusicBrainz…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(MuurTheme.danger)
                } else if candidates.isEmpty {
                    Text("No matches found. Try editing the search above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { match in
                        Button {
                            apply(match)
                        } label: {
                            matchRow(match)
                        }
                        .buttonStyle(.plain)
                        .disabled(appliedID != nil)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func matchRow(_ match: MusicBrainzRecordingMatch) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text([match.artist, match.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let year = match.year {
                        Text(String(year))
                    }
                    if let duration = match.duration {
                        Text(MuurFormat.duration(duration))
                    }
                    Text("Score \(match.score)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if appliedID == match.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MuurTheme.success)
            }
        }
        .contentShape(Rectangle())
    }

    private func autoSearch() async {
        guard let track else { return }
        searchTitle = track.displayTitle
        searchArtist = track.artist.isEmpty ? track.albumArtist : track.artist
        isLoading = true
        do {
            candidates = try await model.environment.metadata.candidates(for: track)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func manualSearch() {
        isLoading = true
        Task {
            do {
                candidates = try await model.environment.musicBrainz.searchRecordings(
                    title: searchTitle,
                    artist: searchArtist.isEmpty ? nil : searchArtist,
                    album: nil,
                    duration: nil
                )
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func apply(_ match: MusicBrainzRecordingMatch) {
        guard let track else { return }
        Task {
            do {
                _ = try await model.environment.metadata.apply(
                    match, to: track, overwrite: overwrite, tagEditor: model.environment.tagEditor
                )
                appliedID = match.id
                MuurHaptics.purr(enabled: model.settings.haptics)
                model.showToast(.success("Tags updated from MusicBrainz", systemImage: "checkmark.circle.fill"))
            } catch {
                model.showError(error)
            }
        }
    }
}
