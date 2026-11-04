import SwiftUI
import MuurCore

/// Small capsule showing the audio format (FLAC, MP3, …); highlighted amber for hi-res.
struct FormatBadge: View {
    @EnvironmentObject var model: AppModel
    let track: Track

    var body: some View {
        if model.settings.showHiResBadges, !track.formatBadge.isEmpty {
            Text(track.formatBadge)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(track.isHiRes ? MuurTheme.accentAmber : Color.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(track.isHiRes ? MuurTheme.accentAmber.opacity(0.7) : Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .accessibilityLabel(track.isHiRes ? "High resolution \(track.formatBadge)" : track.formatBadge)
        }
    }
}
