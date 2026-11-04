import Combine

/// Publishes the playback position on its own so only progress views re-render on each tick.
/// Observing `PlaybackController` for the position used to rebuild every track row and any
/// open menu several times a second.
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public internal(set) var position: Double = 0
}
