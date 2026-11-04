import SwiftUI
import PhotosUI
import MuurCore

/// Tag editor: full editor for one track, batch editor for a selection.
struct TagEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]

    // Single-track fields
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var genre = ""
    @State private var composer = ""
    @State private var yearText = ""
    @State private var trackNumberText = ""
    @State private var trackTotalText = ""
    @State private var discNumberText = ""
    @State private var discTotalText = ""
    @State private var bpmText = ""
    @State private var comment = ""
    @State private var notes = ""

    // Batch fields (empty = unchanged)
    @State private var batchArtist = ""
    @State private var batchAlbum = ""
    @State private var batchAlbumArtist = ""
    @State private var batchGenre = ""
    @State private var batchComposer = ""
    @State private var batchYearText = ""
    @State private var batchRating: Int? = nil

    // Artwork
    @State private var artworkChange: ArtworkChange = .keep
    @State private var artworkPreview: UXImage?
    @State private var pickedPhoto: PhotosPickerItem?

    @State private var isSaving = false

    private var single: Track? { tracks.count == 1 ? tracks.first : nil }

    var body: some View {
        NavigationStack {
            Form {
                if let track = single {
                    singleForm(track)
                } else {
                    batchForm
                }
            }
            .formStyle(.grouped)
            .navigationTitle(single == nil ? "Edit \(tracks.count) Tracks" : "Edit Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
        .onAppear(perform: prefill)
        .onChange(of: pickedPhoto) { _, item in
            loadPickedArtwork(item)
        }
    }

    @ViewBuilder
    private func singleForm(_ track: Track) -> some View {
        Section("Artwork") {
            HStack(spacing: 16) {
                artworkPreviewView(track)
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Choose Image…", systemImage: "photo")
                    }
                    if track.artworkKey != nil || artworkPreview != nil {
                        Button(role: .destructive) {
                            artworkChange = .remove
                            artworkPreview = nil
                        } label: {
                            Label("Remove Artwork", systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }

        Section("Tags") {
            TagField(title: "Title", text: $title)
            TagField(title: "Artist", text: $artist)
            TagField(title: "Album", text: $album)
            TagField(title: "Album Artist", text: $albumArtist)
            TagField(title: "Genre", text: $genre)
            TagField(title: "Composer", text: $composer)
        }

        Section("Numbers") {
            TagField(title: "Year", text: $yearText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            NumberPairField(title: "Track", number: $trackNumberText, total: $trackTotalText)
            NumberPairField(title: "Disc", number: $discNumberText, total: $discTotalText)
            TagField(title: "BPM", text: $bpmText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }

        Section("Notes") {
            TextField("Comment", text: $comment, axis: .vertical)
                .lineLimit(2...5)
            TextField("Private notes (library only)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }

        if !model.environment.tagEditor.canWriteFile(for: track) {
            Section {
                Label("This file is remote — tags are saved to the library only.", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func artworkPreviewView(_ track: Track) -> some View {
        Group {
            switch artworkChange {
            case .keep:
                ArtworkImage(artworkKey: track.artworkKey, cornerRadius: MuurTheme.radiusCard, size: 300)
            case .remove:
                Image("DefaultArtwork")
                    .resizable()
                    .scaledToFill()
            case .replace:
                if let artworkPreview {
                    Image(uxImage: artworkPreview)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("DefaultArtwork")
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: MuurTheme.radiusCard, style: .continuous))
    }

    private var batchForm: some View {
        Group {
            Section("Tags (empty fields stay unchanged)") {
                TagField(title: "Artist", text: $batchArtist)
                TagField(title: "Album", text: $batchAlbum)
                TagField(title: "Album Artist", text: $batchAlbumArtist)
                TagField(title: "Genre", text: $batchGenre)
                TagField(title: "Composer", text: $batchComposer)
                TagField(title: "Year", text: $batchYearText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            Section("Rating") {
                RatingView(rating: batchRating ?? 0, starSize: 20) { value in
                    batchRating = value
                }
                if batchRating != nil {
                    Button("Leave ratings unchanged") { batchRating = nil }
                        .font(.caption)
                }
            }
        }
    }

    private func prefill() {
        guard let track = single else { return }
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        genre = track.genre
        composer = track.composer
        yearText = track.year.map(String.init) ?? ""
        trackNumberText = track.trackNumber.map(String.init) ?? ""
        trackTotalText = track.trackTotal.map(String.init) ?? ""
        discNumberText = track.discNumber.map(String.init) ?? ""
        discTotalText = track.discTotal.map(String.init) ?? ""
        bpmText = track.bpm.map(String.init) ?? ""
        comment = track.comment
        notes = track.notes
    }

    private func loadPickedArtwork(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UXImage.from(data: data) {
                artworkPreview = image
                artworkChange = .replace(data)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                if let track = single {
                    var updated = track
                    updated.title = title.trimmingCharacters(in: .whitespaces)
                    updated.artist = artist.trimmingCharacters(in: .whitespaces)
                    updated.album = album.trimmingCharacters(in: .whitespaces)
                    updated.albumArtist = albumArtist.trimmingCharacters(in: .whitespaces)
                    updated.genre = genre.trimmingCharacters(in: .whitespaces)
                    updated.composer = composer.trimmingCharacters(in: .whitespaces)
                    updated.year = Int(yearText)
                    updated.trackNumber = Int(trackNumberText)
                    updated.trackTotal = Int(trackTotalText)
                    updated.discNumber = Int(discNumberText)
                    updated.discTotal = Int(discTotalText)
                    updated.bpm = Int(bpmText)
                    updated.comment = comment
                    updated.notes = notes
                    _ = try await model.environment.tagEditor.save(updated, artwork: artworkChange)
                } else {
                    let changes = BatchTagChanges(
                        artist: batchArtist.isEmpty ? nil : batchArtist,
                        album: batchAlbum.isEmpty ? nil : batchAlbum,
                        albumArtist: batchAlbumArtist.isEmpty ? nil : batchAlbumArtist,
                        genre: batchGenre.isEmpty ? nil : batchGenre,
                        composer: batchComposer.isEmpty ? nil : batchComposer,
                        year: Int(batchYearText),
                        rating: batchRating,
                        artwork: .keep
                    )
                    _ = try await model.environment.tagEditor.apply(changes, to: tracks)
                }
                MuurHaptics.purr(enabled: model.settings.haptics)
                model.showToast(.success("Tags saved", systemImage: "tag.fill"))
                dismiss()
            } catch {
                model.showError(error)
                isSaving = false
            }
        }
    }
}

/// iOS forms show a text field's title only as a placeholder, which disappears once the field has a value.
private struct TagField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        #if os(iOS)
        LabeledContent(title) {
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
        }
        #else
        TextField(title, text: $text)
        #endif
    }
}

/// "Track 3 of 12" style pair of number fields.
private struct NumberPairField: View {
    let title: String
    @Binding var number: String
    @Binding var total: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("#", text: $number)
                    .multilineTextAlignment(.trailing)
                Text("of")
                    .foregroundStyle(.secondary)
                TextField("Total", text: $total)
                    .frame(maxWidth: 60)
            }
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .labelsHidden()
        }
    }
}
