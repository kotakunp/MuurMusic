import SwiftUI

/// Small toolbar content shown while the library scanner is working.
struct ScanStatusLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isScanning {
            HStack(spacing: 6) {
                PawProgressView(pawSize: 10)
                Text(model.scanProgress.folderName.isEmpty ? "Scanning" : model.scanProgress.folderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning library")
        }
    }
}
