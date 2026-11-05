import SwiftUI
import MuurCore
import MuurAudio
#if os(macOS)
import AppKit
#endif

/// App settings: appearance, playback, audio output, storage, library, about.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    @State private var isShowingVisualizer = false
    @State private var isPickingFolder = false
    @State private var showRebuildConfirm = false
    @State private var folderToRemove: WatchedFolder?

    private var settings: MuurSettings { model.settings }

    var body: some View {
        Form {
            appearanceSection
            playbackSection
            audioSection
            visualizerSection
            storageSection
            onlineSection
            librarySection
            Section {
                NavigationLink {
                    WiFiTransferView()
                } label: {
                    Label("Wi-Fi Transfer", systemImage: "wifi")
                }
            }
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About MuurMusic", systemImage: "info.circle")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                addFolder(url)
            }
        }
        .confirmationDialog("Rebuild the library database?",
                            isPresented: $showRebuildConfirm, titleVisibility: .visible) {
            Button("Full Rescan", role: .destructive) {
                model.environment.scanner.scanAll(full: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-reads every file from disk. Play counts and liked songs are kept.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isShowingVisualizer) {
            FullScreenVisualizerView()
        }
        #else
        .sheet(isPresented: $isShowingVisualizer) {
            FullScreenVisualizerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        #endif
    }

    // MARK: Binding helper

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<MuurSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: bind(\.theme)) {
                Text("System").tag(ThemePreference.system)
                Text("Dark").tag(ThemePreference.dark)
                Text("Light").tag(ThemePreference.light)
            }
            HStack {
                Text("Accent")
                Spacer()
                ForEach(AccentChoice.allCases, id: \.self) { choice in
                    Button {
                        settings.accent = choice
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 26, height: 26)
                            .overlay {
                                if settings.accent == choice {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.rawValue.capitalized)
                }
            }
            Picker("Now Playing Style", selection: bind(\.nowPlayingStyle)) {
                Text("Artwork").tag(NowPlayingStyle.artwork)
                Text("Vinyl").tag(NowPlayingStyle.vinyl)
                Text("Visualizer").tag(NowPlayingStyle.visualizer)
            }
            Toggle("Show Hi-Res Badges", isOn: bind(\.showHiResBadges))
            Toggle("Haptics (purr when you like a song)", isOn: bind(\.haptics))
            #if os(macOS)
            NavigationLink {
                TabOrderView()
            } label: {
                Label("Customize Tabs", systemImage: "rectangle.3.group")
            }
            #endif
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section("Playback") {
            VStack(alignment: .leading) {
                Slider(value: bind(\.crossfadeSeconds), in: 0...12, step: 0.5) { _ in
                    model.player.applyAudioSettings()
                }
                Text(settings.crossfadeSeconds == 0
                     ? "Crossfade off"
                     : "Crossfade \(String(format: "%.1f", settings.crossfadeSeconds)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if settings.crossfadeSeconds > 0 {
                Toggle("Crossfade between tracks of the same album", isOn: bind(\.crossfadeSkipsSameAlbum))
            }
            Toggle("Gapless Playback", isOn: bind(\.gapless))
            Toggle("Resume Queue on Launch", isOn: bind(\.resumeOnLaunch))
            Toggle("Fade Out on Sleep Timer", isOn: bind(\.sleepFadeOut))
            Picker("Skip Back", selection: bind(\.skipBackInterval)) {
                ForEach(Self.skipIntervals, id: \.self) { interval in
                    Text("\(Int(interval)) s").tag(interval)
                }
            }
            Picker("Skip Forward", selection: bind(\.skipForwardInterval)) {
                ForEach(Self.skipIntervals, id: \.self) { interval in
                    Text("\(Int(interval)) s").tag(interval)
                }
            }
        }
    }

    private static let skipIntervals: [Double] = [5, 10, 15, 30, 60]

    // MARK: Audio

    private var audioSection: some View {
        Section("Audio") {
            NavigationLink {
                EQView()
            } label: {
                Label("Equalizer", systemImage: "slider.vertical.3")
            }
            NavigationLink {
                EffectsView()
            } label: {
                Label("Audio Effects & DSP", systemImage: "waveform.badge.plus")
            }

            #if os(iOS)
            Toggle("Mix With Other Apps", isOn: bind(\.mixWithOthers))
            Toggle("Pause When Headphones Disconnect", isOn: bind(\.pauseOnRouteLoss))
            #else
            MacAudioOutputSection()
            Picker("DSD Playback", selection: bind(\.dsdMode)) {
                Text("Convert to PCM").tag(DSDPlaybackMode.pcm)
                Text("DoP (bit-perfect)").tag(DSDPlaybackMode.dop)
            }
            #endif
        }
    }

    // MARK: Visualizer

    private var visualizerSection: some View {
        Section("Visualizer") {
            Picker("Preset", selection: bind(\.visualizerPreset)) {
                ForEach(VisualizerPreset.allCases, id: \.self) { preset in
                    Text(Self.visualizerName(preset)).tag(preset)
                }
            }
            Toggle("Auto-Cycle Presets", isOn: bind(\.visualizerAutoCycle))
            if settings.visualizerAutoCycle {
                Stepper("Every \(Int(settings.visualizerCycleSeconds)) s",
                        value: bind(\.visualizerCycleSeconds), in: 5...120, step: 5)
            }
            Button {
                isShowingVisualizer = true
            } label: {
                Label("Open Full-Screen Visualizer", systemImage: "rectangle.expand.vertical")
            }
        }
    }

    static func visualizerName(_ preset: VisualizerPreset) -> String {
        switch preset {
        case .spectrumBars: return "Spectrum Bars"
        case .mirrorBars: return "Mirror Bars"
        case .circleSpectrum: return "Circle Spectrum"
        case .waveform: return "Waveform"
        case .particles: return "Particles"
        case .catEyes: return "Cat Eyes"
        case .starfield: return "Starfield"
        case .vinyl: return "Vinyl"
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage & Network") {
            Stepper("Stream Cache: \(settings.audioCacheLimitMB) MB",
                    value: bind(\.audioCacheLimitMB), in: 128...8192, step: 128)
            Toggle("Offline Mode", isOn: bind(\.offlineMode))
            Toggle("Prefetch Next Track", isOn: bind(\.prefetchNext))
            Toggle("Download over Cellular", isOn: bind(\.downloadOverCellular))
        }
    }

    // MARK: Online

    private var onlineSection: some View {
        Section("Online Metadata") {
            Toggle("Fetch Lyrics Online (LRCLIB)", isOn: bind(\.fetchLyricsOnline))
            Toggle("MusicBrainz Tag Lookup", isOn: bind(\.autoTagOnline))
        }
    }

    // MARK: Library

    private var librarySection: some View {
        Section {
            ForEach(model.watchedFolders) { folder in
                folderRow(folder)
            }
            Button {
                pickFolder()
            } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            Toggle("Watch Folders for Changes", isOn: bind(\.watchFolders))
            Button {
                model.environment.scanner.scanAll()
            } label: {
                Label("Rescan Library", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
            Button {
                showRebuildConfirm = true
            } label: {
                Label("Full Rebuild…", systemImage: "exclamationmark.arrow.circlepath")
            }
            .disabled(model.isScanning)
            if model.isScanning {
                HStack(spacing: 8) {
                    PawProgressView(pawSize: 12)
                    Text(model.scanProgress.folderName.isEmpty ? "Scanning…" : model.scanProgress.folderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Library")
        } footer: {
            #if os(iOS)
            if model.watchedFolders.contains(where: { !$0.isAppDocuments }) {
                Text("Swipe left on a folder to remove it. Its songs leave your library, but the files stay where they are.")
            }
            #endif
        }
    }

    #if os(iOS)
    private func folderRow(_ folder: WatchedFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isAppDocuments ? "iphone" : "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderTitle(folder))
                    .lineLimit(1)
                Text(folderLocation(folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Toggle(folderTitle(folder), isOn: folderBinding(folder))
                .labelsHidden()
        }
        // A destructive role would animate the row away before the removal is confirmed.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !folder.isAppDocuments {
                Button {
                    folderToRemove = folder
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(MuurTheme.danger)
            }
        }
        .contextMenu {
            Button {
                model.environment.scanner.scan(folderID: folder.id)
            } label: {
                Label("Rescan Folder", systemImage: "arrow.clockwise")
            }
            if !folder.isAppDocuments {
                Button(role: .destructive) {
                    folderToRemove = folder
                } label: {
                    Label("Remove Folder…", systemImage: "trash")
                }
            }
        }
        .removeFolderDialog(folder, pending: $folderToRemove, remove: removeFolder)
    }

    private var deviceFolderName: String { "On My \(UIDevice.current.model)" }

    private func folderTitle(_ folder: WatchedFolder) -> String {
        folder.isAppDocuments ? deviceFolderName : folder.name
    }

    /// Where the folder lives as the Files app names it, instead of the raw sandbox path.
    private func folderLocation(_ folder: WatchedFolder) -> String {
        if folder.isAppDocuments {
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MuurMusic"
            return "Files › \(deviceFolderName) › \(appName)"
        }
        let parts = folder.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + parts[(index + 1)...]).joined(separator: " › ")
        }
        if let index = parts.firstIndex(of: "File Provider Storage") {
            return ([deviceFolderName] + parts[(index + 1)...]).joined(separator: " › ")
        }
        // External drives mount under LiveFiles/<provider>/<volume>/…
        if let index = parts.firstIndex(of: "LiveFiles"), index + 2 < parts.count {
            return parts[(index + 2)...].joined(separator: " › ")
        }
        return parts.suffix(2).joined(separator: " › ")
    }
    #else
    private func folderRow(_ folder: WatchedFolder) -> some View {
        folderRowContent(folder)
            .removeFolderDialog(folder, pending: $folderToRemove, remove: removeFolder)
    }

    private func folderRowContent(_ folder: WatchedFolder) -> some View {
        HStack {
            Toggle(isOn: folderBinding(folder)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .lineLimit(1)
                    Text(folder.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Button(role: .destructive) {
                folderToRemove = folder
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(MuurTheme.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove folder")
        }
    }
    #endif

    private func folderBinding(_ folder: WatchedFolder) -> Binding<Bool> {
        Binding(
            get: { folder.enabled },
            set: { enabled in
                Task {
                    try? await model.environment.scanner.setFolderEnabled(folder, enabled: enabled)
                }
            }
        )
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            addFolder(url)
        }
        #else
        isPickingFolder = true
        #endif
    }

    private func addFolder(_ url: URL) {
        Task {
            do {
                _ = try await model.environment.scanner.addFolder(url: url)
                model.showToast(.success("Added \(url.lastPathComponent)", systemImage: "folder.badge.plus"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func removeFolder(_ folder: WatchedFolder) {
        Task {
            do {
                try await model.environment.scanner.removeFolder(folder)
                model.showToast(.success("Removed \(folder.name)", systemImage: "folder.badge.minus"))
            } catch {
                model.showError(error)
            }
        }
    }
}

private extension View {
    /// Asks before removing a watched folder. Attached to the folder's own row so the iOS 26
    /// popover points at that row instead of the top of the form.
    func removeFolderDialog(_ folder: WatchedFolder, pending: Binding<WatchedFolder?>,
                            remove: @escaping (WatchedFolder) -> Void) -> some View {
        confirmationDialog("Remove “\(folder.name)”?",
                           isPresented: Binding(get: { pending.wrappedValue?.id == folder.id },
                                                set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible) {
            Button("Remove Folder", role: .destructive) { remove(folder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its songs leave your library. The files stay where they are.")
        }
    }
}

#if os(macOS)
/// macOS audio output device picker with sample-rate controls.
struct MacAudioOutputSection: View {
    @EnvironmentObject var model: AppModel

    @State private var devices: [AudioOutputDevice] = []

    private var settings: MuurSettings { model.settings }

    private let fixedRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    var body: some View {
        Group {
            Picker("Output Device", selection: deviceBinding) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Picker("Sample Rate", selection: sampleRateModeBinding) {
                Text("System").tag(OutputSampleRateMode.system)
                Text("Match Source (bit-perfect)").tag(OutputSampleRateMode.matchSource)
                Text("Fixed").tag(OutputSampleRateMode.fixed)
            }
            if settings.outputSampleRateMode == .fixed {
                Picker("Fixed Rate", selection: fixedRateBinding) {
                    ForEach(fixedRates, id: \.self) { rate in
                        Text(MuurFormat.sampleRate(rate)).tag(rate)
                    }
                }
            }
        }
        .onAppear {
            devices = AudioOutputDevices.outputDevices()
        }
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { settings.outputDeviceUID ?? "" },
            set: { value in
                settings.outputDeviceUID = value.isEmpty ? nil : value
                model.player.applyAudioSettings()
            }
        )
    }

    private var sampleRateModeBinding: Binding<OutputSampleRateMode> {
        Binding(
            get: { settings.outputSampleRateMode },
            set: { value in
                settings.outputSampleRateMode = value
                model.player.applyAudioSettings()
            }
        )
    }

    private var fixedRateBinding: Binding<Double> {
        Binding(
            get: { settings.fixedOutputSampleRate },
            set: { value in
                settings.fixedOutputSampleRate = value
                model.player.applyAudioSettings()
            }
        )
    }
}
#endif
