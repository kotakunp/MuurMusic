import SwiftUI

/// The Play / Shuffle pair under album, artist and playlist headers.
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        .buttonStyle(MuurPillButtonStyle())
    }
}
