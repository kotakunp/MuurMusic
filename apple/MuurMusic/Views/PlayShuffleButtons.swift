import SwiftUI

/// The Play / Shuffle pair in album, artist and playlist headers. Shows full labels when they
/// fit and falls back to icon-only buttons in narrow columns (next to artwork on iPhone).
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(iconOnly: false)
            buttons(iconOnly: true)
        }
    }

    private func buttons(iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: play) {
                // Inside a List, icons take the accent tint, which matches the prominent fill.
                label("Play", systemImage: "play.fill", iconOnly: iconOnly)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            Button(action: shuffle) {
                label("Shuffle", systemImage: "shuffle", iconOnly: iconOnly)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func label(_ title: String, systemImage: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 32)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
