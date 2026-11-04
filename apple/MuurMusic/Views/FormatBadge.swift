import SwiftUI
import MuurCore

/// Small capsule marking hi-res tracks (FLAC 24/96, DSD, …).
struct FormatBadge: View {
    @EnvironmentObject var model: AppModel
    let track: Track

    var body: some View {
        if model.settings.showHiResBadges, track.isHiRes, !track.formatBadge.isEmpty {
            Text(track.formatBadge)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize()
                .accessibilityLabel("High resolution \(track.formatBadge)")
        }
    }
}
