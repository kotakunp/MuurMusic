import AVFAudio
import Combine
import Foundation
import MuurCore
import MuurWidgetKitSupport

public enum PlaybackState: String, Sendable { case stopped, playing, paused }

/// Where audio goes: the device's output or a DLNA renderer.
public enum PlaybackOutput: Equatable, Sendable {
    case local
    case dlna(id: String, name: String)
}

public enum SleepTimerMode: Equatable, Sendable {
    case off
    case endOfTrack
    case minutes(Int)
}

/// The audio facade of MuurMusic (FEATURES "Playback"). Main-actor observable; owns two
/// `PlaybackEngine`s (alternated for crossfades), the queue, sleep timer, ReplayGain, gapless
/// enqueueing, Now Playing / remote commands, DLNA output and widget snapshots.
///
/// ```swift
/// let player = PlaybackController(environment: try MuurEnvironment.bootstrap())
/// player.play(albumTracks, startIndex: 0)
/// ```
@MainActor
public final class PlaybackController: ObservableObject {
    public let environment: MuurEnvironment
    private var sources: SourceManager { environment.sources }
    private var settings: MuurSettings { environment.settings }

    /// Level meter / spectrum for the visualizer.
    public let meters = AudioLevelMonitor()
    private let nowPlayingManager = NowPlayingManager()
    private let widgetWriter: WidgetSnapshotWriter
    #if !os(macOS)
    public let audioSession = AudioSessionManager()
    #endif

    @Published public private(set) var state: PlaybackState = .stopped
    @Published public private(set) var queue = PlaybackQueue()
    /// Seconds into the current track (CUE window relative).
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isCrossfading = false
    @Published public private(set) var output: PlaybackOutput = .local
    @Published public private(set) var sleepTimer: SleepTimerMode = .off
    @Published public private(set) var sleepTimerEndsAt: Date?
    @Published public private(set) var lastError: String?
    /// The volume used for local output (macOS device volume; mirrored to DLNA renderers).
    @Published public var volume: Float = 1 {
        didSet { applyVolume() }
    }

    public var currentTrack: Track? { queue.currentTrack }
    public var shuffleMode: ShuffleMode { queue.shuffleMode }
    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isPlaying: Bool { state == .playing }

    private var engines: [PlaybackEngine] = []
    private var activeIndex = 0
    private var active: PlaybackEngine? { engines.isEmpty ? nil : engines[activeIndex] }
    private var inactive: PlaybackEngine? { engines.isEmpty ? nil : engines[1 - activeIndex] }
    private var positionTimer: Timer?
    private var nowPlayingTick = 0
    private var sleepTask: Task<Void, Never>?
    private var crossfadeTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var dlnaRenderer: DLNARenderer?
    private let audioServer = LocalAudioServer()
    private var dlnaPollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var trackStartedAt: Double = 0
    private var historyRecorded = false
    private var enqueuedGaplessKey: String?
    private var restoredQueue = false

    public init(environment: MuurEnvironment) {
        self.environment = environment
        self.widgetWriter = WidgetSnapshotWriter(store: environment.paths.widgetStore, artwork: environment.artwork)
        do {
            engines = [try makeEngine(index: 0), try makeEngine(index: 1)]
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("Audio engine setup failed: \(error.localizedDescription, privacy: .public)")
        }
        configureRemoteCommands()
        observeSettings()
        #if !os(macOS)
        audioSession.onShouldPause = { [weak self] in self?.pause() }
        audioSession.onShouldResume = { [weak self] in self?.resume() }
        #endif
        restoreQueueIfNeeded()
    }

