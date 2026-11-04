import SwiftUI
import MuurCore
import MuurAudio

/// Visual editor for the muur-dsp effects chain.
struct DSPChainBuilderView: View {
    @EnvironmentObject var model: AppModel

    @State var chain: DSPChain
    @State private var isAddingNode = false
    @State private var isSavingAs = false
    @State private var saveName = ""
    @State private var sharedFile: SharedFile?

    private var settings: MuurSettings { model.settings }

    var body: some View {
        List {
            Section {
                TextField("Chain name", text: $chain.name)
                    .onChange(of: chain.name) { _, _ in persist() }
            }

            Section("Nodes (top to bottom)") {
                if chain.nodes.isEmpty {
                    Text("No effects yet — add one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach($chain.nodes) { $node in
                    DSPNodeRow(node: $node)
                        .onChange(of: node) { _, _ in persist() }
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
                Button {
                    isAddingNode = true
                } label: {
                    Label("Add Effect", systemImage: "plus.circle.fill")
                }
            }

            Section {
                Button {
                    saveName = chain.name
                    isSavingAs = true
                } label: {
                    Label("Save to My Chains", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    shareChain()
                } label: {
                    Label("Share Chain…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .muurScreen()
        .navigationTitle("Chain Builder")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        #endif
        .sheet(isPresented: $isAddingNode) {
            NodePickerSheet { type in
                chain.nodes.append(DSPNode(type: type))
                persist()
            }
        }
        .alert("Save Chain", isPresented: $isSavingAs) {
            TextField("Chain name", text: $saveName)
            Button("Save") { saveAs() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $sharedFile) { file in
            MuurShareSheet(file: file)
        }
    }

    private func persist() {
        settings.dspChainJSON = chain.jsonString()
        model.player.applyAudioSettings()
    }

    private func move(from source: IndexSet, to destination: Int) {
        chain.nodes.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func delete(at offsets: IndexSet) {
        chain.nodes.remove(atOffsets: offsets)
        persist()
    }

    private func saveAs() {
        var copy = chain
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        copy.name = name
        Task {
            do {
                try await model.environment.presets.save(chain: copy)
                model.showToast(.success("Saved \(name)", systemImage: "waveform.badge.plus"))
            } catch {
                model.showError(error)
            }
        }
    }

    private func shareChain() {
        do {
            let data = try chain.encoded()
            sharedFile = try SharedFile.write(data: data, fileName: PathUtils.sanitizeFileName(chain.name) + ".muurdsp.json")
        } catch {
            model.showError(error)
        }
    }
}

/// One effect node with bypass toggle and parameter sliders.
struct DSPNodeRow: View {
    @Binding var node: DSPNode

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $node.enabled) {
                    Label(node.nodeType?.displayName ?? node.type, systemImage: icon(for: node.nodeType))
                }
                .toggleStyle(.switch)
                Spacer()
                if !(node.nodeType?.parameters.isEmpty ?? true) {
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Parameters")
                }
            }
            if isExpanded, let specs = node.nodeType?.parameters, !specs.isEmpty {
                ForEach(specs, id: \.key) { spec in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(spec.key.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                            Spacer()
                            Text(formatted(spec))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: valueBinding(for: spec), in: spec.range)
                            .controlSize(.small)
                    }
                    .disabled(!node.enabled)
                    .opacity(node.enabled ? 1 : 0.4)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for type: DSPNodeType?) -> String {
        guard let type else { return "questionmark.circle" }
        switch type {
        case .lowPass, .highPass, .bandPass, .notch, .peaking, .lowShelf, .highShelf:
            return "waveform.path.ecg"
        case .gain:
            return "speaker.wave.2"
        case .softClip, .bitCrusher, .distortion:
            return "bolt.trianglebadge.exclamationmark"
        case .tremolo, .ringModulator, .autoWah:
            return "waveform"
        case .delay:
            return "clock.arrow.circlepath"
        case .stereoWidth, .crossfeed:
            return "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .reverb:
            return "building.columns"
        case .chorus, .flanger, .phaser:
            return "waveform.path"
        case .compressor:
            return "rectangle.compress.vertical"
        }
    }

    private func formatted(_ spec: DSPParameterSpec) -> String {
        let value = node.value(spec.key, default: spec.defaultValue)
        let text = value == floor(value) ? String(format: "%.0f", value) : String(format: "%.2f", value)
        return spec.unit.isEmpty ? text : "\(text) \(spec.unit)"
    }

    private func valueBinding(for spec: DSPParameterSpec) -> Binding<Double> {
        Binding(
            get: { node.value(spec.key, default: spec.defaultValue) },
            set: { node.params[spec.key] = .number($0) }
        )
    }
}

/// Sheet listing every available DSP effect.
struct NodePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (DSPNodeType) -> Void

    var body: some View {
        NavigationStack {
            List(DSPNodeType.allCases, id: \.self) { type in
                Button {
                    onPick(type)
                    dismiss()
                } label: {
                    Label(type.displayName, systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add Effect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 480)
        #endif
    }
}
