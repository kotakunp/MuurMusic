import SwiftUI
import MuurCore
import MuurAudio

/// The play queue: current track plus everything coming up, with reorder/remove.
struct QueueView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Group {
            if player.queue.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "Queue is empty",
                    message: "Add songs and the cat lines them up here."
                )
            } else {
                List {
                    if let current = player.queue.currentItem {
                        Section("Now Playing") {
                            QueueRow(item: current, isCurrent: true)
                        }
                    }
                    Section {
                        ForEach(player.queue.following) { item in
                            QueueRow(item: item, isCurrent: false)
                                .onTapGesture {
                                    player.playItem(id: item.id)
                                }
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    } header: {
                        upNextHeader
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
                .muurEditMode($editMode)
            }
        }
    }

    // Inline rather than toolbar items: Now Playing hosts this view without a navigation bar.
    private var upNextHeader: some View {
        HStack {
            Text("Up Next")
            Spacer()
            #if os(iOS)
            Button(editMode.isEditing ? "Done" : "Edit") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .disabled(player.queue.following.isEmpty && !editMode.isEditing)
            #endif
            Button("Clear", role: .destructive) {
                editMode = .inactive
                player.clearQueue()
            }
        }
        .font(.subheadline)
        .textCase(nil)
    }

    private func move(from source: IndexSet, to destination: Int) {
        player.moveInQueue(from: source, to: destination)
    }

    private func delete(at offsets: IndexSet) {
        let items = player.queue.following
        let ids = Set(offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        player.removeFromQueue(ids: ids)
    }
}

/// One row in the queue.
struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ArtworkImage(artworkKey: item.track.artworkKey, cornerRadius: 6, size: 120)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.displayTitle)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(item.track.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(MuurFormat.duration(item.track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
