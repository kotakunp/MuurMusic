import SwiftUI
import MuurCore
import MuurAudio

/// The play queue: current track plus everything coming up, with reorder/remove.
struct QueueView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @State private var editMode: EditMode = .inactive
    @State private var confirmsStopping = false

    var body: some View {
        Group {
            if player.queue.isEmpty {
                EmptyStateView(
                    illustration: .library,
                    title: "Queue is empty",
                    message: "Add songs and the cat lines them up here.",
                    systemImage: "list.bullet"
                )
            } else {
                List {
                    if let current = player.queue.currentItem {
                        Section("Now Playing") {
                            QueueRow(item: current, isCurrent: true)
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(player.queue.following) { item in
                            QueueRow(item: item, isCurrent: false)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.playItem(id: item.id)
                                }
                                .listRowBackground(Color.clear)
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    } header: {
                        upNextHeader
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .muurEditMode($editMode)
            }
        }
        .alert("Stop and clear the queue?", isPresented: $confirmsStopping) {
            Button("Cancel", role: .cancel) {}
            Button("Stop and Clear Queue", role: .destructive) {
                editMode = .inactive
                player.clearQueue()
            }
        } message: {
            Text("Playback stops and the queue is emptied.")
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
            Menu {
                Button("Clear Up Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    editMode = .inactive
                    player.clearUpcoming()
                }
                .disabled(player.queue.following.isEmpty)
                Button("Stop and Clear Queue…", systemImage: "stop.circle", role: .destructive) {
                    confirmsStopping = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queue Actions")
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
            ArtworkImage(artworkKey: item.track.artworkKey, cornerRadius: MuurTheme.radiusRow, size: 120)
                .frame(width: 42, height: 42)
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
