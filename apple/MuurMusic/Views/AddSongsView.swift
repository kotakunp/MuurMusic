import SwiftUI
import UniformTypeIdentifiers
import MuurCore

#if os(iOS)
/// Every way to get music into the app: importing, linking a folder, Wi-Fi, USB, the share sheet and servers.
struct AddSongsView: View {
    @EnvironmentObject var model: AppModel

    @State private var pickerMode: FilePickerMode = .files
    @State private var isPicking = false
    @State private var isWorking = false
    @State private var newSource: NewSource?
    @State private var discovered: [DiscoveredService] = []
    @State private var isWiFiRunning = false

    private enum FilePickerMode {
        case files, folder
    }

    private struct NewSource: Identifiable {
        let kind: SourceKind
        var id: String { kind.rawValue }
    }

    private static let mediaServers: [SourceKind] = [.plex, .jellyfin, .emby, .subsonic]
    private static let cloudDrives: [SourceKind] = [.dropbox, .googleDrive, .oneDrive, .box, .pCloud]
    private static let networkStorage: [SourceKind] = [.smb, .webdav, .sftp, .ftp, .upnp, .s3]

    private var newServices: [DiscoveredService] {
        discovered.filter { service in
            !model.sources.contains { $0.host == service.host && $0.kind == service.kind }
        }
    }

