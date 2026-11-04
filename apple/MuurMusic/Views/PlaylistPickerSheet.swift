import SwiftUI
import MuurCore

/// Sheet that adds tracks to an existing playlist or creates a new one.
struct PlaylistPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]

    @State private var newName = ""
    @State private var isSaving = false

    private var regularPlaylists: [Playlist] {
        model.playlists.filter { !$0.isSmart }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist name", text: $newName)
                        #if os(iOS)
                            .textInputAutocapitalization(.words)
                        #endif
                        Button("Create") {
                            createAndAdd()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    }
                }
                Section("Playlists") {
                    if regularPlaylists.isEmpty {
                        Text("No playlists yet — create one above.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(regularPlaylists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 420)
        #endif
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isSaving = true
        Task {
            do {
                let playlist = try await model.environment.playlists.create(name: name, tracks: tracks)
                MuurHaptics.purr(enabled: model.settings.haptics)
                model.showToast(.success("Added to \(playlist.name)", systemImage: "music.note.list"))
                dismiss()
            } catch {
                model.showError(error)
                isSaving = false
            }
        }
    }

    private func add(to playlist: Playlist) {
        guard let id = playlist.id else { return }
        isSaving = true
        Task {
            do {
                try await model.environment.playlists.add(tracks, to: id)
                MuurHaptics.tap(enabled: model.settings.haptics)
                model.showToast(.success("Added to \(playlist.name)", systemImage: "music.note.list"))
                dismiss()
            } catch {
                model.showError(error)
                isSaving = false
            }
        }
    }
}
