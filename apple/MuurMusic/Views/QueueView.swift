import SwiftUI
import MuurCore
import MuurAudio

/// The play queue: current track plus everything coming up, with reorder/remove.
struct QueueView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

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
                    Section("Up Next") {
                        ForEach(player.queue.upNext()) { item in
                            QueueRow(item: item, isCurrent: false)
                                .onTapGesture {
                                    player.playItem(id: item.id)
                                }
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            player.clearQueue()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
                    #endif
                }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        player.moveInQueue(from: source, to: destination)
    }

    private func delete(at offsets: IndexSet) {
        let items = player.queue.upNext()
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
