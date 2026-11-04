import SwiftUI
import MuurCore
import MuurAudio

/// Download queue and completed downloads, plus cache management.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    @State private var items: [DownloadItem] = []
    @State private var isWaitingForWiFi = false
    @State private var cacheBytes: Int64 = 0

    private var downloads: DownloadManager { model.environment.downloads }

    private var active: [DownloadItem] {
        items.filter { $0.state != .completed }
    }

    private var completed: [DownloadItem] {
        items.filter { $0.state == .completed }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(MuurFormat.bytes(downloads.totalDownloadedBytes))
                            .font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Stream cache")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(MuurFormat.bytes(cacheBytes))
                            .font(.headline)
                    }
                }
                if isWaitingForWiFi {
                    Label("Waiting for Wi-Fi — enable “Download over Cellular” in Settings to continue.", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(MuurTheme.accentAmber)
                }
            }

            if !active.isEmpty {
                Section("Queue") {
                    ForEach(active) { item in
                        DownloadRow(item: item)
                    }
                }
            }

            Section("Completed") {
                if completed.isEmpty && active.isEmpty {
                    Text("Nothing downloaded yet. Use the download action on any remote track, album or folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(completed) { item in
                    CompletedRow(item: item)
                }
            }

            Section("Storage") {
                Button {
                    clearCache()
                } label: {
                    Label("Clear Stream Cache", systemImage: "trash")
                }
                Button(role: .destructive) {
                    removeCompleted()
                } label: {
                    Label("Remove All Downloads", systemImage: "trash.fill")
                }
                .disabled(completed.isEmpty)
            }
        }
        .muurScreen()
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button {
                        Task { await downloads.pauseAll() }
                    } label: {
                        Image(systemName: "pause.circle")
                    }
                    .accessibilityLabel("Pause all")
                    Button {
                        Task { await downloads.resumeAll() }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .accessibilityLabel("Resume all")
                }
            }
        }
        .onReceive(downloads.$items) { items = $0 }
        .onReceive(downloads.$isWaitingForWiFi) { isWaitingForWiFi = $0 }
        .task { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        cacheBytes = await model.environment.audioCache.totalBytes
    }

    private func clearCache() {
        Task {
            await model.environment.audioCache.clear()
            await refreshCacheSize()
            model.showToast(.success("Cache cleared", systemImage: "trash"))
        }
    }

    private func removeCompleted() {
        Task {
            await downloads.removeAll(in: [.completed])
            model.showToast(.success("Downloads removed", systemImage: "trash"))
        }
    }
}

/// Active download row with progress and controls.
struct DownloadRow: View {
    @EnvironmentObject var model: AppModel

    let item: DownloadItem

    private var downloads: DownloadManager { model.environment.downloads }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                controls
            }
            if item.state == .downloading {
                ProgressView(value: item.progress)
                    .tint(MuurTheme.accentAmber)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch item.state {
        case .queued: return "Queued"
        case .downloading:
            return "\(MuurFormat.bytes(item.bytesReceived)) of \(MuurFormat.bytes(item.bytesExpected))"
        case .paused: return "Paused"
        case .failed: return item.errorMessage ?? "Failed"
        case .completed: return "Done"
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .queued, .downloading:
                Button {
                    Task { await downloads.pause(item.id) }
                } label: {
                    Image(systemName: "pause.fill")
                }
                .accessibilityLabel("Pause")
            case .paused:
                Button {
                    Task { await downloads.resume(item.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .accessibilityLabel("Resume")
            case .failed:
                Button {
                    Task { await downloads.retry(item.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Retry")
            case .completed:
                EmptyView()
            }
            Button {
                Task { await downloads.remove(item.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Completed download row — tap to play.
struct CompletedRow: View {
    @EnvironmentObject var model: AppModel

    let item: DownloadItem

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MuurTheme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.artist.isEmpty ? MuurFormat.bytes(item.bytesReceived) : item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { play() }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await model.environment.downloads.remove(item.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func play() {
        guard let trackID = item.trackId else { return }
        Task {
            do {
                if let track = try await model.environment.database.read({ db in
                    try LibraryQueries.track(db, id: trackID)
                }) {
                    model.play([track])
                }
            } catch {
                model.showError(error)
            }
        }
    }
}