    private func makeEngine(index: Int) throws -> PlaybackEngine {
        try PlaybackEngine(tapBuffer: meters.tapBuffer) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEngineEvent(event, from: index)
            }
        }
    }

    // MARK: - Settings observation

    private func observeSettings() {
        let apply = { [weak self] in self?.applyAudioSettings() }
        settings.$playbackSpeed.dropFirst().sink { [weak self] speed in
            self?.engines.forEach { $0.setSpeed(speed) }
        }.store(in: &cancellables)
        settings.$eqEnabled.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$eqBandGains.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$eqPreampDb.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$dspEnabled.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$dspChainJSON.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$loudnessEnabled.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$loudnessBoostDb.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$replayGainMode.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$replayGainPreampDb.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        settings.$preventClipping.dropFirst().sink { _ in apply() }.store(in: &cancellables)
        #if os(macOS)
        settings.$outputDeviceUID.dropFirst().sink { [weak self] _ in self?.applyOutputDevice() }.store(in: &cancellables)
        #endif
        engines.forEach { $0.setSpeed(settings.playbackSpeed) }
    }

    /// Pushes EQ / speed / DSP / ReplayGain settings into both engines.
    public func applyAudioSettings() {
        let preGain = currentTrack.map(replayGainDb(for:)) ?? 0
        for engine in engines {
            engine.setSpeed(settings.playbackSpeed)
            engine.applyEQ(gains: settings.eqBandGains, preampDb: settings.eqPreampDb, enabled: settings.eqEnabled)
            engine.applyDSP(chainJSON: settings.dspChainJSON, dspEnabled: settings.dspEnabled, preGainDb: preGain,
                            loudnessEnabled: settings.loudnessEnabled, loudnessBoostDb: settings.loudnessBoostDb)
        }
    }

    /// ReplayGain (track or album) plus preamp, clamped to avoid clipping when enabled.
    private func replayGainDb(for track: Track) -> Double {
        var gain: Double
        switch settings.replayGainMode {
        case .off: gain = 0
        case .track: gain = track.replayGainTrackGain ?? 0
        case .album: gain = track.replayGainAlbumGain ?? track.replayGainTrackGain ?? 0
        }
        var total = gain + settings.replayGainPreampDb
        if settings.preventClipping, settings.replayGainMode != .off {
            let peak = max(track.replayGainTrackPeak ?? 1, 1e-6)
            total = min(total, -20 * log10(peak))
        }
        return total
    }

    #if os(macOS)
    private func applyOutputDevice() {
        guard let uid = settings.outputDeviceUID, let device = AudioOutputDevices.device(forUID: uid) else { return }
        for engine in engines {
            try? engine.player.setOutputDeviceID(device.id)
        }
    }

    /// Matches the output device's nominal sample rate to the track when configured.
    private func applySampleRate(for track: Track) {
        let device = settings.outputDeviceUID.flatMap(AudioOutputDevices.device(forUID:))
            ?? AudioOutputDevices.defaultOutputDeviceID().flatMap { id in AudioOutputDevices.outputDevices().first { $0.id == id } }
        guard let device else { return }
        let target: Double?
        switch settings.outputSampleRateMode {
        case .system: target = nil
        case .matchSource: target = track.sampleRate > 0 ? track.sampleRate : nil
        case .fixed: target = settings.fixedOutputSampleRate
        }
        guard let target, AudioOutputDevices.availableSampleRates(of: device.id).contains(target),
              device.sampleRate != target else { return }
        try? AudioOutputDevices.setNominalSampleRate(target, of: device.id)
    }
    #endif

    private func applyVolume() {
        #if os(macOS)
        for engine in engines { try? engine.player.setVolume(volume) }
        #endif
        if let dlnaRenderer { Task { try? await dlnaRenderer.setVolume(Int(volume * 100)) } }
    }

    // MARK: - Queue API

    /// Plays a list of tracks starting at `startIndex`.
    public func play(_ tracks: [Track], startIndex: Int = 0, shuffle: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        let mode = shuffle.map { $0 ? ShuffleMode.on : ShuffleMode.off } ?? queue.shuffleMode
        let items = tracks.map(QueueItem.init(track:))
        queue = PlaybackQueue(items: items, startIndex: min(max(0, startIndex), items.count - 1), shuffleMode: mode,
                              repeatMode: queue.repeatMode)
        finishTrackForHistory(skipped: false)
        startCurrent(at: 0)
    }

    /// Plays a single track immediately.
    public func play(_ track: Track) {
        play([track], startIndex: 0)
    }

    /// Jumps to a queue entry.
    public func playItem(id: UUID) {
        guard queue.jump(to: id) else { return }
        finishTrackForHistory(skipped: false)
        startCurrent(at: 0)
    }

    public func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue.insertNext(tracks.map(QueueItem.init(track:)))
        scheduleQueueSave()
        prefetchUpcoming()
    }

    public func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.append(tracks.map(QueueItem.init(track:)))
        scheduleQueueSave()
        if wasEmpty && state == .stopped { startCurrent(at: 0) }
    }

    public func removeFromQueue(ids: Set<UUID>) {
        let removedCurrent = ids.contains(where: { $0 == queue.currentItem?.id })
        queue.remove(ids: ids)
        scheduleQueueSave()
        if removedCurrent {
            if queue.currentTrack != nil {
                startCurrent(at: 0)
            } else {
                stop()
            }
        }
    }

    public func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.moveInPlayOrder(from: source, to: destination)
        scheduleQueueSave()
    }

    public func clearQueue() {
        stop()
        queue = PlaybackQueue(repeatMode: queue.repeatMode)
        scheduleQueueSave()
    }

    public func setShuffle(_ mode: ShuffleMode) {
        queue.setShuffle(mode)
        scheduleQueueSave()
        prefetchUpcoming()
    }

    public func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
        scheduleQueueSave()
    }

    // MARK: - Transport

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped:
            if queue.currentTrack != nil { startCurrent(at: position) }
        }
    }

    public func pause() {
        guard state == .playing else { return }
        if case .dlna = output {
            Task { try? await dlnaRenderer?.pause() }
        } else {
            active?.pause()
        }
        state = .paused
        updateNowPlaying()
        publishWidgetSnapshot()
    }

    public func resume() {
        guard state == .paused else { return }
        if case .dlna = output {
            Task { try? await dlnaRenderer?.play() }
        } else {
            #if !os(macOS)
            try? audioSession.activate(mixWithOthers: settings.mixWithOthers)
            #endif
            active?.resume()
        }
        state = .playing
        updateNowPlaying()
        publishWidgetSnapshot()
    }

    public func stop() {
        crossfadeTask?.cancel()
        isCrossfading = false
        finishTrackForHistory(skipped: false)
        if case .dlna = output {
            Task { try? await dlnaRenderer?.stop() }
        }
        engines.forEach { $0.stop() }
        state = .stopped
        position = 0
        nowPlayingManager.clear()
        stopPositionTimer()
        publishWidgetSnapshot()
        scheduleQueueSave()
    }

    /// Next track. When within the first seconds, counts as a skip for statistics.
    public func next() {
        guard queue.currentTrack != nil else { return }
        finishTrackForHistory(skipped: position - trackStartedAt < 30 && duration > 0 && (position - trackStartedAt) / duration < 0.5)
        guard queue.advance() else { stop(); return }
        startCurrent(at: 0)
    }

    /// Previous track; restarts the current track when past the first three seconds.
    public func previous() {
        if position > 3, !(queue.repeatMode == .one) {
            seek(to: 0)
            return
        }
        finishTrackForHistory(skipped: false)
        guard queue.back() else { seek(to: 0); return }
        startCurrent(at: 0)
    }

    public func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(duration - 0.2, 0))
        position = clamped
        if case .dlna = output {
            Task { try? await dlnaRenderer?.seek(to: clamped) }
        } else {
            active?.seek(to: clamped)
        }
        updateNowPlaying()
    }

    public func skipForward() { seek(to: position + settings.skipForwardInterval) }
    public func skipBackward() { seek(to: position - settings.skipBackInterval) }

    public func setSpeed(_ speed: Double) {
        settings.playbackSpeed = speed
    }

    // MARK: - Sleep timer

    public func setSleepTimer(_ mode: SleepTimerMode) {
        sleepTask?.cancel()
        sleepTimer = mode
        switch mode {
        case .off:
            sleepTimerEndsAt = nil
        case .endOfTrack:
            sleepTimerEndsAt = nil
        case .minutes(let minutes):
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepTimerEndsAt = end
            sleepTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.performSleepStop()
            }
        }
    }

    public var sleepTimerRemaining: TimeInterval? {
        sleepTimerEndsAt?.timeIntervalSinceNow
    }

    private func performSleepStop() {
        sleepTimer = .off
        sleepTimerEndsAt = nil
        if settings.sleepFadeOut, state == .playing {
            active?.fade(to: 0, rampSeconds: 5)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                guard let self else { return }
                self.pause()
                self.active?.snapFade(to: 1)
            }
        } else {
            pause()
        }
    }

    // MARK: - DLNA output

    /// Discovers DLNA renderers on the network (SSDP, ~3 s).
    public func discoverRenderers(timeout: TimeInterval = 3) async -> [DLNARenderer] {
        await DLNARenderer.discover(timeout: timeout)
    }

    /// Switches output to a renderer (or back with `setLocalOutput()`).
    public func setRenderer(_ renderer: DLNARenderer) {
        let wasPlaying = state == .playing
        let resumeAt = position
        engines.forEach { $0.stop() }
        dlnaRenderer = renderer
        output = .dlna(id: renderer.id, name: renderer.displayName)
        do {
            try audioServer.start()
        } catch {
            Log.audio.error("Local audio server failed: \(error.localizedDescription, privacy: .public)")
        }
        startDlnaPolling()
        if let track = currentTrack {
            Task { await cast(track, resumeAt: wasPlaying ? resumeAt : 0, autoPlay: wasPlaying) }
        }
    }

    public func setLocalOutput() {
        guard case .dlna = output else { return }
        let resumeAt = position
        let wasPlaying = state == .playing
        Task { try? await dlnaRenderer?.stop() }
        dlnaRenderer = nil
        output = .local
        dlnaPollTask?.cancel()
        audioServer.stop()
        if currentTrack != nil {
            startCurrent(at: wasPlaying ? resumeAt : 0)
        }
    }

    private func startDlnaPolling() {
        dlnaPollTask?.cancel()
        dlnaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let renderer = self.dlnaRenderer else { return }
                do {
                    let position = try await renderer.position()
                    if position.durationSeconds > 0 { self.duration = position.durationSeconds }
                    self.position = position.trackSeconds
                    if self.state == .playing && position.isStopped && !Task.isCancelled {
                        self.trackEndedNaturally()
                    } else if self.state == .paused && position.isPlaying {
                        self.state = .playing
                    } else if self.state == .playing && position.state == "PAUSED_PLAYBACK" {
                        self.state = .paused
                    }
                } catch {
                    Log.audio.error("DLNA poll failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func cast(_ track: Track, resumeAt: Double, autoPlay: Bool) async {
        guard let renderer = dlnaRenderer else { return }
        do {
            var mime = PathUtils.mimeType(forExtension: PathUtils.fileExtension(track.fileName))
            let url: URL
            if let resource = try await sources.remoteResource(for: track) {
                url = resource.url
            } else {
                let local = try await sources.playableURL(for: track)
                if !audioServer.isRunning { try audioServer.start() }
                guard let served = audioServer.url(for: local, fileName: track.fileName.isEmpty ? local.lastPathComponent : track.fileName) else {
                    throw MuurError.network("Could not start the local audio server")
                }
                url = served
                mime = PathUtils.mimeType(forExtension: local.pathExtension)
            }
            var artworkURL: URL?
            if let key = track.artworkKey, let original = environment.artwork.originalURL(for: key), audioServer.isRunning {
                artworkURL = audioServer.url(for: original, fileName: original.lastPathComponent)
            }
            if autoPlay {
                try await renderer.play(url: url, track: track, mimeType: mime, artworkURL: artworkURL)
                if resumeAt > 1 { try await renderer.seek(to: resumeAt) }
            } else {
                _ = try await UPnPSOAP.call("SetAVTransportURI", service: renderer.device.service(SSDPDiscovery.avTransport)!, arguments: [
                    ("InstanceID", "0"), ("CurrentURI", url.absoluteString),
                ])
            }
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("Casting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Track lifecycle

    private func startCurrent(at resumePosition: Double) {
        guard let track = currentTrack else { return }
        historyRecorded = false
        enqueuedGaplessKey = nil
        duration = track.duration
        position = resumePosition
        trackStartedAt = resumePosition
        if case .dlna = output {
            state = .playing
            updateNowPlaying()
            publishWidgetSnapshot()
            Task { await cast(track, resumeAt: resumePosition, autoPlay: true) }
            return
        }
        crossfadeTask?.cancel()
        isCrossfading = false
        Task { [weak self] in
            guard let self else { return }
            do {
                #if !os(macOS)
                try self.audioSession.activate(mixWithOthers: self.settings.mixWithOthers)
                #endif
                let url = try await self.sources.playableURL(for: track)
                guard self.currentTrack?.libraryKey == track.libraryKey else { return }
                #if os(macOS)
                self.applySampleRate(for: track)
                #endif
                let engine = self.active
                engine?.snapFade(to: 1)
                self.applyAudioSettings()
                try engine?.play(track: track, url: url, dsdMode: self.settings.dsdMode, at: resumePosition)
                self.state = .playing
                self.startPositionTimer()
                self.trackDidStart(track)
            } catch is CancellationError {
            } catch MuurError.cancelled {
            } catch {
                self.lastError = error.localizedDescription
                Log.audio.error("Playback failed: \(error.localizedDescription, privacy: .public)")
                self.skipBrokenTrack()
            }
        }
    }

    private func trackDidStart(_ track: Track) {
        updateNowPlaying()
        publishWidgetSnapshot()
        prefetchUpcoming()
        scheduleQueueSave()
        maybeEnqueueGaplessNext()
        scrobbleNowPlaying(track)
    }

    private func skipBrokenTrack() {
        guard state != .stopped else { return }
        if queue.advance() {
            startCurrent(at: 0)
        } else {
            stop()
        }
    }

    /// Enqueues the next track into the same engine for gapless playback when configured.
    private func maybeEnqueueGaplessNext() {
        guard settings.gapless, settings.crossfadeSeconds <= 0, queue.repeatMode != .one,
              let engine = active, engine.queueIsEmpty,
              let next = queue.upNext(limit: 1).first else { return }
        let key = next.track.libraryKey
        guard enqueuedGaplessKey != key else { return }
        enqueuedGaplessKey = key
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.sources.playableURL(for: next.track)
                guard self.enqueuedGaplessKey == key, self.active === engine else { return }
                try engine.enqueueNext(track: next.track, url: url, dsdMode: self.settings.dsdMode)
            } catch {
                self.enqueuedGaplessKey = nil
                Log.audio.info("Gapless enqueue failed (falls back to normal advance): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The current track finished naturally (render complete / renderer stopped).
    private func trackEndedNaturally() {
        finishTrackForHistory(skipped: false)
        if sleepTimer == .endOfTrack {
            sleepTimer = .off
            performSleepStop()
            return
        }
        if queue.repeatMode == .one {
            startCurrent(at: 0)
            return
        }
        guard queue.advance() else {
            state = .stopped
            stopPositionTimer()
            updateNowPlaying()
            publishWidgetSnapshot()
            scheduleQueueSave()
            return
        }
        if let key = enqueuedGaplessKey, queue.currentTrack?.libraryKey == key, case .local = output {
            // The next decoder is already playing in the same engine: no reload needed.
            enqueuedGaplessKey = nil
            let track = queue.currentTrack
            historyRecorded = false
            position = 0
            trackStartedAt = 0
            duration = track?.duration ?? 0
            if let track { trackDidStart(track) }
            return
        }
        startCurrent(at: 0)
    }

    private func finishTrackForHistory(skipped: Bool) {
        guard let track = currentTrack, !historyRecorded else { return }
        historyRecorded = true
        let listened = max(0, position - trackStartedAt)
        let trackDuration = track.duration
        Task {
            do {
                if skipped {
                    if let id = track.id { try await environment.repository.recordSkip(trackID: id) }
                } else if listened >= 30 || (trackDuration > 0 && listened / trackDuration >= 0.5) {
                    try await environment.repository.recordPlay(of: track, listenedSeconds: listened)
                    await scrobbleCompleted(track)
                }
            } catch {
                Log.audio.error("Recording play history failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Engine events & timers

    private func handleEngineEvent(_ event: EngineEvent, from engineIndex: Int) {
        // Events from the inactive engine only matter while a crossfade is starting it.
        let isActiveEngine = engineIndex == activeIndex
        switch event {
        case .renderingStarted:
            if isActiveEngine, let time = active?.currentTime { position = time }
        case .renderingComplete:
            if isActiveEngine, !isCrossfading, case .local = output { trackEndedNaturally() }
        case .endOfAudio:
            if isActiveEngine, case .local = output, queue.repeatMode != .one {
                // Rendering of the last decoder finished; trackEndedNaturally already advanced the queue.
                if queue.currentTrack == nil || queue.nextItem == nil {
                    state = .stopped
                    stopPositionTimer()
                }
            }
        case .playbackStateChanged(let isPlaying):
            if isActiveEngine, !isPlaying, state == .playing, !isCrossfading, case .local = output {
                // Paused by the system (e.g. an audio session interruption on iOS).
                state = .paused
                updateNowPlaying()
                publishWidgetSnapshot()
            }
        case .decodingAborted(let message), .asynchronousError(let message):
            if isActiveEngine {
                lastError = message
                Log.audio.error("Engine error: \(message, privacy: .public)")
            }
        case .seekCompleted:
            if isActiveEngine, let time = active?.currentTime { position = time }
        case .configurationChange:
            applyAudioSettings()
        }
    }

    private func startPositionTimer() {
        guard positionTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tick() {
        guard case .local = output else { return }
        guard let engine = active else { return }
        if let time = engine.currentTime { position = time }
        if let total = engine.totalTime, total > 0 { duration = total }
        nowPlayingTick += 1
        if nowPlayingTick % 4 == 0 {
            nowPlayingManager.updateElapsed(position, rate: settings.playbackSpeed, isPlaying: state == .playing)
        }
        if nowPlayingTick % 60 == 0 { publishWidgetSnapshot() }
        checkCrossfade()
    }

    private func checkCrossfade() {
        let seconds = settings.crossfadeSeconds
        guard seconds > 0, state == .playing, !isCrossfading, case .local = output,
              let track = currentTrack, duration > seconds + 1,
              duration - position <= seconds, queue.repeatMode != .one,
              let next = queue.upNext(limit: 1).first else { return }
        if settings.crossfadeSkipsSameAlbum, !track.album.isEmpty, track.album == next.track.album,
           track.displayAlbumArtist == next.track.displayAlbumArtist { return }
        isCrossfading = true
        finishTrackForHistory(skipped: false)
        _ = queue.advance()
        let fadeSeconds = seconds
        let outgoing = active
        activeIndex = 1 - activeIndex
        let incoming = active
        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.sources.playableURL(for: next.track)
                guard !Task.isCancelled, let incoming else { return }
                incoming.snapFade(to: 0)
                self.applyAudioSettings()
                try incoming.play(track: next.track, url: url, dsdMode: self.settings.dsdMode)
                incoming.fade(to: 1, rampSeconds: fadeSeconds)
                outgoing?.fade(to: 0, rampSeconds: fadeSeconds)
                let track = next.track
                self.historyRecorded = false
                self.position = 0
                self.trackStartedAt = 0
                self.duration = track.duration
                self.trackDidStart(track)
                try await Task.sleep(nanoseconds: UInt64((fadeSeconds + 0.3) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                outgoing?.stop()
                outgoing?.snapFade(to: 1)
                self.isCrossfading = false
            } catch {
                outgoing?.snapFade(to: 1)
                self.isCrossfading = false
            }
        }
    }

    // MARK: - Now Playing / widgets / prefetch

    private func configureRemoteCommands() {
        nowPlayingManager.configure(skipBack: settings.skipBackInterval, skipForward: settings.skipForwardInterval)
        nowPlayingManager.onPlay = { [weak self] in self?.resume() }
        nowPlayingManager.onPause = { [weak self] in self?.pause() }
        nowPlayingManager.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        nowPlayingManager.onNext = { [weak self] in self?.next() }
        nowPlayingManager.onPrevious = { [weak self] in self?.previous() }
        nowPlayingManager.onSeek = { [weak self] time in self?.seek(to: time) }
        nowPlayingManager.onSkipForward = { [weak self] _ in self?.skipForward() }
        nowPlayingManager.onSkipBackward = { [weak self] _ in self?.skipBackward() }
        nowPlayingManager.onChangePlaybackRate = { [weak self] rate in self?.setSpeed(rate) }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            nowPlayingManager.clear()
            return
        }
        var artwork: Data?
        if let key = track.artworkKey {
            artwork = environment.artwork.thumbnailData(for: key, size: ArtworkCache.Size.medium.rawValue)
        }
        nowPlayingManager.update(track: track, elapsed: position, duration: duration,
                                 rate: settings.playbackSpeed, isPlaying: state == .playing, artwork: artwork)
        nowPlayingManager.setPlaybackStatePlaying(state == .playing)
    }

    private func publishWidgetSnapshot() {
        let track = currentTrack
        let upNext = queue.upNext(limit: 20).map(\.track)
        let playing = state == .playing
        let elapsed = position
        let rate = settings.playbackSpeed
        Task { [weak self] in
            guard let self else { return }
            let recent = (try? await self.environment.repository.recentlyPlayed(limit: 10)) ?? []
            let lyrics = track.flatMap { await self.environment.lyrics.lyrics(for: $0, allowOnline: false) }
            self.widgetWriter.publish(nowPlaying: track, isPlaying: playing, elapsed: elapsed, playbackRate: rate,
                                      upNext: upNext, recentlyPlayed: recent, lyrics: lyrics,
                                      accentHex: self.settings.accent.hex, canResume: !self.queue.isEmpty)
        }
    }

    private func prefetchUpcoming() {
        let upcoming = queue.upNext(limit: 2).map(\.track)
        sources.prefetch(upcoming)
        var pinned = Set(upcoming.map(\.sourceURI))
        if let current = currentTrack { pinned.insert(current.sourceURI) }
        Task { await sources.pinCached(pinned) }
    }

    // MARK: - Scrobbling (Subsonic-compatible sources)

    private func scrobbleNowPlaying(_ track: Track) {
        guard let sourceID = track.sourceID.flatMap(UUID.init(uuidString:)) else { return }
        Task { [weak self] in
            guard let source = try? await self?.sources.source(id: sourceID) as? SubsonicSource else { return }
            try? await source.scrobble(uri: track.sourceURI, submission: false)
        }
    }

    private func scrobbleCompleted(_ track: Track) async {
        guard let sourceID = track.sourceID.flatMap(UUID.init(uuidString:)) else { return }
        if let source = try? await sources.source(id: sourceID) as? SubsonicSource {
            try? await source.scrobble(uri: track.sourceURI, submission: true)
        }
    }

    // MARK: - Persistence

    private func scheduleQueueSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let state = QueueState(queue: self.queue, trackPosition: self.position, isPlaying: self.state == .playing)
            try? state.save(to: self.environment.paths.queueStateURL)
        }
    }

    private func restoreQueueIfNeeded() {
        guard !restoredQueue, settings.resumeOnLaunch,
              let saved = QueueState.load(from: environment.paths.queueStateURL), !saved.queue.isEmpty else { return }
        restoredQueue = true
        queue = saved.queue
        duration = queue.currentTrack?.duration ?? 0
        position = saved.trackPosition
        publishWidgetSnapshot()
    }

    /// Resumes the restored queue (call from a "Resume" widget action or the Now Playing screen).
    public func resumeRestoredQueue() {
        guard state == .stopped, queue.currentTrack != nil else { return }
        startCurrent(at: position)
    }
}