    var body: some View {
        List {
            Section("On This iPhone") {
                Button {
                    pick(.files)
                } label: {
                    AddMethodRow(title: "Import from Files",
                                 detail: "Copy songs, ZIP files or playlists from iCloud Drive, On My iPhone or a USB drive.",
                                 systemImage: "square.and.arrow.down")
                }
                Button {
                    pick(.folder)
                } label: {
                    AddMethodRow(title: "Link a Folder",
                                 detail: "Play a folder where it is, without copying. Songs you add to it later show up too.",
                                 systemImage: "folder.badge.plus")
                }
            }

            Section("From a Computer") {
                NavigationLink {
                    WiFiTransferView()
                } label: {
                    AddMethodRow(title: "Wi-Fi Transfer",
                                 detail: isWiFiRunning
                                    ? "Running. Open the address it shows in a browser on your computer."
                                    : "Upload from a browser on any computer on the same Wi-Fi.",
                                 systemImage: "wifi")
                }
                NavigationLink {
                    AddSongsGuideView(guide: .cable)
                } label: {
                    AddMethodRow(title: "USB Cable",
                                 detail: "Drag songs onto MuurMusic in Finder on a Mac, or in Apple Devices on Windows.",
                                 systemImage: "cable.connector")
                }
            }

            Section("From Another App") {
                NavigationLink {
                    AddSongsGuideView(guide: .share)
                } label: {
                    AddMethodRow(title: "Share or Open In",
                                 detail: "In Files, Safari, Mail or a chat app, tap Share and choose MuurMusic.",
                                 systemImage: "square.and.arrow.up")
                }
            }

            if !newServices.isEmpty {
                Section("Found on Your Wi-Fi") {
                    ForEach(newServices) { service in
                        HStack {
                            AddMethodRow(title: service.name,
                                         detail: "\(service.kind.displayName) · \(service.host)",
                                         systemImage: service.kind.systemImage)
                            Spacer(minLength: 8)
                            Button("Add") { addDiscovered(service) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    }
                }
            }

            sourceSection("Media Servers", kinds: Self.mediaServers,
                          footer: "Stream the server's whole library, or download songs to play offline.")
            sourceSection("Cloud Drives", kinds: Self.cloudDrives,
                          footer: "Sign in, then browse the drive and add or download songs.")
            sourceSection("Network Storage", kinds: Self.networkStorage,
                          footer: "A NAS, a shared folder on a computer, a media box on your network, or S3 storage.")

            if !model.sources.isEmpty {
                Section {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        AddMethodRow(title: "Connected Sources",
                                     detail: model.sources.count == 1 ? "1 source" : "\(model.sources.count) sources",
                                     systemImage: "externaldrive.fill.badge.wifi")
                    }
                }
            }
        }
        .navigationTitle("Add Songs")
        .muurTopLevelTitle()
        .toolbar {
            if isWorking {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
        .fileImporter(isPresented: $isPicking,
                      allowedContentTypes: pickerMode == .folder ? [.folder] : [.item],
                      allowsMultipleSelection: pickerMode == .files) { result in
            handlePick(result)
        }
        .sheet(item: $newSource) { source in
            AddSourceView(kind: source.kind)
        }
        .onReceive(model.environment.discovery.$services) { discovered = $0 }
        .onReceive(model.environment.wifiTransfer.$isRunning) { isWiFiRunning = $0 }
        .onAppear { model.environment.discovery.start() }
    }

    private func sourceSection(_ title: String, kinds: [SourceKind], footer: String) -> some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                Button {
                    newSource = NewSource(kind: kind)
                } label: {
                    AddMethodRow(title: kind.displayName, systemImage: kind.systemImage)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func pick(_ mode: FilePickerMode) {
        pickerMode = mode
        isPicking = true
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.showError(error)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            switch pickerMode {
            case .files: importFiles(urls)
            case .folder: linkFolder(urls[0])
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        let usable = urls.filter { url in
            let name = url.lastPathComponent
            return PathUtils.isAudio(name) || PathUtils.isPlaylist(name) || PathUtils.isArchive(name)
        }
        let skipped = urls.count - usable.count
        guard !usable.isEmpty else {
            model.showError("Those files aren't songs, playlists or ZIP files.")
            return
        }
        isWorking = true
        Task {
            do {
                let copied = try await model.environment.scanner.importFiles(usable)
                var message = copied.count == 1 ? "Imported \(copied[0].lastPathComponent)" : "Imported \(copied.count) files"
                if skipped > 0 { message += ", skipped \(skipped) that aren't music" }
                model.showToast(.success(message, systemImage: "square.and.arrow.down.fill"))
            } catch {
                model.showError(error)
            }
            isWorking = false
        }
    }

    private func linkFolder(_ url: URL) {
        Task {
            do {
                _ = try await model.environment.scanner.addFolder(url: url)
                model.showToast(.success("Linked \(url.lastPathComponent)", systemImage: "folder.badge.plus"))
            } catch {
                model.showError(error)
            }
        }
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
}

/// An icon tile, a title and an optional one-line explanation.
private struct AddMethodRow: View {
    let title: String
    var detail: String? = nil
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Concrete colors: .primary/.secondary resolve against the tint inside a List button.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.primary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Step-by-step instructions for adding songs from outside the app.
struct AddSongsGuideView: View {
    enum Guide {
        case cable, share
    }

    let guide: Guide

    private var title: String {
        switch guide {
        case .cable: return "USB Cable"
        case .share: return "Share or Open In"
        }
    }

    private var steps: [String] {
        switch guide {
        case .cable:
            return [
                "Connect your iPhone to the computer with a cable and unlock it.",
                "On a Mac, open Finder and select your iPhone in the sidebar. On Windows, open the Apple Devices app and select your iPhone.",
                "Click Files, then drag songs or folders onto MuurMusic.",
                "Open MuurMusic. The new songs show up in your library a few seconds later.",
            ]
        case .share:
            return [
                "Find the song in Files, Safari downloads, Mail, or a chat app such as Telegram or WhatsApp.",
                "Tap Share, then choose MuurMusic. If it isn't in the row of apps, scroll to the end and tap More.",
                "MuurMusic opens and copies the song into your library.",
            ]
        }
    }

    private var footer: String {
        switch guide {
        case .cable:
            return "Songs are copied into MuurMusic's own folder. You can also find it in the Files app under On My iPhone."
        case .share:
            return "ZIP files are unpacked, and M3U or PLS files become playlists."
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
