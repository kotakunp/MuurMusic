import SwiftUI
import UniformTypeIdentifiers
import MuurCore
import MuurAudio

/// Loudness, ReplayGain, and the DSP effects chain entry point.
struct EffectsView: View {
    @EnvironmentObject var model: AppModel

    @State private var chains: [DSPChain] = []
    @State private var isImporting = false
    @State private var sharedFile: SharedFile?

    private var settings: MuurSettings { model.settings }

    private var activeChain: DSPChain? {
        guard !settings.dspChainJSON.isEmpty,
              let data = settings.dspChainJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DSPChain.self, from: data)
    }

    var body: some View {
        Form {
            Section("Loudness") {
                Toggle("Loudness Boost", isOn: binding(\.loudnessEnabled))
                if settings.loudnessEnabled {
                    VStack(alignment: .leading) {
                        Slider(value: binding(\.loudnessBoostDb), in: 0...12, step: 0.5)
                        Text("\(String(format: "%.1f", settings.loudnessBoostDb)) dB — lifts quiet tracks; a safety limiter keeps it clean.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("ReplayGain") {
                Picker("Mode", selection: replayGainBinding) {
                    Text("Off").tag(ReplayGainMode.off)
                    Text("Track").tag(ReplayGainMode.track)
                    Text("Album").tag(ReplayGainMode.album)
                }
                VStack(alignment: .leading) {
                    Slider(value: binding(\.replayGainPreampDb), in: -12...12, step: 0.5)
                    Text("Preamp \(String(format: "%+.1f", settings.replayGainPreampDb)) dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Prevent Clipping", isOn: binding(\.preventClipping))
            }

            Section("DSP Effects Chain") {
                Toggle("Effects Enabled", isOn: binding(\.dspEnabled))
                if let chain = activeChain {
                    let activeNodes = chain.nodes.filter(\.enabled)
                    LabeledContent("Active chain", value: chain.name)
                    LabeledContent("Nodes", value: "\(activeNodes.count) of \(chain.nodes.count) active")
                } else {
                    Text("No chain yet — build one with the cat-approved effects rack.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    DSPChainBuilderView(chain: activeChain ?? DSPChain(name: "My Chain"))
                } label: {
                    Label("Open Chain Builder", systemImage: "waveform.badge.plus")
                }
            }

            Section("Saved Chains") {
                if chains.isEmpty {
                    Text("Save a chain in the builder and it appears here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(chains) { chain in
                    HStack {
                        Button {
                            applyChain(chain)
                        } label: {
                            Label(chain.name, systemImage: "link")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button {
                                share(chain)
                            } label: {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                deleteChain(chain)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Chain (.muurdsp.json)…", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio Effects")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: $sharedFile) { file in
            MuurShareSheet(file: file)
        }
        .task { await observeChains() }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<MuurSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                model.player.applyAudioSettings()
            }
        )
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<MuurSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                model.player.applyAudioSettings()
            }
        )
    }

    private var replayGainBinding: Binding<ReplayGainMode> {
        Binding(
            get: { settings.replayGainMode },
            set: { value in
                settings.replayGainMode = value
                model.player.applyAudioSettings()
            }
        )
    }

    private func applyChain(_ chain: DSPChain) {
        settings.dspChainJSON = chain.jsonString()
        settings.dspEnabled = true
        model.player.applyAudioSettings()
        model.showToast(.success("Applied \(chain.name)", systemImage: "waveform.badge.plus"))
    }

    private func share(_ chain: DSPChain) {
        do {
            let data = try model.environment.presets.exportChain(chain)
            sharedFile = try SharedFile.write(data: data, fileName: PathUtils.sanitizeFileName(chain.name) + ".muurdsp.json")
        } catch {
            model.showError(error)
        }
    }

    private func deleteChain(_ chain: DSPChain) {
        Task {
            do {
                try await model.environment.presets.deleteChain(named: chain.name)
            } catch {
                model.showError(error)
            }
        }
    }

    private func observeChains() async {
        do {
            for try await value in model.environment.presets.observeDSPChains() {
                chains = value
            }
        } catch {}
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.showError(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let chain = try await model.environment.presets.importChain(from: data)
                    model.showToast(.success("Imported \(chain.name)", systemImage: "square.and.arrow.down"))
                } catch {
                    model.showError(error)
                }
            }
        }
    }
}
