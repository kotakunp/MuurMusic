import SwiftUI
import MuurCore

/// Reorderable editor for the iOS tab bar order (first four + More).
struct TabOrderView: View {
    @EnvironmentObject var model: AppModel

    private var settings: MuurSettings { model.settings }

    private var available: [LibraryTab] {
        LibraryTab.allCases.filter { !settings.tabOrder.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(settings.tabOrder, id: \.self) { tab in
                    row(for: tab)
                }
                .onMove { source, destination in
                    settings.tabOrder.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    guard settings.tabOrder.count > 1 else { return }
                    settings.tabOrder.remove(atOffsets: offsets)
                }
            } header: {
                Text("Tab order")
            } footer: {
                Text("On iOS the first three (Search aside) get their own tabs next to Library. Every section stays in Library.")
            }

            if !available.isEmpty {
                Section("Available") {
                    ForEach(available, id: \.self) { tab in
                        Button {
                            settings.tabOrder.append(tab)
                        } label: {
                            HStack {
                                row(for: tab)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(MuurTheme.success)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Tabs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        #endif
    }

    private func row(for tab: LibraryTab) -> some View {
        let section = AppSection(tab)
        return Label(section?.title ?? tab.rawValue, systemImage: section?.systemImage ?? "questionmark")
    }
}
