import AVFoundation
import AVKit
import CoreImage
import Observation
import SwiftUI
import UIKit

enum PlaybackPhase: Equatable {
    case idle
    case loading
    case ready
    case ended
    case failed(String)
}

/** The side panels the player can open. */
enum PlayerPanel: String, Identifiable, Hashable {
    case audio, subtitles, speed, chapters, episodes, quality, subtitleStyle, onlineSubtitles

    var id: String { rawValue }
}

/**
 * The video player: one AVPlayer, the Jellyfin session around it (which
 * version and tracks, reporting progress to the server), subtitles drawn by
 * Kinema, skipping intros and credits, Up Next, Picture in Picture, and the
 * state the player's screen shows.
 */
@MainActor
@Observable
final class PlayerModel: NSObject {
    @ObservationIgnored private unowned let graph: AppGraph

    // ---------------------------------------------------------------- what --
    private(set) var item: Item?
    private(set) var stream: ResolvedStream?
    /** Playing a download, not the server. */
    private(set) var offline: DownloadRecord?
    private(set) var phase: PlaybackPhase = .idle
    private(set) var isPlaying = false
    private(set) var isBuffering = false

    // -------------------------------------------------------------- tracks --
    private(set) var audioIndex: Int?
    private(set) var subtitleIndex: Int?
    private(set) var secondaryIndex: Int?
    /** Seconds the subtitles are moved by: positive shows them later. */
    var subtitleDelay: Double = 0
    /** A picture subtitle the server draws into the video. */
    private(set) var burnedIn = false
    private(set) var maxBitrateOverride: Int?

    let clock = PlayerClock()
    let subtitles = SubtitleState()

    // ------------------------------------------------------------ controls --
    var controlsVisible = true
    var locked = false
    var panel: PlayerPanel?
    var statsVisible = false
    private(set) var speed: Double = 1
    /** Holding the screen plays faster until let go (or locked with a swipe up). */
    private(set) var holding = false
    private(set) var holdLocked = false
    var aspect: AspectMode = .fit
    /** Turned to portrait for an upright video. */
    private(set) var portrait = false
    /** Portrait or landscape chosen in the player (•••), kept for the episodes after, until it closes. */
    @ObservationIgnored private var orientationChosen = false
    /** Whether the player is taller than wide on screen right now (set by the player's screen). */
    var portraitLayout = false

    // ------------------------------------------------- segments and up next --
    private(set) var segments: [MediaSegment] = []
    private(set) var activeSegment: MediaSegment?
    private(set) var nextEpisode: Item?
    private(set) var previousEpisode: Item?
    private(set) var upNextShown = false
    private(set) var upNextCountdown: Int?
    private(set) var seasonEpisodes: [Item] = []

    // ----------------------------------------------------------------- PiP --
    private(set) var pipActive = false
    private(set) var pipPossible = false

    // -------------------------------------------------------------- engine --
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let surface = PlayerSurfaceView()
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var subtitleObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var readyHandled = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var primaryTrack = SubtitleTrack.empty
    @ObservationIgnored private var secondaryTrack = SubtitleTrack.empty
    @ObservationIgnored private var skippedSegments: Set<String> = []
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var startPosition: Double = 0
    @ObservationIgnored private var speedBeforeHold: Double = 1
    @ObservationIgnored private var triedWithoutDirectPlay = false
    @ObservationIgnored private var restoringFromPiP = false
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var detachedForBackground = false
    @ObservationIgnored private var lastReportedTicks: Int64 = 0
    @ObservationIgnored private var nowPlayingArtwork: UIImage?
    @ObservationIgnored private(set) var trickplay: TrickplayThumbnails?
    /** The next episode, prepared ahead: its stream asked for and its asset loading. */
    @ObservationIgnored private var preloaded: (id: String, prepared: Prepared, asset: AVURLAsset)?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /** Recording a GIF of what's playing. */
    private(set) var recordingGIF = false
    @ObservationIgnored private var gifTask: Task<Void, Never>?
    /** The server's own segments, and what the online databases have, merged with the marks into [segments]. */
    @ObservationIgnored private var serverSegments: [MediaSegment] = []
    @ObservationIgnored private var onlineFound: [IntroDatabase.Found] = []
    @ObservationIgnored private var session = 0

    init(graph: AppGraph) {
        self.graph = graph
        super.init()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        surface.playerLayer.player = player
        setUpPictureInPicture()
        observePlayer()
        observeApp()
        NowPlaying.register(self)
    }

    var skipForwardSeconds: Int { graph.settings.settings.skipForward }
    var skipBackSeconds: Int { graph.settings.settings.skipBack }

    var source: MediaSource? { stream?.source ?? item?.mediaSources?.first { $0.id == offline?.mediaSourceId } ?? item?.primarySource }

    var chapters: [Chapter] { (item?.chapters ?? []).filter { $0.start >= 0 }.sorted { $0.startPositionTicks < $1.startPositionTicks } }

