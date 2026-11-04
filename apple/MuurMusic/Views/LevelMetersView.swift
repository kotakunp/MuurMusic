import SwiftUI
import MuurCore
import MuurAudio

/// Stereo level meters fed by AudioLevelMonitor (dB scale).
struct LevelMetersView: View {
    @EnvironmentObject var player: PlaybackController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            HStack(spacing: 8) {
                meterBar(value: normalized(player.meters.levels.first ?? -60))
                meterBar(value: normalized(player.meters.levels.count > 1 ? player.meters.levels[1] : -60))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stereo level meters")
    }

    private func normalized(_ db: Float) -> Double {
        Double(min(max((db + 60) / 60, 0), 1))
    }

    private func meterBar(value: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MuurTheme.success, MuurTheme.accentAmber, MuurTheme.danger],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * value)
            }
        }
        .frame(height: 8)
    }
}
