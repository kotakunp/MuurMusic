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

    @Published public private(set) var state: PlaybackState = .stopped {
        didSet { updateMeterPublishing() }
    }
    @Published public private(set) var queue = PlaybackQueue()
    @Published public private(set) var isPreparing = false
    /// Live position updates, published separately from the rest of the player state.
    public let clock = PlaybackClock()
    /// Seconds into the current track (CUE window relative). Observe `clock` to follow it live.
    public private(set) var position: Double {
        get { clock.position }
        set { clock.position = newValue }
    }
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isCrossfading = false
    @Published public private(set) var output: PlaybackOutput = .local {
        didSet { updateMeterPublishing() }
    }
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
    private var startTask: Task<Void, Never>?
    private var startID: UUID?
    private var startFailureBudget = 0
    private var resumesSameTrack = false
    private var activeDecoderID: UUID?
    private var activeDecoderStarted = false
    private var pendingSeek: Double?
    private var gaplessTask: Task<Void, Never>?
    private var pendingGaplessID: UUID?
    private var gaplessNext: Transition?
    private var crossfadeTask: Task<Void, Never>?
    private var crossfadeNext: Transition?
    private var failedCrossfadeFrom: UUID?
    private var saveTask: Task<Void, Never>?
    private var cachePinTask: Task<Void, Never>?
    private var dlnaRenderer: DLNARenderer?
    private var castTask: Task<Void, Never>?
    private var castFile: PlaybackFileLease?
    private var castItemID: UUID?
    private let audioServer = LocalAudioServer()
    private var dlnaPollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var currentTrackObservation: Task<Void, Never>?
    private var trackStartedAt: Double = 0
    private var historyRecorded = false
    private var restoredQueue = false

    private struct Transition {
        let itemID: UUID
        let decoderID: UUID
        var started = false
    }

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
        $queue.map { $0.currentTrack?.libraryKey }.removeDuplicates().sink { [weak self] key in
            self?.observeFavorite(libraryKey: key)
        }.store(in: &cancellables)
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
        settings.$gapless.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconcileTransitions() }
        }.store(in: &cancellables)
        settings.$crossfadeSeconds.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconcileTransitions() }
        }.store(in: &cancellables)
        #if os(macOS)
        settings.$outputDeviceUID.dropFirst().sink { [weak self] _ in self?.applyOutputDevice() }.store(in: &cancellables)
        #endif
        engines.forEach { $0.setSpeed(settings.playbackSpeed) }
    }

    /// Pushes EQ / speed / DSP / ReplayGain settings into both engines.
    public func applyAudioSettings() {
        for engine in engines {
            applyAudioSettings(to: engine, for: engine === inactive && crossfadeNext != nil ? queue.nextItem?.track : currentTrack)
        }
    }

    private func applyAudioSettings(to engine: PlaybackEngine, for track: Track?) {
        engine.setSpeed(settings.playbackSpeed)
        engine.applyEQ(gains: settings.eqBandGains, preampDb: settings.eqPreampDb, enabled: settings.eqEnabled)
        engine.applyDSP(chainJSON: settings.dspChainJSON, dspEnabled: settings.dspEnabled, preGainDb: track.map(replayGainDb(for:)) ?? 0,
                        loudnessEnabled: settings.loudnessEnabled, loudnessBoostDb: settings.loudnessBoostDb)
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

    private func updateMeterPublishing() {
        meters.setPublishing(state == .playing && output == .local)
    }

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
        let items = tracks.map { QueueItem(track: $0) }
        finishTrackForHistory(skipped: false)
        queue = PlaybackQueue(items: items, startIndex: min(max(0, startIndex), items.count - 1), shuffleMode: mode,
                              repeatMode: queue.repeatMode)
        startCurrent(at: 0)
    }

    /// Plays a single track immediately.
    public func play(_ track: Track) {
        play([track], startIndex: 0)
    }

    /// Jumps to a queue entry.
    public func playItem(id: UUID) {
        var updated = queue
        guard updated.jump(to: id) else { return }
        finishTrackForHistory(skipped: false)
        queue = updated
        startCurrent(at: 0)
    }

    public func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue.insertNext(tracks.map { QueueItem(track: $0) })
        scheduleQueueSave()
        reconcileTransitions()
        prefetchUpcoming()
    }

    public func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.append(tracks.map { QueueItem(track: $0) })
        scheduleQueueSave()
        if wasEmpty && state == .stopped { startCurrent(at: 0) }
        else { reconcileTransitions() }
    }

    public func removeFromQueue(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removedCurrent = ids.contains(where: { $0 == queue.currentItem?.id })
        if removedCurrent { finishTrackForHistory(skipped: false) }
        queue.remove(ids: ids)
        scheduleQueueSave()
        if removedCurrent {
            if queue.currentTrack != nil {
                startCurrent(at: 0)
            } else {
                stop()
            }
        } else { reconcileTransitions() }
        prefetchUpcoming()
    }

    public func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.moveInPlayOrder(from: source, to: destination)
        scheduleQueueSave()
        reconcileTransitions()
        prefetchUpcoming()
    }

    public func clearQueue() {
        stop()
        queue = PlaybackQueue(repeatMode: queue.repeatMode)
        scheduleQueueSave()
        prefetchUpcoming()
    }

    public func clearUpcoming() {
        removeFromQueue(ids: Set(queue.following.map(\.id)))
    }

    public func setShuffle(_ mode: ShuffleMode) {
        queue.setShuffle(mode)
        scheduleQueueSave()
        reconcileTransitions()
        prefetchUpcoming()
    }

    public func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
        scheduleQueueSave()
        reconcileTransitions()
    }

    // MARK: - Transport

    public func togglePlayPause() {
        if isPreparing { pause(); return }
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped:
            if queue.currentTrack != nil { startCurrent(at: position) }
        }
    }

    public func pause() {
        guard state == .playing || isPreparing else { return }
        if case .dlna = output {
            castTask?.cancel()
            castTask = nil
            Task { try? await dlnaRenderer?.pause() }
        } else if isPreparing {
            stopLocalAudio()
        } else {
            cancelCrossfade()
            active?.pause()
        }
        state = .paused
        updateNowPlaying()
        publishWidgetSnapshot()
        scheduleQueueSave()
    }

    public func resume() {
        guard state == .paused else { return }
        if case .dlna = output {
            if let item = queue.currentItem, castItemID != item.id {
                startCast(item, resumeAt: position, autoPlay: true)
            } else {
                Task { try? await dlnaRenderer?.play() }
            }
        } else {
            guard activeDecoderID != nil else { startCurrent(at: position); return }
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
        finishTrackForHistory(skipped: false)
        if case .dlna = output {
            castTask?.cancel()
            castTask = nil
            Task { try? await dlnaRenderer?.stop() }
            castFile = nil
            castItemID = nil
        }
        stopLocalAudio()
        state = .stopped
        position = 0
        nowPlayingManager.clear()
        stopPositionTimer()
        publishWidgetSnapshot()
        scheduleQueueSave()
        prefetchUpcoming()
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
            cancelCrossfade()
            if activeDecoderStarted {
                active?.seek(to: clamped)
            } else {
                pendingSeek = clamped
            }
        }
        updateNowPlaying()
        scheduleQueueSave()
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
        reconcileTransitions()
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
        let wasPlaying = state == .playing || isPreparing
        let resumeAt = position
        stopLocalAudio()
        if wasPlaying { state = .playing }
        castTask?.cancel()
        castTask = nil
        castFile = nil
        castItemID = nil
        if let previous = dlnaRenderer, previous !== renderer {
            Task { try? await previous.stop() }
        }
        dlnaRenderer = renderer
        output = .dlna(id: renderer.id, name: renderer.displayName)
        do {
            try audioServer.start()
        } catch {
            Log.audio.error("Local audio server failed: \(error.localizedDescription, privacy: .public)")
        }
        startDlnaPolling()
        if let item = queue.currentItem {
            startCast(item, resumeAt: wasPlaying ? resumeAt : 0, autoPlay: wasPlaying)
        }
    }

    public func setLocalOutput() {
        guard case .dlna = output else { return }
        let resumeAt = position
        let wasPlaying = state == .playing
        let renderer = dlnaRenderer
        Task { try? await renderer?.stop() }
        castTask?.cancel()
        castTask = nil
        dlnaRenderer = nil
        castFile = nil
        castItemID = nil
        output = .local
        dlnaPollTask?.cancel()
        audioServer.stop()
        if wasPlaying, currentTrack != nil {
            startCurrent(at: resumeAt, continuing: true)
        }
    }

    private func startDlnaPolling() {
        dlnaPollTask?.cancel()
        dlnaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let renderer = self.dlnaRenderer else { return }
                do {
                    let position = try await renderer.position()
                    guard !Task.isCancelled, self.dlnaRenderer === renderer, self.castTask == nil else {
                        try await Task.sleep(for: .seconds(1))
                        continue
                    }
                    if position.durationSeconds > 0, self.duration != position.durationSeconds {
                        self.duration = position.durationSeconds
                    }
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

    private func startCast(_ item: QueueItem, resumeAt: Double, autoPlay: Bool) {
        castTask?.cancel()
        castTask = Task { [weak self] in
            await self?.cast(item, resumeAt: resumeAt, autoPlay: autoPlay)
            if !Task.isCancelled { self?.castTask = nil }
        }
    }

    private func cast(_ item: QueueItem, resumeAt: Double, autoPlay: Bool) async {
        guard !Task.isCancelled, let renderer = dlnaRenderer else { return }
        let track = item.track
        do {
            var mime = PathUtils.mimeType(forExtension: PathUtils.fileExtension(track.fileName))
            let url: URL
            var file: PlaybackFileLease?
            if let resource = try await sources.remoteResource(for: track) {
                url = resource.url
            } else {
                let leasedFile = try await sources.acquirePlaybackFile(for: track)
                file = leasedFile
                let local = leasedFile.url
                guard !Task.isCancelled, dlnaRenderer === renderer else { return }
                if !audioServer.isRunning { try audioServer.start() }
                guard let served = audioServer.url(for: local, fileName: track.fileName.isEmpty ? local.lastPathComponent : track.fileName) else {
                    throw MuurError.network("Could not start the local audio server")
                }
                url = served
                mime = PathUtils.mimeType(forExtension: local.pathExtension)
            }
            guard !Task.isCancelled, dlnaRenderer === renderer, queue.currentItem?.id == item.id,
                  !autoPlay || state == .playing else { return }
            var artworkURL: URL?
            if let key = track.artworkKey, let original = environment.artwork.originalURL(for: key), audioServer.isRunning {
                artworkURL = audioServer.url(for: original, fileName: original.lastPathComponent)
            }
            if autoPlay {
                try await renderer.play(url: url, track: track, mimeType: mime, artworkURL: artworkURL)
                if !Task.isCancelled && resumeAt > 1 { try await renderer.seek(to: resumeAt) }
            } else {
                _ = try await UPnPSOAP.call("SetAVTransportURI", service: renderer.device.service(SSDPDiscovery.avTransport)!, arguments: [
                    ("InstanceID", "0"), ("CurrentURI", url.absoluteString),
                ])
            }
            if !Task.isCancelled, dlnaRenderer === renderer, queue.currentItem?.id == item.id, !autoPlay || state == .playing {
                castFile = file
                castItemID = item.id
            }
        } catch {
            guard !Task.isCancelled, dlnaRenderer === renderer, queue.currentItem?.id == item.id,
                  !autoPlay || state == .playing else { return }
            lastError = error.localizedDescription
            Log.audio.error("Casting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Track lifecycle

    private func startCurrent(at resumePosition: Double, continuing: Bool = false, retries: Int? = nil) {
        guard let item = queue.currentItem else { return }
        let track = item.track
        if !continuing {
            historyRecorded = false
            trackStartedAt = resumePosition
        }
        duration = track.duration
        position = resumePosition
        if case .dlna = output {
            state = .playing
            updateNowPlaying()
            publishWidgetSnapshot()
            startCast(item, resumeAt: resumePosition, autoPlay: true)
            return
        }
        let retryCount = retries ?? (state == .playing && !continuing ? max(0, queue.count - 1) : 0)
        stopLocalAudio()
        state = .stopped
        startFailureBudget = retryCount
        resumesSameTrack = continuing
        isPreparing = true
        pendingSeek = resumePosition > 0.5 ? resumePosition : nil
        let id = UUID()
        startID = id
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.sources.acquirePlaybackFile(for: track)
                guard !Task.isCancelled, self.startID == id,
                      self.queue.currentItem?.id == item.id, case .local = self.output else { return }
                guard let engine = self.active else { throw MuurError.invalidData("Audio output is unavailable.") }
                #if !os(macOS)
                try self.audioSession.activate(mixWithOthers: self.settings.mixWithOthers)
                #endif
                #if os(macOS)
                self.applySampleRate(for: track)
                #endif
                self.activeDecoderID = id
                engine.snapFade(to: 1)
                self.applyAudioSettings(to: engine, for: track)
                try engine.play(track: track, file: file, decoderID: id, dsdMode: self.settings.dsdMode)
                // Some decoder errors arrive without a decoder callback.
                try await Task.sleep(for: .seconds(15))
                guard self.startID == id else { return }
                self.failStart("The audio decoder did not start.")
            } catch {
                guard !Task.isCancelled, self.startID == id else { return }
                self.failStart(error.localizedDescription)
            }
        }
    }

    private func failStart(_ message: String) {
        lastError = message
        Log.audio.error("Playback failed: \(message, privacy: .public)")
        if startFailureBudget > 0, queue.advance() {
            startCurrent(at: 0, retries: startFailureBudget - 1)
            return
        }
        settleStopped()
    }

    private func stopLocalAudio() {
        startTask?.cancel()
        startTask = nil
        startID = nil
        startFailureBudget = 0
        resumesSameTrack = false
        isPreparing = false
        activeDecoderID = nil
        activeDecoderStarted = false
        pendingSeek = nil
        failedCrossfadeFrom = nil
        cancelGapless()
        cancelCrossfade()
        engines.forEach { $0.stop() }
        stopPositionTimer()
    }

    private func cancelGapless() {
        gaplessTask?.cancel()
        gaplessTask = nil
        pendingGaplessID = nil
        gaplessNext = nil
    }

    private func cancelCrossfade() {
        let wasTransitioning = crossfadeNext != nil || isCrossfading
        crossfadeTask?.cancel()
        crossfadeTask = nil
        crossfadeNext = nil
        isCrossfading = false
        if wasTransitioning {
            inactive?.stop()
            inactive?.snapFade(to: 1)
            active?.snapFade(to: 1)
        }
    }

    private func trackDidStart(_ track: Track, reportToServer: Bool = true) {
        updateNowPlaying()
        publishWidgetSnapshot()
        prefetchUpcoming()
        scheduleQueueSave()
        maybeEnqueueGaplessNext()
        if reportToServer { scrobbleNowPlaying(track) }
    }

    private var nextGaplessItem: QueueItem? {
        guard settings.gapless, settings.crossfadeSeconds <= 0, queue.repeatMode != .one,
              sleepTimer != .endOfTrack, case .local = output,
              let next = queue.nextItem, next.id != queue.currentItem?.id else { return nil }
        return next
    }

    private func reconcileTransitions() {
        if let planned = crossfadeNext,
           planned.itemID != queue.nextItem?.id || queue.repeatMode == .one ||
           sleepTimer == .endOfTrack || settings.crossfadeSeconds <= 0 {
            cancelCrossfade()
        }
        let next = nextGaplessItem?.id
        if let previous = gaplessNext, previous.itemID != next {
            // The player can already be decoding the queued item. Stop before accepting
            // the new order so the old decoder cannot become audible.
            if state == .playing { startCurrent(at: position, continuing: true) }
            else { stopLocalAudio() }
            return
        }
        if pendingGaplessID != nil && pendingGaplessID != next { cancelGapless() }
        maybeEnqueueGaplessNext()
    }

    private func maybeEnqueueGaplessNext() {
        guard state == .playing, activeDecoderStarted, let currentID = activeDecoderID,
              let engine = active, let next = nextGaplessItem, gaplessTask == nil, gaplessNext == nil else { return }
        let decoderID = UUID()
        pendingGaplessID = next.id
        gaplessTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.sources.acquirePlaybackFile(for: next.track)
                guard !Task.isCancelled, self.activeDecoderID == currentID, self.active === engine,
                      self.nextGaplessItem?.id == next.id else { return }
                try engine.enqueueNext(track: next.track, file: file, decoderID: decoderID, dsdMode: self.settings.dsdMode)
                self.gaplessNext = Transition(itemID: next.id, decoderID: decoderID)
            } catch {
                guard !Task.isCancelled else { return }
                Log.audio.info("Gapless enqueue failed (falls back to normal advance): \(error.localizedDescription, privacy: .public)")
            }
            if !Task.isCancelled {
                self.gaplessTask = nil
                self.pendingGaplessID = nil
            }
        }
    }

    /// The current track finished naturally (render complete / renderer stopped).
    private func trackEndedNaturally() {
        cancelCrossfade()
        finishTrackForHistory(skipped: false)
        if sleepTimer == .endOfTrack {
            sleepTimer = .off
            sleepTimerEndsAt = nil
            // The track already finished, so pausing would leave an idle engine running. Stop and line up
            // the next track so Play continues the queue.
            if queue.repeatMode != .one { queue.advance() }
            position = 0
            duration = currentTrack?.duration ?? 0
            settleStopped()
            return
        }
        if queue.repeatMode == .one {
            startCurrent(at: 0)
            return
        }
        guard queue.advance() else {
            // Play after the queue ends restarts the last track instead of resuming at its end.
            position = 0
            settleStopped()
            return
        }
        if let next = gaplessNext, queue.currentItem?.id == next.itemID, case .local = output {
            cancelGapless()
            activeDecoderID = next.decoderID
            activeDecoderStarted = false
            let track = queue.currentTrack
            historyRecorded = false
            position = 0
            trackStartedAt = 0
            duration = track?.duration ?? 0
            if next.started {
                decoderDidStart(next.decoderID)
            } else {
                isPreparing = true
                startTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, self.activeDecoderID == next.decoderID,
                          !self.activeDecoderStarted else { return }
                    self.startCurrent(at: 0)
                }
            }
            return
        }
        startCurrent(at: 0)
    }

    private func settleStopped() {
        state = .stopped
        stopLocalAudio()
        updateNowPlaying()
        publishWidgetSnapshot()
        scheduleQueueSave()
        prefetchUpcoming()
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
        if case .configurationChange = event { applyAudioSettings(); return }
        guard case .local = output else { return }
        if engineIndex != activeIndex {
            handleIncomingCrossfadeEvent(event)
            return
        }
        switch event {
        case .renderingStarted(let id):
            if gaplessNext?.decoderID == id { gaplessNext?.started = true }
            decoderDidStart(id)
        case .renderingComplete(let id):
            if activeDecoderID == id { trackEndedNaturally() }
        case .endOfAudio:
            if startID == nil, activeDecoderID != nil, !activeDecoderStarted, active?.isReady == false {
                // A queued decoder was adopted but never rendered. Try a regular start.
                startCurrent(at: position)
            }
        case .playbackStateChanged(let isPlaying):
            if !isPlaying, state == .playing, active?.isPlaying == false {
                pause()
            }
        case .decodingAborted(let id, let message):
            if gaplessNext?.decoderID == id {
                cancelGapless()
            } else if activeDecoderID == id {
                if startID == nil && !activeDecoderStarted {
                    startCurrent(at: position)
                } else {
                    failStart(message)
                }
            }
        case .asynchronousError(let message):
            Log.audio.error("Engine error: \(message, privacy: .public)")
        case .seekCompleted(let id, _):
            if activeDecoderID == id, let time = active?.currentTime { position = time }
        case .configurationChange:
            break
        }
    }

    private func decoderDidStart(_ id: UUID) {
        guard activeDecoderID == id, !activeDecoderStarted, let track = currentTrack else { return }
        startTask?.cancel()
        startTask = nil
        startID = nil
        startFailureBudget = 0
        activeDecoderStarted = true
        isPreparing = false
        if let target = pendingSeek, active?.seek(to: target) == true {
            position = target
        } else if let time = active?.currentTime {
            position = time
        }
        pendingSeek = nil
        if state != .paused { state = .playing }
        startPositionTimer()
        let reportToServer = !resumesSameTrack
        resumesSameTrack = false
        trackDidStart(track, reportToServer: reportToServer)
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
        guard activeDecoderStarted, let engine = active else { return }
        if let time = engine.currentTime { position = time }
        if let total = engine.totalTime, total > 0, total != duration { duration = total }
        nowPlayingTick += 1
        if nowPlayingTick % 4 == 0 {
            nowPlayingManager.updateElapsed(position, rate: settings.playbackSpeed, isPlaying: state == .playing)
        }
        if nowPlayingTick % 60 == 0 { publishWidgetSnapshot() }
        checkCrossfade()
    }

    private func checkCrossfade() {
        let seconds = settings.crossfadeSeconds
        guard seconds > 0, state == .playing, !isCrossfading, crossfadeNext == nil, case .local = output,
              let outgoingID = activeDecoderID, outgoingID != failedCrossfadeFrom, let incoming = inactive,
              let track = currentTrack, duration > seconds + 1,
              duration - position <= seconds, queue.repeatMode != .one, sleepTimer != .endOfTrack,
              let next = queue.nextItem, next.id != queue.currentItem?.id else { return }
        if settings.crossfadeSkipsSameAlbum, !track.album.isEmpty, track.album == next.track.album,
           track.displayAlbumArtist == next.track.displayAlbumArtist { return }
        let decoderID = UUID()
        crossfadeNext = Transition(itemID: next.id, decoderID: decoderID)
        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.sources.acquirePlaybackFile(for: next.track)
                guard !Task.isCancelled, self.crossfadeNext?.decoderID == decoderID,
                      self.activeDecoderID == outgoingID, self.queue.nextItem?.id == next.id else { return }
                self.applyAudioSettings(to: incoming, for: next.track)
                incoming.snapFade(to: 0)
                try incoming.play(track: next.track, file: file, decoderID: decoderID, dsdMode: self.settings.dsdMode)
                try await Task.sleep(for: .seconds(15))
                if self.crossfadeNext?.decoderID == decoderID { self.crossfadeFailed() }
            } catch {
                guard !Task.isCancelled, self.crossfadeNext?.decoderID == decoderID else { return }
                self.crossfadeFailed()
            }
        }
    }

    private func handleIncomingCrossfadeEvent(_ event: EngineEvent) {
        guard let next = crossfadeNext else { return }
        switch event {
        case .renderingStarted(let id) where id == next.decoderID:
            guard state == .playing, queue.nextItem?.id == next.itemID,
                  let track = queue.nextItem?.track, let incoming = inactive, let outgoing = active else {
                cancelCrossfade()
                return
            }
            finishTrackForHistory(skipped: false)
            guard queue.advance() else { cancelCrossfade(); return }
            let seconds = max(0, min(settings.crossfadeSeconds, duration - position))
            crossfadeTask?.cancel()
            crossfadeNext = nil
            isCrossfading = true
            activeIndex = 1 - activeIndex
            activeDecoderID = id
            activeDecoderStarted = false
            historyRecorded = false
            position = 0
            trackStartedAt = 0
            duration = track.duration
            if seconds > 0 {
                incoming.fade(to: 1, rampSeconds: seconds)
                outgoing.fade(to: 0, rampSeconds: seconds)
            } else {
                incoming.snapFade(to: 1)
                outgoing.stop()
            }
            decoderDidStart(id)
            crossfadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds + 0.3))
                guard !Task.isCancelled, let self else { return }
                self.cancelCrossfade()
            }
        case .decodingAborted(let id, _) where id == next.decoderID:
            crossfadeFailed()
        default:
            break
        }
    }

    private func crossfadeFailed() {
        failedCrossfadeFrom = activeDecoderID
        cancelCrossfade()
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
        nowPlayingManager.onSetFavorite = { [weak self] track, favorite in
            guard let self else { return }
            do {
                try await self.updateFavorite(for: track, to: favorite)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func updateFavorite(for track: Track, to favorite: Bool? = nil) async throws -> Bool {
        let stored = try await environment.repository.updateFavorite(for: track, to: favorite)
        applyFavorite(stored, matching: track.libraryKey)
        return stored.favorite
    }

    private func observeFavorite(libraryKey: String?) {
        currentTrackObservation?.cancel()
        guard let libraryKey else { currentTrackObservation = nil; return }
        let repository = environment.repository
        currentTrackObservation = Task { [weak self] in
            do {
                for try await track in repository.observeTrack(libraryKey: libraryKey) {
                    guard !Task.isCancelled, let self, self.currentTrack?.libraryKey == libraryKey else { return }
                    if let track { self.applyFavorite(track, matching: libraryKey) }
                }
            } catch {
                if !Task.isCancelled { Log.audio.error("Now Playing favorite observation failed: \(error.localizedDescription)") }
            }
        }
    }

    private func applyFavorite(_ stored: Track, matching libraryKey: String) {
        var updated = queue
        guard updated.updateFavorite(from: stored, matching: libraryKey) else { return }
        queue = updated
        let matchesCurrent = currentTrack?.libraryKey == libraryKey || (stored.id != nil && currentTrack?.id == stored.id)
        if matchesCurrent, state != .stopped {
            updateNowPlaying()
            publishWidgetSnapshot()
        }
        scheduleQueueSave()
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
            var lyrics: Lyrics?
            if let track { lyrics = await self.environment.lyrics.lyrics(for: track, allowOnline: false) }
            self.widgetWriter.publish(nowPlaying: track, isPlaying: playing, elapsed: elapsed, playbackRate: rate,
                                      upNext: upNext, recentlyPlayed: recent, lyrics: lyrics,
                                      accentHex: self.settings.accent.hex, canResume: !self.queue.isEmpty)
        }
    }

    private func prefetchUpcoming() {
        let upcoming = state == .stopped ? [] : queue.upNext(limit: 2).map(\.track)
        cachePinTask?.cancel()
        cachePinTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await sources.pinCached(Set(upcoming.map(\.sourceURI)))
            guard !Task.isCancelled else { return }
            sources.prefetch(upcoming)
        }
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