    var gravity: AVLayerVideoGravity {
        switch aspect {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    // ---------------------------------------------------------- opening --

    /** Play [item] from [startTicks], with the version [mediaSourceId] (or the first). */
    func open(_ item: Item, startTicks: Int64, mediaSourceId: String?) {
        if let record = graph.downloads.record(item.id), record.isDone, mediaSourceId == nil || mediaSourceId == record.mediaSourceId {
            openOffline(record, startTicks: startTicks)
            return
        }
        begin(item)
        startPosition = Ticks.seconds(startTicks)
        loadTask = Task { await self.load(item, sourceId: mediaSourceId, at: startPosition) }
    }

    /** Play a download, with no server needed. */
    func openOffline(_ record: DownloadRecord, startTicks: Int64? = nil) {
        guard let url = graph.downloads.fileURL(for: record) else {
            graph.messages.error("The downloaded file is missing.")
            return
        }
        begin(record.item)
        offline = record
        startPosition = Ticks.seconds(startTicks ?? record.resumeTicks)
        let settings = graph.settings.settings
        // A copy made by the server has one language; the original file has them all.
        audioIndex = record.kind == .hls ? record.audioIndex : nil
        let source = record.item.mediaSources?.first { $0.id == record.mediaSourceId } ?? record.item.primarySource
        stream = source.map { ResolvedStream(url: url, method: .directPlay, source: $0, playSessionId: nil) }
        // Subtitles saved with the download, chosen the usual way.
        if let source {
            let wanted = StreamResolver.subtitleIndex(source, mode: settings.subtitleMode, language: settings.subtitleLanguage, audioLanguage: source.audioStreams.first?.language)
            if let wanted, record.subtitles.contains(where: { $0.index == wanted }) { subtitleIndex = wanted }
        }
        let asset = AVURLAsset(url: url)
        start(AVPlayerItem(asset: asset), at: startPosition)
        Task { await loadSubtitles() }
        Task { await loadSegments(record.item) }
        Task { await refreshDownloadedSubtitles(record.id) }
        loadEpisodesAround(record.item)
    }

    /** With a connection, subtitles added on the server since the download are saved with it and listed. */
    private func refreshDownloadedSubtitles(_ id: String) async {
        guard let refreshed = await graph.downloads.refreshSubtitles(id), refreshed.added > 0, offline?.id == id else { return }
        offline = refreshed.record
        item = refreshed.record.item
        if let updated = refreshed.record.item.mediaSources?.first(where: { $0.id == stream?.source.id }) { adopt(updated) }
        graph.messages.show(refreshed.added == 1 ? "1 new subtitle saved with the download" : "\(refreshed.added) new subtitles saved with the download")
    }

    private func begin(_ item: Item) {
        stopSession(report: true)
        discardPreload()
        session += 1
        self.item = item
        offline = nil
        stream = nil
        phase = .loading
        isPlaying = false
        isBuffering = true
        audioIndex = nil
        subtitleIndex = nil
        secondaryIndex = nil
        subtitleDelay = 0
        burnedIn = false
        maxBitrateOverride = nil
        segments = []
        serverSegments = []
        onlineFound = []
        activeSegment = nil
        nextEpisode = nil
        previousEpisode = nil
        seasonEpisodes = []
        upNextShown = false
        upNextCountdown = nil
        upNextDismissed = false
        skippedSegments = []
        triedWithoutDirectPlay = false
        primaryTrack = .empty
        secondaryTrack = .empty
        subtitles.primary = []
        subtitles.secondary = []
        clock.position = 0
        clock.duration = item.runtime
        clock.buffered = 0
        clock.scrubbing = nil
        panel = nil
        statsVisible = false
        locked = false
        holding = false
        holdLocked = false
        let settings = graph.settings.settings
        speed = settings.startSpeed
        aspect = settings.aspect
        nowPlayingArtwork = nil
        trickplay = TrickplayThumbnails(item: item, mediaSourceId: item.primarySource?.id)
        showControls()
        if !graph.ui.playerOpen {
            graph.ui.playerOpen = true
            // A fresh start; the next episode keeps the orientation chosen for this one.
            portrait = false
            orientationChosen = false
        }
        AppDelegate.lock(playerOrientation)
        graph.downloads.pauseForPlayback(settings.pauseDownloadsWhilePlaying)
        loadArtwork(item)
    }

    /** The orientation chosen in the player, else landscape or turning with the phone (Settings → Player). */
    private var playerOrientation: UIInterfaceOrientationMask {
        if orientationChosen { return portrait ? .portrait : .landscape }
        return graph.settings.settings.landscapeByDefault ? .landscape : .allButUpsideDown
    }

    /** Everything needed to start an item: its details, the stream and the tracks chosen. */
    private struct Prepared {
        var item: Item
        var stream: ResolvedStream
        var audioIndex: Int?
        var subtitleIndex: Int?
        var burnedIn: Bool
    }

    private struct PlaybackFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /** Ask the server how to play [item], and start it at [position]. */
    private func load(_ seed: Item, sourceId: String?, at position: Double, audio: Int? = nil, subtitle: Int?? = nil, keepTracks: Bool = false) async {
        let mySession = session
        var tracks: (audio: Int?, subtitle: Int?)?
        if keepTracks || audio != nil || subtitle != nil {
            tracks = (audio ?? audioIndex, subtitle ?? subtitleIndex)
        }
        do {
            let prepared = try await prepare(
                seed,
                sourceId: sourceId,
                at: position,
                tracks: tracks,
                allowDirectPlay: !triedWithoutDirectPlay,
                maxBitrate: maxBitrateOverride ?? graph.maxBitrate,
                capped: maxBitrateOverride != nil
            )
            guard mySession == session else { return }
            await apply(prepared, at: position, asset: nil)
        } catch {
            guard mySession == session else { return }
            phase = .failed((error as? PlaybackFailure)?.message ?? JellyfinError.from(error).localizedDescription)
        }
    }

    /**
     * Work out how to play [seed]: fetch its details if the page passed a thin
     * copy, choose the tracks (unless [tracks] says), and ask the server for
     * a stream. Changes nothing, so the next episode can be prepared too.
     */
    private func prepare(_ seed: Item, sourceId: String?, at position: Double, tracks: (audio: Int?, subtitle: Int?)?, allowDirectPlay: Bool, maxBitrate: Int, capped: Bool) async throws -> Prepared {
        guard let client = graph.auth.client else { throw PlaybackFailure(message: "You're not signed in.") }
        var item = seed
        // Playback needs the sources, chapters and trickplay.
        if item.mediaSources == nil || item.chapters == nil {
            if let full = try? await client.item(seed.id) { item = full }
        }
        let settings = graph.settings.settings
        let chosen = item.mediaSources?.first { $0.id == sourceId } ?? item.primarySource
        var audio: Int?
        var subtitle: Int?
        if let tracks {
            audio = tracks.audio
            subtitle = tracks.subtitle
        } else if let chosen {
            audio = StreamResolver.audioIndex(chosen, language: settings.audioLanguage.isEmpty ? graph.auth.user?.configuration?.audioLanguagePreference : settings.audioLanguage)
            let audioLanguage = chosen.streams.first { $0.index == audio }?.language
            subtitle = StreamResolver.subtitleIndex(
                chosen,
                mode: settings.subtitleMode,
                language: settings.subtitleLanguage.isEmpty ? graph.auth.user?.configuration?.subtitleLanguagePreference : settings.subtitleLanguage,
                audioLanguage: audioLanguage,
                prefer: settings.subtitleSource,
                embedded: settings.loadEmbeddedSubtitles
            )
        }
        let burnedIn = chosen?.streams.first { $0.index == subtitle }?.isImageSubtitle == true
        var allowDirect = allowDirectPlay && settings.directPlay && !burnedIn
        if capped, let bitrate = chosen?.bitrate, bitrate > maxBitrate { allowDirect = false }
        if let chosen, !StreamResolver.directPlayIsSafe(chosen) { allowDirect = false }

        func request(direct: Bool) -> PlaybackInfoRequest {
            PlaybackInfoRequest(
                userId: client.userId ?? "",
                maxStreamingBitrate: maxBitrate,
                startTimeTicks: Ticks.from(position),
                audioStreamIndex: audio,
                subtitleStreamIndex: burnedIn ? subtitle : -1,
                mediaSourceId: chosen?.id,
                deviceProfile: graph.deviceProfile(maxBitrate: maxBitrate),
                enableDirectPlay: direct,
                enableDirectStream: true,
                enableTranscoding: true,
                allowVideoStreamCopy: true,
                allowAudioStreamCopy: true,
                autoOpenLiveStream: true,
                alwaysBurnInSubtitleWhenTranscoding: false
            )
        }
        var response = try await client.playbackInfo(item.id, request(direct: allowDirect))
        if let code = response.errorCode { throw PlaybackFailure(message: Self.describe(playbackError: code)) }
        var resolved = StreamResolver.resolve(response, itemId: item.id, sourceId: chosen?.id, client: client)
        if resolved == nil, allowDirect {
            response = try await client.playbackInfo(item.id, request(direct: false))
            resolved = StreamResolver.resolve(response, itemId: item.id, sourceId: chosen?.id, client: client)
        }
        guard let resolved else {
            throw PlaybackFailure(message: "The server can't play this on an iPhone. It may need its transcoding settings checked.")
        }
        // Track choices the server made, where Kinema left them to it.
        return Prepared(item: item, stream: resolved, audioIndex: audio ?? resolved.source.defaultAudioStreamIndex, subtitleIndex: subtitle, burnedIn: burnedIn)
    }

    /** Start a prepared item at [position] (with the asset loaded ahead, when it was preloaded). */
    private func apply(_ prepared: Prepared, at position: Double, asset: AVURLAsset?) async {
        item = prepared.item
        trickplay = TrickplayThumbnails(item: prepared.item, mediaSourceId: prepared.stream.source.id)
        stream = prepared.stream
        audioIndex = prepared.audioIndex
        subtitleIndex = prepared.subtitleIndex
        burnedIn = prepared.burnedIn
        start(AVPlayerItem(asset: asset ?? AVURLAsset(url: prepared.stream.url)), at: position)
        await loadSubtitles()
        if offline == nil {
            let playing = prepared.item
            Task { await loadSegments(playing) }
            loadEpisodesAround(prepared.item)
        }
    }

    private static func describe(playbackError code: String) -> String {
        switch code {
        case "NotAllowed": return "Your account isn't allowed to play this."
        case "NoCompatibleStream": return "The server has no way to play this on an iPhone."
        case "RateLimitExceeded": return "The server is busy. Try again in a moment."
        default: return "The server couldn't start playback (\(code))."
        }
    }

    /** Put [playerItem] in the player, and play from [position] once it's ready. */
    private func start(_ playerItem: AVPlayerItem, at position: Double) {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        readyHandled = false
        // The maximum cache, as seconds of this stream to load ahead.
        let bitrate: Int? = {
            guard let stream else { return nil }
            if stream.method == .directPlay { return stream.source.bitrate }
            return min(stream.source.bitrate ?? Int.max, maxBitrateOverride ?? graph.maxBitrate)
        }()
        playerItem.preferredForwardBufferDuration = graph.settings.settings.forwardBuffer(bitrate: bitrate)
        player.replaceCurrentItem(with: playerItem)
        surface.playerLayer.opacity = position > 1 ? 0 : 1
        let mySession = session
        let status = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, mySession == self.session, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    guard !self.readyHandled else { return }
                    self.readyHandled = true
                    self.ready(item, at: position)
                case .failed:
                    self.failed(item.error)
                default:
                    break
                }
            }
        }
        itemObservations.append(status)
        let duration = playerItem.observe(\.duration, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                let seconds = item.duration.seconds
                if seconds.isFinite && seconds > 0 { self.clock.duration = seconds }
            }
        }
        itemObservations.append(duration)
    }

    private func ready(_ playerItem: AVPlayerItem, at position: Double) {
        let seconds = playerItem.duration.seconds
        if seconds.isFinite && seconds > 0 { clock.duration = seconds }
        phase = .ready
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            self.surface.playerLayer.opacity = 1
            self.applyAudioSelection()
            self.play()
            self.reportStart()
            #if DEBUG
            ScreenshotDriver.noteLoaded("player")
            #endif
        }
        if position > 1 {
            playerItem.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in begin() }
            }
        } else {
            begin()
        }
        checkVideoTrack(playerItem)
    }

    /**
     * Some files play their sound but not their picture on iOS (HEVC tagged
     * hev1 the server didn't flag). Played directly, those go through the
     * server instead.
     */
    private func checkVideoTrack(_ playerItem: AVPlayerItem) {
        guard stream?.method == .directPlay, offline == nil, let asset = playerItem.asset as? AVURLAsset else { return }
        Task {
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first else { return }
            let playable = (try? await track.load(.isPlayable)) ?? true
            if !playable { self.retryWithoutDirectPlay() }
        }
    }

    private func failed(_ error: Error?) {
        if stream?.method == .directPlay, offline == nil, !triedWithoutDirectPlay {
            retryWithoutDirectPlay()
            return
        }
        let message = (error as NSError?)?.localizedDescription ?? "Playback failed."
        phase = .failed(message)
        isBuffering = false
    }

    private func retryWithoutDirectPlay() {
        guard let item, !triedWithoutDirectPlay else { return }
        triedWithoutDirectPlay = true
        let position = max(clock.position, startPosition)
        phase = .loading
        loadTask = Task { await self.load(item, sourceId: stream?.source.id, at: position, keepTracks: true) }
    }

    /** Ask again with different choices (another audio track, a burned-in subtitle, another quality), from where it is now. */
    private func reload(audio: Int? = nil, subtitle: Int?? = nil) {
        guard let item, offline == nil else { return }
        let position = clock.position
        let wasPlaying = isPlaying || phase == .loading
        reportStopped()
        player.pause()
        phase = .loading
        isBuffering = true
        startPosition = position
        loadTask?.cancel()
        loadTask = Task {
            await self.load(item, sourceId: stream?.source.id, at: position, audio: audio, subtitle: subtitle, keepTracks: true)
            if !wasPlaying { self.pause() }
        }
    }

    func retry() {
        guard let item else { return }
        if let offline {
            openOffline(offline, startTicks: Ticks.from(clock.position))
            return
        }
        let position = max(clock.position, startPosition)
        phase = .loading
        loadTask = Task { await self.load(item, sourceId: stream?.source.id, at: position, keepTracks: true) }
    }

    // ---------------------------------------------------------- closing --

    /** Stop and close the player. */
    func close() {
        stopSession(report: true)
        discardPreload()
        graph.downloads.pauseForPlayback(false)
        // What was just watched may move a show's next episodes along.
        let downloads = graph.downloads
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await downloads.keepNextEpisodes()
        }
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        player.replaceCurrentItem(with: nil)
        item = nil
        stream = nil
        offline = nil
        phase = .idle
        graph.ui.playerOpen = false
        AppDelegate.lock(UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
        NowPlaying.clear()
        graph.library.invalidate()
    }

    /** The player's screen was swiped away: close, unless it went into Picture in Picture. */
    func dismissedByUser() {
        if item == nil || pipActive || restoringFromPiP { return }
        close()
    }

    private func stopSession(report: Bool) {
        loadTask?.cancel()
        countdownTask?.cancel()
        hideTask?.cancel()
        reportTask?.cancel()
        reportTask = nil
        if report, item != nil { reportStopped() }
        player.pause()
        session += 1
    }

    // --------------------------------------------------------- transport --

    func play() {
        guard player.currentItem != nil else { return }
        if phase == .ended {
            seek(to: 0, precise: true)
            phase = .ready
        }
        if speed > 2, player.currentItem?.canPlayFastForward == false { speed = 2 }
        player.defaultRate = Float(speed)
        player.playImmediately(atRate: Float(holding ? graph.settings.settings.holdSpeed : speed))
        scheduleHide()
    }

    func pause() {
        player.pause()
        reportProgress(event: "Pause")
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
        Haptics.tap()
    }

    func seek(to seconds: Double, precise: Bool = true) {
        let target = max(0, min(seconds, clock.duration > 0 ? clock.duration - 0.5 : seconds))
        clock.position = target
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 1.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in self?.reportProgress(event: "TimeUpdate") }
        }
        if phase == .ended { phase = .ready }
        upNextDismissed = false
        if upNextShown, target < clock.duration - 40 { hideUpNext() }
        updateSubtitles(at: target)
    }

    func skip(_ seconds: Double) {
        seek(to: clock.position + seconds, precise: false)
    }

    func setSpeed(_ value: Double) {
        var next = value
        if next > 2, player.currentItem?.canPlayFastForward == false {
            next = 2
            graph.messages.show("This stream plays at up to 2×.")
        }
        speed = next
        player.defaultRate = Float(next)
        if isPlaying, !holding { player.rate = Float(next) }
        if graph.settings.settings.rememberSpeed { graph.settings.update { $0.lastSpeed = next } }
    }

    /** Hold the screen: faster until let go. */
    func beginHold() {
        guard !holding, isPlaying else { return }
        speedBeforeHold = speed
        holding = true
        holdLocked = false
        var rate = graph.settings.settings.holdSpeed
        if rate > 2, player.currentItem?.canPlayFastForward == false { rate = 2 }
        player.rate = Float(rate)
        Haptics.tap()
    }

    /** Swipe up while holding: keep the faster speed after letting go. */
    func lockHold() {
        guard holding, !holdLocked else { return }
        holdLocked = true
        Haptics.success()
    }

    func endHold() {
        guard holding else { return }
        holding = false
        if holdLocked {
            holdLocked = false
            setSpeed(Double(player.rate))
        } else if isPlaying {
            player.rate = Float(speed)
        }
    }

    func cycleAspect() {
        aspect = aspect.next
        Haptics.select()
        graph.messages.show(aspect.label)
    }

    /**
     * Turn to the other orientation from the one on screen, and stay there
     * (also for the next episodes) until the player closes.
     */
    func toggleOrientation() {
        portrait = !portraitLayout
        orientationChosen = true
        AppDelegate.lock(playerOrientation)
        showControls()
    }

    func setQuality(_ bitrate: Int?) {
        maxBitrateOverride = bitrate
        reload()
    }

    // ---------------------------------------------------------- controls --

    func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    func toggleControls() {
        if controlsVisible { controlsVisible = false } else { showControls() }
    }

    func scheduleHide() {
        hideTask?.cancel()
        let delay = graph.settings.settings.controlsHideDelay
        guard delay > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isPlaying, self.panel == nil, self.clock.scrubbing == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.controlsVisible = false }
        }
    }

    // ------------------------------------------------------------ tracks --

    var audioStreams: [MediaStream] { source?.audioStreams ?? [] }

    /** Subtitle tracks Kinema can show: all of them streaming, only the saved ones offline. */
    var subtitleStreams: [MediaStream] {
        let all = source?.subtitleStreams ?? []
        if let offline { return all.filter { stream in offline.subtitles.contains { $0.index == stream.index } } }
        return all
    }

    func selectAudio(_ index: Int) {
        guard index != audioIndex else { return }
        if let offline {
            if offline.kind == .hls {
                // A copy made by the server holds one language.
                if index == downloadedAudioIndex { audioIndex = index } else { playAudioFromServer(index) }
                return
            }
            let previous = audioIndex
            audioIndex = index
            if !applyAudioSelection() {
                audioIndex = previous
                playAudioFromServer(index)
            }
            return
        }
        audioIndex = index
        if stream?.method == .directPlay, applyAudioSelection() { return }
        reload(audio: index)
    }

    /**
     * Switch the language inside the file, when it is played as it is: by
     * the file's own list of languages where it has one (by language, else
     * the nth audio track the server lists is the nth option), else by
     * turning its audio tracks on and off (files that don't group them).
     */
    @discardableResult
    private func applyAudioSelection() -> Bool {
        guard let audioIndex, let playerItem = player.currentItem,
              stream?.method == .directPlay || offline != nil
        else { return false }
        let streams = audioStreams.sorted { $0.index < $1.index }
        guard let position = streams.firstIndex(where: { $0.index == audioIndex }) else { return false }
        let chosen = streams[position]
        if let group = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible), group.options.count > 1 {
            let options = group.options
            let sameLanguage = options.filter { Languages.same($0.extendedLanguageTag ?? $0.locale?.identifier, chosen.language) }
            let streamsInLanguage = streams.filter { Languages.same($0.language, chosen.language) }
            var option: AVMediaSelectionOption?
            if sameLanguage.count == 1 && streamsInLanguage.count == 1 {
                option = sameLanguage[0]
            } else if options.count == streams.count {
                option = options[position]
            } else if !sameLanguage.isEmpty, let nth = streamsInLanguage.firstIndex(where: { $0.index == audioIndex }) {
                option = sameLanguage[min(nth, sameLanguage.count - 1)]
            }
            if let option {
                playerItem.select(option, in: group)
                return true
            }
        }
        let tracks = playerItem.tracks.filter { $0.assetTrack?.mediaType == .audio }
        guard tracks.count > 1, tracks.count == streams.count else { return false }
        for (i, track) in tracks.enumerated() { track.isEnabled = i == position }
        return true
    }

    /**
     * The one audio track of a download the server made (HLS): as kept when
     * it was downloaded, or for older downloads, by the copy's language.
     */
    var downloadedAudioIndex: Int? {
        guard let offline, offline.kind == .hls else { return nil }
        if let index = offline.audioIndex { return index }
        if let option = player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .audible)?.options.first,
           let tag = option.extendedLanguageTag ?? option.locale?.identifier,
           let match = audioStreams.first(where: { Languages.same($0.language, tag) }) {
            return match.index
        }
        // Chosen the way downloads chose it before the language was kept.
        return source.flatMap { StreamResolver.audioIndex($0, language: graph.settings.settings.audioLanguage) }
    }

    /**
     * The server's fresh list of tracks for what's playing. It numbers them
     * again when a subtitle is added, so the chosen tracks are carried over.
     */
    private func adopt(_ updated: MediaSource) {
        guard var current = stream else { return }
        let map = StreamRemap.indexMap(from: current.source.streams, to: updated.streams)
        if let index = audioIndex { audioIndex = map[index] ?? index }
        if let index = subtitleIndex { subtitleIndex = map[index] ?? index }
        if let index = secondaryIndex { secondaryIndex = map[index] ?? index }
        current.source = updated
        stream = current
    }

    /** A language the download doesn't have: from the server instead, from here on, when there's a connection. */
    private func playAudioFromServer(_ index: Int) {
        let name = audioStreams.first { $0.index == index }?.label ?? "That language"
        guard let item, graph.network.online, graph.auth.client != nil else {
            graph.messages.show("\(name) isn't in this download. Play it with a connection, or download it again in \(name).")
            return
        }
        let position = clock.position
        let sourceId = offline?.mediaSourceId
        let subtitle = subtitleIndex
        graph.messages.show("\(name) isn't in the download, so it plays from your server")
        begin(item)
        startPosition = position
        loadTask = Task { await self.load(item, sourceId: sourceId, at: position, audio: index, subtitle: .some(subtitle)) }
    }

    func selectSubtitle(_ index: Int?) {
        let wanted = subtitleStreams.first { $0.index == index }
        let needsBurnIn = wanted?.isImageSubtitle == true
        if needsBurnIn || burnedIn {
            // Pictures are drawn into the video by the server; changing to or from one needs a new stream.
            subtitleIndex = index
            primaryTrack = .empty
            subtitles.primary = []
            if offline != nil && needsBurnIn {
                graph.messages.show("Picture subtitles can't be shown in a download.")
                return
            }
            reload(subtitle: .some(index))
            return
        }
        subtitleIndex = index
        Task { await loadSubtitles() }
    }

    func selectSecondary(_ index: Int?) {
        secondaryIndex = index
        Task { await loadSubtitles() }
    }

    private func loadSubtitles() async {
        primaryTrack = await track(for: burnedIn ? nil : subtitleIndex)
        secondaryTrack = await track(for: secondaryIndex == subtitleIndex ? nil : secondaryIndex)
        updateSubtitles(at: clock.position)
    }

    private func track(for index: Int?) async -> SubtitleTrack {
        guard let index, let item else { return .empty }
        if let offline, let saved = offline.subtitles.first(where: { $0.index == index }) {
            guard let url = graph.downloads.subtitleURL(offline, saved), let data = try? Data(contentsOf: url) else { return .empty }
            return SubtitleTrack.parse(data)
        }
        guard let client = graph.auth.client, let source = stream?.source ?? item.primarySource,
              let url = client.subtitleURL(itemId: item.id, mediaSourceId: source.id, index: index)
        else { return .empty }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return SubtitleTrack.parse(data)
        } catch {
            graph.messages.error("Couldn't load the subtitles.")
            return .empty
        }
    }

    private func updateSubtitles(at time: Double) {
        let t = time - subtitleDelay
        let primary = primaryTrack.cues(at: t)
        if primary != subtitles.primary { subtitles.primary = primary }
        let secondary = secondaryTrack.cues(at: t)
        if secondary != subtitles.secondary { subtitles.secondary = secondary }
    }

    /** The server found a subtitle online; show it once the server has it (and keep it with the download, if there is one). */
    func remoteSubtitleDownloaded() async {
        guard let client = graph.auth.client, let item, let full = try? await client.item(item.id) else { return }
        let oldStreams = source?.streams ?? []
        // Playing the download, it's what was asked for, whatever the setting.
        if let refreshed = await graph.downloads.refreshSubtitles(item.id, force: offline?.id == item.id), offline?.id == item.id {
            offline = refreshed.record
        }
        guard self.item?.id == full.id else { return }
        self.item = full
        if let updated = full.mediaSources?.first(where: { $0.id == stream?.source.id }) { adopt(updated) }
        // The server numbered the tracks again: the new one is the one that maps to nothing before.
        let map = StreamRemap.indexMap(from: oldStreams, to: source?.streams ?? [])
        let known = Set(map.values)
        if let added = subtitleStreams.first(where: { !known.contains($0.index) && !$0.isImageSubtitle }) {
            selectSubtitle(added.index)
            graph.messages.show("Showing \(added.label)", .success)
        }
    }

    // ---------------------------------------------------- segments, chapters --

    /**
     * Intros, recaps and credits for [playing]: the server's own; where it
     * has none, the ones marked by hand; and where there are none of those
     * either, the online databases' (when Find intros and credits online is on).
     */
    private func loadSegments(_ playing: Item) async {
        let id = playing.id
        if offline == nil, let client = graph.auth.client {
            let found = await client.mediaSegments(id)
            guard item?.id == id else { return }
            serverSegments = found
        }
        rebuildSegments()
        await loadOnlineSegments(playing)
    }

    private func loadOnlineSegments(_ playing: Item) async {
        let have = Set(serverSegments.map(\.type))
        guard graph.settings.settings.onlineSegments, !(have.contains("Intro") && have.contains("Outro")) else { return }
        let found = await graph.onlineSegments.find(playing)
        guard item?.id == playing.id else { return }
        onlineFound = found
        rebuildSegments()
    }

    private func rebuildSegments() {
        let duration = clock.duration > 0 ? clock.duration : (item?.runtime ?? 0)
        let marked = item?.seriesId.flatMap { graph.markers.markers($0) }?.segments(duration: duration) ?? []
        let online = graph.settings.settings.onlineSegments ? IntroDatabase.segments(onlineFound, duration: duration) : []
        segments = IntroDatabase.merge(server: serverSegments, marked: marked, online: online)
    }

    /** Where this item's intros and credits come from, for the player's menu. */
    var segmentSources: String? {
        var sources: [String] = []
        if !serverSegments.isEmpty { sources.append("your server") }
        if segments.contains(where: { $0.id.hasPrefix("marker-") }) { sources.append("your marks") }
        let online = Set(onlineFound.map(\.source))
        if graph.settings.settings.onlineSegments, segments.contains(where: { $0.id.hasPrefix("online-") }) { sources += online.sorted() }
        return sources.isEmpty ? nil : sources.joined(separator: ", ")
    }

    /** Settings → Playback → Find intros and credits online, from the player. */
    func setOnlineSegments(_ on: Bool) {
        graph.settings.update { $0.onlineSegments = on }
        rebuildSegments()
        if on, let item { Task { await loadOnlineSegments(item) } }
    }

    /** Skip intros (or credits) by themselves, or show a button: also in Settings → Playback → Skipping. */
    func setAutoSkip(intro on: Bool) {
        graph.settings.update { $0.skipIntro = on ? .automatic : .button }
    }

    func setAutoSkip(credits on: Bool) {
        graph.settings.update { $0.skipCredits = on ? .automatic : .button }
    }

    /** Mark where this series' intro ends (or its credits start), here and now. */
    func markIntroEnd() {
        guard let seriesId = item?.seriesId else { return }
        graph.markers.update(seriesId) { $0.introEnd = clock.position }
        rebuildSegments()
        graph.messages.show("Intro ends at \(Format.clock(clock.position)) in every episode", .success)
    }

    func markCreditsStart() {
        guard let seriesId = item?.seriesId, clock.duration > 0 else { return }
        graph.markers.update(seriesId) { $0.creditsFromEnd = clock.duration - clock.position }
        rebuildSegments()
        graph.messages.show("Credits start \(Format.clock(clock.duration - clock.position)) before the end of every episode", .success)
    }

    func clearMarkers() {
        guard let seriesId = item?.seriesId else { return }
        graph.markers.clear(seriesId)
        rebuildSegments()
        graph.messages.show("Marks cleared")
    }

    var hasMarkers: Bool { item?.seriesId.flatMap { graph.markers.markers($0) } != nil }

    private func updateSegment(at time: Double) {
        let settings = graph.settings.settings
        let current = segments.first { time >= $0.start && time < $0.end - 0.5 }
        if current != activeSegment { activeSegment = current }
        guard let current, !skippedSegments.contains(current.id) else { return }
        let mode: SkipMode
        switch current.type {
        case "Intro": mode = settings.skipIntro
        case "Outro": mode = settings.skipCredits
        case "Recap", "Preview": mode = settings.skipRecap
        default: mode = .button
        }
        if mode == .automatic {
            skippedSegments.insert(current.id)
            if current.type == "Outro", nextEpisode != nil, current.end >= clock.duration - 5 {
                showUpNext()
            } else {
                seek(to: current.end, precise: false)
                graph.messages.show("Skipped \(current.type == "Outro" ? "credits" : current.type.lowercased())")
            }
        }
    }

    /** Whether the skip button should show for the segment now. */
    var skipButtonShown: Bool {
        guard let segment = activeSegment, !skippedSegments.contains(segment.id), graph.settings.settings.showSkipButtons else { return false }
        switch segment.type {
        case "Intro": return graph.settings.settings.skipIntro == .button
        case "Outro": return graph.settings.settings.skipCredits == .button && !upNextShown
        case "Recap", "Preview": return graph.settings.settings.skipRecap == .button
        default: return true
        }
    }

    func skipSegment() {
        guard let segment = activeSegment else { return }
        skippedSegments.insert(segment.id)
        if segment.type == "Outro", nextEpisode != nil, segment.end >= clock.duration - 5 {
            playNext()
            return
        }
        seek(to: segment.end, precise: true)
        Haptics.tap()
    }

    func previousChapter() {
        let list = chapters
        let now = clock.position
        if let previous = list.last(where: { $0.start < now - 3 }) { seek(to: previous.start) } else { seek(to: 0) }
    }

    func nextChapter() {
        if let next = chapters.first(where: { $0.start > clock.position + 1 }) { seek(to: next.start) }
    }

    var currentChapterIndex: Int? {
        chapters.lastIndex { $0.start <= clock.position + 0.5 }
    }

    // ----------------------------------------------------------- up next --

    private func loadEpisodesAround(_ item: Item) {
        guard item.kind == .episode, let seriesId = item.seriesId else { return }
        let mySession = session
        Task {
            if offline != nil {
                // Offline, the next episode is the next one downloaded.
                let downloaded = graph.downloads.records.filter { $0.isDone && $0.item.seriesId == seriesId }.map(\.item)
                    .sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) }
                if let index = downloaded.firstIndex(where: { $0.id == item.id }) {
                    nextEpisode = index + 1 < downloaded.count ? downloaded[index + 1] : nil
                    previousEpisode = index > 0 ? downloaded[index - 1] : nil
                }
                seasonEpisodes = downloaded
                return
            }
            guard let client = graph.auth.client else { return }
            let all = (try? await client.episodes(seriesId: seriesId)) ?? []
            guard mySession == session else { return }
            let playable = all.filter { $0.locationType != "Virtual" }
            if let index = playable.firstIndex(where: { $0.id == item.id }) {
                nextEpisode = index + 1 < playable.count ? playable[index + 1] : nil
                previousEpisode = index > 0 ? playable[index - 1] : nil
            }
            seasonEpisodes = playable.filter { $0.seasonId == item.seasonId }
            if seasonEpisodes.isEmpty { seasonEpisodes = playable }
        }
    }

    private func updateUpNext(at time: Double) {
        guard nextEpisode != nil, !upNextDismissed, !upNextShown, graph.settings.settings.autoplayNext, clock.duration > 60 else { return }
        let countdown = Double(graph.settings.settings.upNextCountdown)
        let creditsStart = segments.first { $0.type == "Outro" && $0.end >= clock.duration - 5 }?.start
        let trigger = creditsStart ?? (clock.duration - max(countdown + 5, 25))
        if time >= trigger { showUpNext() }
    }

    private func showUpNext() {
        guard nextEpisode != nil, !upNextShown else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { upNextShown = true }
        guard graph.settings.settings.autoplayNext else { return }
        let total = graph.settings.settings.upNextCountdown
        upNextCountdown = total
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            var left = total
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isPlaying || self.phase == .ended {
                    left -= 1
                    self.upNextCountdown = left
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.playNext()
        }
    }

    func hideUpNext() {
        countdownTask?.cancel()
        upNextDismissed = true
        upNextCountdown = nil
        withAnimation(.easeOut(duration: 0.25)) { upNextShown = false }
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        countdownTask?.cancel()
        let library = graph.library
        if let record = graph.downloads.record(next.id), record.isDone {
            openOffline(record)
            return
        }
        // Prepared ahead: start straight away, with the asset already loading.
        if let ready = preloaded, ready.id == next.id {
            preloaded = nil
            begin(ready.prepared.item)
            startPosition = Ticks.seconds(library.resumeTicks(next))
            let position = startPosition
            loadTask = Task { await self.apply(ready.prepared, at: position, asset: ready.asset) }
            return
        }
        open(library.current(next), startTicks: library.resumeTicks(next), mediaSourceId: nil)
    }

    // ---------------------------------------------------------- preloading --

    /**
     * Near the end of an episode (the last fifth, or three minutes), prepare
     * the next one: ask the server for its stream, load the asset, and for a
     * stream the server makes, ask for its first pieces so it starts making
     * them. Then Up Next starts it at once.
     */
    private func maybePreload(at time: Double) {
        guard graph.settings.settings.preloadNextEpisode, offline == nil, preloaded == nil, preloadTask == nil,
              let next = nextEpisode, clock.duration > 60, graph.downloads.record(next.id)?.isDone != true
        else { return }
        guard time >= max(clock.duration * 0.8, clock.duration - 180) else { return }
        let mySession = session
        let library = graph.library
        let start = Ticks.seconds(library.resumeTicks(next))
        let seed = library.current(next)
        graph.onlineSegments.prefetch(seed)
        preloadTask = Task {
            defer { if mySession == self.session { self.preloadTask = nil } }
            guard let prepared = try? await self.prepare(seed, sourceId: nil, at: start, tracks: nil, allowDirectPlay: true, maxBitrate: self.graph.maxBitrate, capped: false),
                  mySession == self.session
            else { return }
            let asset = AVURLAsset(url: prepared.stream.url)
            _ = try? await asset.load(.isPlayable, .duration)
            if prepared.stream.isHLS { await Self.warm(prepared.stream.url) }
            guard mySession == self.session else { return }
            self.preloaded = (next.id, prepared, asset)
        }
    }

    private func discardPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preloaded = nil
    }

    /** Ask for an HLS stream's first pieces, so the server starts converting it before it's needed. */
    private static func warm(_ master: URL) async {
        func lines(_ url: URL) async -> [String] {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
            return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        }
        let masterLines = await lines(master)
        guard let variantLine = masterLines.first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let variant = URL(string: variantLine, relativeTo: master)?.absoluteURL
        else { return }
        let variantLines = await lines(variant)
        var wanted: [URL] = []
        if let map = variantLines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
           let range = map.range(of: "URI=\""),
           let end = map[range.upperBound...].firstIndex(of: "\""),
           let url = URL(string: String(map[range.upperBound..<end]), relativeTo: variant)?.absoluteURL {
            wanted.append(url)
        }
        if let first = variantLines.first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let url = URL(string: first, relativeTo: variant)?.absoluteURL {
            wanted.append(url)
        }
        for url in wanted { _ = try? await URLSession.shared.data(from: url) }
    }

    func playPrevious() {
        guard let previous = previousEpisode else { return }
        open(graph.library.current(previous), startTicks: graph.library.resumeTicks(previous), mediaSourceId: nil)
    }

    func playEpisode(_ episode: Item) {
        if let record = graph.downloads.record(episode.id), record.isDone {
            openOffline(record)
        } else {
            open(graph.library.current(episode), startTicks: graph.library.resumeTicks(episode), mediaSourceId: nil)
        }
    }

    private func ended() {
        phase = .ended
        isPlaying = false
        reportStopped()
        if nextEpisode != nil, graph.settings.settings.autoplayNext {
            if !upNextShown { showUpNext() }
        } else {
            showControls()
        }
    }

    // --------------------------------------------------------- reporting --

    private func report(position: Double? = nil, paused: Bool? = nil, event: String? = nil) -> PlaybackReport? {
        guard let item else { return nil }
        return PlaybackReport(
            itemId: item.id,
            mediaSourceId: stream?.source.id,
            playSessionId: stream?.playSessionId,
            positionTicks: Ticks.from(position ?? clock.position),
            isPaused: paused ?? !isPlaying,
            playMethod: stream?.method,
            audioStreamIndex: audioIndex,
            subtitleStreamIndex: subtitleIndex,
            eventName: event
        )
    }

    private func reportStart() {
        guard offline == nil, let client = graph.auth.client, let report = report(paused: false) else { return }
        Task { await client.reportStart(report) }
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isPlaying { self.reportProgress(event: "TimeUpdate") }
            }
        }
    }

    private func reportProgress(event: String) {
        guard let item else { return }
        let ticks = Ticks.from(clock.position)
        lastReportedTicks = ticks
        notePosition(item, ticks: ticks)
        guard offline == nil, let client = graph.auth.client, let report = report(event: event) else { return }
        Task { await client.reportProgress(report) }
    }

    private func reportStopped() {
        guard let item else { return }
        let position = phase == .ended ? clock.duration : clock.position
        let ticks = Ticks.from(position)
        notePosition(item, ticks: ticks)
        if offline != nil {
            graph.downloads.noteWatched(item.id, ticks: ticks, duration: clock.duration)
            return
        }
        guard let client = graph.auth.client, var report = report(position: position, paused: true) else { return }
        report.failed = nil
        Task { await client.reportStopped(report) }
    }

    /** What the pages should show for [item] until they reload. */
    private func notePosition(_ item: Item, ticks: Int64) {
        guard clock.duration > 0 else { return }
        let fraction = Ticks.seconds(ticks) / clock.duration
        // Like the server: under 5% is "not started", over 90% is "watched".
        if fraction > 0.9 {
            graph.library.notePosition(item.id, ticks: 0, played: true)
        } else if fraction > 0.05 {
            graph.library.notePosition(item.id, ticks: ticks, played: false)
        }
    }

    // ------------------------------------------------------- observation --

    private func observePlayer() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.clock.scrubbing == nil else { return }
                self.updateSubtitles(at: time.seconds)
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                let playing = player.timeControlStatus != .paused
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    if !playing { self.controlsVisible = self.controlsVisible || self.phase == .ended }
                    NowPlaying.update(self, artwork: self.nowPlayingArtwork)
                }
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as AnyObject?) === self.player.currentItem else { return }
                self.ended()
            }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as AnyObject?) === self.player.currentItem else { return }
                self.failed(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            }
        })
    }

    private func tick(_ seconds: Double) {
        guard item != nil, seconds.isFinite, clock.scrubbing == nil else { return }
        if abs(clock.position - seconds) > 0.05 { clock.position = seconds }
        if let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
            clock.buffered = range.end.seconds
        }
        updateSegment(at: seconds)
        updateUpNext(at: seconds)
        maybePreload(at: seconds)
        ticks += 1
        if ticks % 20 == 0 { NowPlaying.update(self, artwork: nowPlayingArtwork) }
    }

    private func observeApp() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self.reportProgress(event: "Pause")
            }
        })
    }

    private func enteredBackground() {
        guard item != nil else { return }
        if pipActive { return }
        if graph.settings.settings.backgroundAudio && isPlaying {
            // Keep the sound going with the picture detached.
            surface.playerLayer.player = nil
            detachedForBackground = true
        } else if !(pip?.isPictureInPictureActive ?? false) && !graph.settings.settings.autoPiP {
            pause()
        }
        reportProgress(event: "TimeUpdate")
    }

    private func enteringForeground() {
        if detachedForBackground {
            surface.playerLayer.player = player
            detachedForBackground = false
        }
    }

    // ------------------------------------------------------------- PiP --

    private func setUpPictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: surface.playerLayer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = graph.settings.settings.autoPiP
        pip = controller
        if let controller {
            observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                Task { @MainActor in self?.pipPossible = controller.isPictureInPicturePossible }
            })
        }
        graph.settings.observe { [weak self] old, new in
            guard old.autoPiP != new.autoPiP else { return }
            self?.pip?.canStartPictureInPictureAutomaticallyFromInline = new.autoPiP
        }
    }

    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // ------------------------------------------------------- screenshot --

    /** The frame on screen now, as a picture. */
    private func currentFrame(maxWidth: Int? = nil) -> CGImage? {
        guard let playerItem = player.currentItem else { return nil }
        if videoOutput == nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            playerItem.add(output)
            videoOutput = output
        }
        guard let output = videoOutput,
              let buffer = output.copyPixelBuffer(forItemTime: playerItem.currentTime(), itemTimeForDisplay: nil)
        else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if let maxWidth, image.extent.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return Self.ciContext.createCGImage(image, from: image.extent)
    }

    private static let ciContext = CIContext()

    /** Save the frame on screen to Photos, in the format chosen in Settings. */
    func screenshot() {
        Task {
            // A freshly added output needs a moment before it hands out frames.
            for _ in 0..<15 {
                if let frame = currentFrame() {
                    let format = graph.settings.settings.screenshotFormat
                    guard let data = PhotoSaver.encode(frame, format: format) else { break }
                    if await PhotoSaver.save(data, type: format.type) {
                        Haptics.success()
                        graph.messages.show("Saved to Photos", .success)
                    } else {
                        graph.messages.error("Kinema isn't allowed to add to Photos. Allow it in Settings → Kinema → Photos.")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            graph.messages.error("Couldn't capture this frame.")
        }
    }

    /** Start recording a GIF of what's playing, or stop and save it. Stops by itself after ten seconds. */
    func toggleGIF() {
        if recordingGIF {
            recordingGIF = false
            return
        }
        let settings = graph.settings.settings
        let fps = max(5, min(30, settings.gifFrameRate))
        let width = settings.gifWidth
        recordingGIF = true
        Haptics.tap()
        gifTask = Task {
            var frames: [CGImage] = []
            let limit = fps * 10
            while recordingGIF && frames.count < limit && !Task.isCancelled {
                if isPlaying, let frame = currentFrame(maxWidth: width) { frames.append(frame) }
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / fps))
            }
            recordingGIF = false
            guard frames.count > 2, let data = PhotoSaver.gif(frames, fps: fps) else {
                graph.messages.show("Too short to save: let it play while recording.")
                return
            }
            if await PhotoSaver.save(data, type: .gif) {
                Haptics.success()
                graph.messages.show("GIF saved to Photos", .success)
            } else {
                graph.messages.error("Kinema isn't allowed to add to Photos. Allow it in Settings → Kinema → Photos.")
            }
        }
    }

    // --------------------------------------------------------- artwork --

    private func loadArtwork(_ item: Item) {
        guard let ref = item.landscapeImage ?? item.posterImage, let url = graph.imageURL(ref, width: 540) else { return }
        Task {
            if let image = await ImageLoader.shared.image(url, pixelSize: 600), self.item?.id == item.id {
                nowPlayingArtwork = image
                NowPlaying.update(self, artwork: image)
            }
        }
    }

    // ------------------------------------------------------------ stats --

    /** The numbers for the stats panel. */
    var stats: [(String, String)] {
        var rows: [(String, String)] = []
        guard let item else { return rows }
        if let stream {
            rows.append(("Play method", offline != nil ? "Downloaded" : stream.methodLabel))
            if !stream.transcodeReasons.isEmpty {
                rows.append(("Why", stream.transcodeReasons.map(StreamResolver.describe(reason:)).joined(separator: ", ")))
            }
            let source = stream.source
            rows.append(("Container", (source.container ?? "–").uppercased()))
            if let video = source.videoStream {
                rows.append(("Video", [Format.resolution(width: video.width, height: video.height), video.codec?.uppercased(), video.profile, Format.dynamicRange(video.videoRangeType) ?? "SDR", video.averageFrameRate.map { String(format: "%.3g fps", $0) }].compactMap { $0 }.joined(separator: " · ")))
            }
            if let audio = source.streams.first(where: { $0.index == audioIndex }) ?? source.audioStreams.first {
                rows.append(("Audio", [audio.label, audio.detail].filter { !$0.isEmpty }.joined(separator: " · ")))
            }
            if let subtitle = source.streams.first(where: { $0.index == subtitleIndex }) {
                rows.append(("Subtitles", subtitle.label + (burnedIn ? " (burned in)" : "")))
            }
            if let bitrate = source.bitrate { rows.append(("File bitrate", Format.bitrate(Double(bitrate)))) }
        }
        if let event = player.currentItem?.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { rows.append(("Stream bitrate", Format.bitrate(event.indicatedBitrate))) }
            if event.observedBitrate > 0 { rows.append(("Connection", Format.bitrate(event.observedBitrate))) }
            if event.numberOfDroppedVideoFrames > 0 { rows.append(("Dropped frames", String(event.numberOfDroppedVideoFrames))) }
            if event.numberOfStalls > 0 { rows.append(("Stalls", String(event.numberOfStalls))) }
        }
        let presentation = player.currentItem?.presentationSize ?? .zero
        if presentation.width > 0 { rows.append(("Picture", "\(Int(presentation.width)) × \(Int(presentation.height))")) }
        rows.append(("Buffered", "\(Int(max(0, clock.buffered - clock.position)))s ahead"))
        rows.append(("Speed", String(format: "%.2g×", Double(player.rate == 0 ? Float(speed) : player.rate))))
        rows.append(("Item", item.id))
        return rows
    }
}

extension PlayerModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipActive = true
            // The rest of the app is usable while the video floats.
            self.graph.ui.playerOpen = false
            AppDelegate.lock(UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipActive = false
            if self.restoringFromPiP {
                self.restoringFromPiP = false
            } else if !self.graph.ui.playerOpen {
                // Closed from the floating window: playback is over.
                self.close()
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.restoringFromPiP = true
            self.graph.ui.playerOpen = true
            AppDelegate.lock(self.playerOrientation)
            try? await Task.sleep(nanoseconds: 450_000_000)
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.pipActive = false
            self.graph.messages.error("Picture in Picture didn't start.")
        }
    }
}
