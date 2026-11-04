import SwiftUI
import MuurCore
import MuurAudio

/// Manage music sources: local folders, cloud drives, servers and network shares.
struct SourcesView: View {
    @EnvironmentObject var model: AppModel

    @State private var isAdding = false
    @State private var editing: SourceConfig?
    @State private var deleteTarget: SourceConfig?
    @State private var syncingID: UUID?
    @State private var discovered: [DiscoveredService] = []
    @State private var isSearchingNetwork = false

    private let categoryOrder = ["This Device", "Cloud", "Servers", "Network"]

    private var grouped: [(String, [SourceConfig])] {
        var buckets: [String: [SourceConfig]] = [:]
        for source in model.sources {
            buckets[Self.category(source.kind), default: []].append(source)
        }
        return categoryOrder.compactMap { key in
            guard let list = buckets[key], !list.isEmpty else { return nil }
            return (key, list)
        }
    }

    static func category(_ kind: SourceKind) -> String {
        switch kind {
        case .local, .iCloud: return "This Device"
        case .dropbox, .googleDrive, .oneDrive, .box, .pCloud: return "Cloud"
        case .subsonic, .jellyfin, .emby, .plex: return "Servers"
        case .smb, .webdav, .ftp, .sftp, .upnp, .s3: return "Network"
        }
    }

    var body: some View {
        List {
            if model.settings.offlineMode {
                Section {
                    HStack(spacing: 10) {
                        Image("Offline")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Offline Mode is on")
                                .font(.subheadline.weight(.semibold))
                            Text("Network sources are paused. Turn it off in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if grouped.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No sources yet")
                            .font(.headline)
                        Text("Add a folder, a NAS, a cloud drive or a media server. The cat fetches the music.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }

            ForEach(grouped, id: \.0) { category, sources in
                Section(category) {
                    ForEach(sources) { config in
                        NavigationLink(value: config) {
                            SourceRow(config: config, isSyncing: syncingID == config.id)
                        }
                        .contextMenu { menu(for: config) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTarget = config
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section("Available Devices") {
                if isSearchingNetwork && discovered.isEmpty {
                    HStack(spacing: 10) {
                        PawProgressView(pawSize: 12)
                        Text("Sniffing around the network…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(discovered) { service in
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .lineLimit(1)
                                Text("\(service.kind.displayName) • \(service.host)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: service.kind.systemImage)
                                .foregroundStyle(MuurTheme.accentViolet)
                        }
                        Spacer()
                        if isAdded(service) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MuurTheme.success)
                        } else {
                            Button("Add") {
                                addDiscovered(service)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if !isSearchingNetwork && discovered.isEmpty {
                    Button {
                        model.environment.discovery.start()
                    } label: {
                        Label("Search Again", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
        .muurScreen()
        .navigationTitle("Sources")
        .navigationDestination(for: SourceConfig.self) { config in
            SourceBrowserView(config: config)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add source")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddSourceView()
        }
        .sheet(item: $editing) { config in
            AddSourceView(editing: config)
        }
        .alert("Remove “\(deleteTarget?.name ?? "")”?", isPresented: deletePresented) {
            Button("Remove", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its tracks leave the library; downloaded files are removed too.")
        }
        .onReceive(model.environment.discovery.$services) { discovered = $0 }
        .onReceive(model.environment.discovery.$isSearching) { isSearchingNetwork = $0 }
        .onAppear {
            model.environment.discovery.start()
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    @ViewBuilder
    private func menu(for config: SourceConfig) -> some View {
        Button {
            editing = config
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        if isServerKind(config.kind) {
            Button {
                syncLibrary(config)
            } label: {
                Label("Sync Library", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(syncingID != nil)
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = config
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    private func isServerKind(_ kind: SourceKind) -> Bool {
        switch kind {
        case .subsonic, .jellyfin, .emby, .plex, .upnp: return true
        default: return false
        }
    }

    private func isAdded(_ service: DiscoveredService) -> Bool {
        model.sources.contains { $0.host == service.host && $0.kind == service.kind }
    }

    private func addDiscovered(_ service: DiscoveredService) {
        Task {
            do {
                try await model.environment.sources.save(service.makeConfig())
                model.showToast(.success("Added \(service.name)", systemImage: "plus.circle.fill"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func syncLibrary(_ config: SourceConfig) {
        syncingID = config.id
        Task {
            do {
                let count = try await model.environment.sources.syncLibrary(sourceID: config.id)
                model.showToast(.success("Synced \(count) tracks from \(config.name)", systemImage: "arrow.triangle.2.circlepath"))
            } catch {
                model.showError(error)
            }
            syncingID = nil
        }
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            do {
                try await model.environment.sources.remove(target.id, deleteDownloads: true)
            } catch {
                model.showError(error)
            }
        }
    }
}

/// One configured source row.
struct SourceRow: View {
    let config: SourceConfig
    var isSyncing: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: config.kind.systemImage)
                .font(.title3)
                .foregroundStyle(MuurTheme.accentViolet)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSyncing {
                PawProgressView(pawSize: 10)
            }
        }
    }

    private var subtitle: String {
        var parts = [config.kind.displayName]
        if !config.host.isEmpty { parts.append(config.host) }
        if let account = config.option(SourceConfig.OptionKey.accountName), !account.isEmpty {
            parts.append(account)
        }
        return parts.joined(separator: " • ")
    }
}
