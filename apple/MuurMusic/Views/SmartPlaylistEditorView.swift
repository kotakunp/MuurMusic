import SwiftUI
import MuurCore

/// Editor for smart playlist rules with a live match count.
struct SmartPlaylistEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let playlistID: Int64
    @State var definition: SmartPlaylistDefinition

    @State private var matchCount: Int?
    @State private var isSaving = false

    init(playlistID: Int64, definition: SmartPlaylistDefinition) {
        self.playlistID = playlistID
        _definition = State(initialValue: definition)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $definition.name)
                    Picker("Match", selection: $definition.match) {
                        Text("All rules").tag(SmartMatch.all)
                        Text("Any rule").tag(SmartMatch.any)
                    }
                }

                Section("Rules") {
                    ForEach(Array(definition.rules.enumerated()), id: \.offset) { index, rule in
                        SmartRuleRow(rule: binding(for: index))
                    }
                    .onDelete { offsets in
                        definition.rules.remove(atOffsets: offsets)
                    }
                    Button {
                        definition.rules.append(SmartRule(field: .artist, op: .contains, value: .string("")))
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                }

                Section("Sort & Limit") {
                    Picker("Sort by", selection: $definition.sort) {
                        ForEach(Self.sortOptions, id: \.self) { option in
                            Text(option.replacingOccurrences(of: "-", with: "").capitalized + (option.hasPrefix("-") ? " (descending)" : ""))
                                .tag(option)
                        }
                    }
                    Stepper("Limit: \(definition.limit == 0 ? "none" : "\(definition.limit) tracks")",
                            value: $definition.limit, in: 0...500, step: 10)
                }

                Section {
                    HStack {
                        Text("Matches now")
                        Spacer()
                        if let matchCount {
                            Text("\(matchCount) tracks")
                                .foregroundStyle(.secondary)
                        } else {
                            PawProgressView(pawSize: 10)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Smart Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || definition.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .task(id: definition) { await refreshCount() }
    }

    private static let sortOptions: [String] = [
        "title", "artist", "album", "albumArtist", "dateAdded", "-dateAdded",
        "lastPlayed", "-lastPlayed", "playCount", "-playCount", "rating", "-rating",
        "year", "-year", "duration", "-duration", "random",
    ]

    private func binding(for index: Int) -> Binding<SmartRule> {
        Binding(
            get: { definition.rules[index] },
            set: { definition.rules[index] = $0 }
        )
    }

    private func refreshCount() async {
        let current = definition
        do {
            let count = try await model.environment.database.read { db in
                try SmartPlaylistCompiler.compile(current).fetch(db).count
            }
            guard !Task.isCancelled else { return }
            matchCount = count
        } catch {
            matchCount = nil
        }
    }

    private func save() {
        isSaving = true
        var updated = definition
        updated.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.environment.playlists.updateSmart(id: playlistID, definition: updated)
                dismiss()
            } catch {
                model.showError(error)
                isSaving = false
            }
        }
    }
}

/// One editable smart rule row.
struct SmartRuleRow: View {
    @Binding var rule: SmartRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Field", selection: $rule.field) {
                    ForEach(SmartRuleField.allCases, id: \.self) { field in
                        Text(Self.fieldName(field)).tag(field)
                    }
                }
                .labelsHidden()
                .onChange(of: rule.field) { _, _ in normalizeRule() }

                Picker("Operator", selection: $rule.op) {
                    ForEach(operators, id: \.self) { op in
                        Text(Self.operatorName(op)).tag(op)
                    }
                }
                .labelsHidden()
            }

            valueEditor
        }
    }

    private var operators: [SmartRuleOperator] {
        if rule.field.isDate {
            return [.inLast, .is, .isNot]
        }
        if rule.field.isNumeric || rule.field == .favorite {
            return [.is, .isNot, .gt, .lt, .between]
        }
        return [.is, .isNot, .contains, .startsWith]
    }

    @ViewBuilder
    private var valueEditor: some View {
        if rule.field == .favorite {
            Picker("Value", selection: favoriteBinding) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else if rule.field.isDate && rule.op == .inLast {
            Stepper("Last \(Int(rule.value.doubleValue ?? 30)) days", value: dayBinding, in: 1...365)
        } else if rule.field.isNumeric {
            HStack {
                TextField("Value", value: numberBinding, format: .number)
                #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                #endif
                if rule.op == .between {
                    Text("and")
                    TextField("Value 2", value: number2Binding, format: .number)
                    #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                    #endif
                }
            }
        } else {
            TextField("Value", text: stringBinding)
        }
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: {
                if case .bool(let flag) = rule.value { return flag }
                return true
            },
            set: { rule.value = .bool($0) }
        )
    }

    private var dayBinding: Binding<Double> {
        Binding(
            get: { rule.value.doubleValue ?? 30 },
            set: { rule.value = .number($0) }
        )
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { rule.value.doubleValue ?? 0 },
            set: { rule.value = .number($0) }
        )
    }

    private var number2Binding: Binding<Double> {
        Binding(
            get: { rule.value2?.doubleValue ?? 0 },
            set: { rule.value2 = .number($0) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { rule.value.stringValue ?? "" },
            set: { rule.value = .string($0) }
        )
    }

    /// Makes sure operator and value type still fit the chosen field.
    private func normalizeRule() {
        if !operators.contains(rule.op) {
            rule.op = operators.first ?? .is
        }
        if rule.field == .favorite {
            rule.value = .bool(true)
        } else if rule.field.isNumeric || rule.field.isDate {
            if rule.value.doubleValue == nil { rule.value = .number(0) }
        } else if rule.value.stringValue == nil {
            rule.value = .string("")
        }
    }

    static func fieldName(_ field: SmartRuleField) -> String {
        switch field {
        case .genre: return "Genre"
        case .artist: return "Artist"
        case .albumArtist: return "Album Artist"
        case .album: return "Album"
        case .composer: return "Composer"
        case .year: return "Year"
        case .rating: return "Rating"
        case .playCount: return "Play Count"
        case .dateAdded: return "Date Added"
        case .format: return "Format"
        case .bitDepth: return "Bit Depth"
        case .sampleRate: return "Sample Rate"
        case .duration: return "Length"
        case .title: return "Title"
        case .favorite: return "Favorite"
        case .lastPlayed: return "Last Played"
        case .bpm: return "BPM"
        case .bitrate: return "Bitrate"
        }
    }

    static func operatorName(_ op: SmartRuleOperator) -> String {
        switch op {
        case .is: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .gt: return ">"
        case .lt: return "<"
        case .between: return "between"
        case .inLast: return "in the last"
        }
    }
}
