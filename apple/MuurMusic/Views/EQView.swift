import SwiftUI
import UniformTypeIdentifiers
import MuurCore
import MuurAudio

/// 10-band graphic equalizer with presets, import/export and user presets.
struct EQView: View {
    @EnvironmentObject var model: AppModel

    @State private var userPresets: [EQPreset] = []
    @State private var isSavingPreset = false
    @State private var presetName = ""
    @State private var isImporting = false
    @State private var sharedFile: SharedFile?

    private var settings: MuurSettings { model.settings }

    private var allPresets: [EQPreset] {
        AudioPresetStore.builtInPresets + userPresets
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Toggle("Equalizer", isOn: eqEnabledBinding)
                        .toggleStyle(.switch)
                    Spacer()
                    presetPicker
                }

                preampRow

                bandSliders

                HStack(spacing: 12) {
                    Button("Flatten") { flatten() }
                    Button("Save as Preset…") {
                        presetName = settings.eqPresetName == "Flat" ? "" : settings.eqPresetName
                        isSavingPreset = true
                    }
                    Spacer()
                    Menu {
                        Button { isImporting = true } label: {
                            Label("Import Presets (.muureq.json)…", systemImage: "square.and.arrow.down")
                        }
                        Button { exportAll() } label: {
                            Label("Export All Presets…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .buttonStyle(.bordered)

                if !userPresets.isEmpty {
                    userPresetList
                }
            }
            .padding(20)
        }
        .muurScreen()
        .navigationTitle("Equalizer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Save EQ Preset", isPresented: $isSavingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: $sharedFile) { file in
            MuurShareSheet(file: file)
        }
        .task { await observeUserPresets() }
    }

    // MARK: Bindings

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.eqEnabled },
            set: { value in
                settings.eqEnabled = value
                model.player.applyAudioSettings()
            }
        )
    }

    // MARK: Presets

    private var presetPicker: some View {
        Menu {
            Button("Flat") { apply(EQPreset.flat) }
            if !AudioPresetStore.builtInPresets.isEmpty {
                Section("Built In") {
                    ForEach(AudioPresetStore.builtInPresets) { preset in
                        presetButton(preset)
                    }
                }
            }
            if !userPresets.isEmpty {
                Section("Your Presets") {
                    ForEach(userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(settings.eqPresetName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel("EQ preset")
    }

    private func presetButton(_ preset: EQPreset) -> some View {
        Button {
            apply(preset)
        } label: {
            if settings.eqPresetName == preset.name {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }

    private func apply(_ preset: EQPreset) {
        settings.eqPresetName = preset.name
        settings.eqPreampDb = preset.preampDb
        settings.eqBandGains = preset.gains
        settings.eqEnabled = true
        model.player.applyAudioSettings()
        MuurHaptics.tap(enabled: settings.haptics)
    }

    private func flatten() {
        apply(.flat)
    }

    // MARK: Sliders

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%+.1f dB", settings.eqPreampDb))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: preampBinding, in: EQPreset.gainRange, step: 0.5)
                .tint(MuurTheme.accentAmber)
        }
        .opacity(settings.eqEnabled ? 1 : 0.4)
        .disabled(!settings.eqEnabled)
    }

    private var preampBinding: Binding<Double> {
        Binding(
            get: { settings.eqPreampDb },
            set: { value in
                settings.eqPreampDb = value
                model.player.applyAudioSettings()
            }
        )
    }

    private var bandSliders: some View {
        let sliderHeight: CGFloat = 170
        return HStack(spacing: 0) {
            ForEach(Array(EQPreset.isoFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", gain(at: index)))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: gainBinding(at: index), in: EQPreset.gainRange, step: 0.5)
                        .rotationEffect(.degrees(-90))
                        .frame(width: sliderHeight)
                        .frame(width: 30, height: sliderHeight)
                        .tint(Color(hex: settings.accent.hex))
                    Text(Self.bandLabel(frequency))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(settings.eqEnabled ? 1 : 0.4)
        .disabled(!settings.eqEnabled)
        .accessibilityElement(children: .contain)
    }

    private func gain(at index: Int) -> Double {
        let gains = settings.eqBandGains
        return index < gains.count ? gains[index] : 0
    }

    private func gainBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { gain(at: index) },
            set: { value in
                var gains = settings.eqBandGains
                while gains.count < EQPreset.isoFrequencies.count { gains.append(0) }
                gains[index] = value
                settings.eqBandGains = gains
                settings.eqPresetName = "Custom"
                model.player.applyAudioSettings()
            }
        )
    }

    static func bandLabel(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))"
    }

    // MARK: User presets

    private var userPresetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Presets")
                .font(.headline)
            ForEach(userPresets) { preset in
                HStack {
                    Button {
                        apply(preset)
                    } label: {
                        Label(preset.name, systemImage: "slider.vertical.3")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        deletePreset(preset)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = EQPreset(name: name, preampDb: settings.eqPreampDb, gains: settings.eqBandGains)
        Task {
            do {
                try await model.environment.presets.save(preset: preset)
                settings.eqPresetName = name
                model.showToast(.success("Saved \(name)", systemImage: "slider.vertical.3"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func deletePreset(_ preset: EQPreset) {
        Task {
            do {
                try await model.environment.presets.deletePreset(named: preset.name)
            } catch {
                model.showError(error)
            }
        }
    }

    private func observeUserPresets() async {
        do {
            for try await value in model.environment.presets.observeUserPresets() {
                userPresets = value
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
                    let imported = try await model.environment.presets.importPresets(from: data)
                    model.showToast(.success("Imported \(imported.count) preset(s)", systemImage: "square.and.arrow.down"))
                } catch {
                    model.showError(error)
                }
            }
        }
    }

    private func exportAll() {
        Task {
            do {
                let presets = try await model.environment.presets.allPresets()
                let data = try model.environment.presets.exportPresets(presets)
                sharedFile = try SharedFile.write(data: data, fileName: "muur-eq-presets.muureq.json")
            } catch {
                model.showError(error)
            }
        }
    }
}
