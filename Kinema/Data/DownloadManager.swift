import AVFoundation
import Foundation
import Observation
import UIKit

/** How much of a film, show or season is downloaded (Home's and the Library's badges). */
enum DownloadCoverage {
    case none, partial, full
}

/**
 * Downloads for watching offline. A file that iOS plays as it is (MP4 or
 * MOV with H.264/HEVC) is downloaded untouched; anything else is fetched as
 * HLS from the server (repackaged, or converted at the chosen quality) and
 * kept as an AVFoundation movie package. Both keep going in the background.
 *
 * Each download keeps the item's details, its poster and its text
 * subtitles, so it can be listed and played with no connection. Watching
 * offline is remembered and sent to the server the next time it's reachable.
 */
@MainActor
@Observable
final class DownloadManager: NSObject {
    @ObservationIgnored private unowned let graph: AppGraph

    /** The downloads of the account in use. */
    private(set) var records: [DownloadRecord] = []
    @ObservationIgnored private var all: [DownloadRecord] = []
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var hlsSession: AVAssetDownloadURLSession!
    /** Which download each task is for. */
    /** The downloads with a background task, running or held. */
    @ObservationIgnored private var liveTasks: Set<String> = []
    @ObservationIgnored private var started = false

    private static let indexName = "downloads.json"

    init(graph: AppGraph) {
        self.graph = graph
        super.init()
    }

    /** The folder downloads live in (kept out of iCloud backups). */
    nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    func start() {
        guard !started else { return }
        started = true
        let fileConfig = URLSessionConfiguration.background(withIdentifier: "app.kinema.ios.downloads")
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileConfig.allowsCellularAccess = true
        fileSession = URLSession(configuration: fileConfig, delegate: self, delegateQueue: .main)
        let hlsConfig = URLSessionConfiguration.background(withIdentifier: "app.kinema.ios.downloads.hls")
        hlsConfig.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig, assetDownloadDelegate: self, delegateQueue: .main)
        loadIndex()
        reload()
        reattach()
        graph.network.observe { [weak self] in self?.connectionChanged() }
    }

    // ------------------------------------------------------------ the index --

    private var indexURL: URL { Self.folder.appendingPathComponent(Self.indexName) }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = (try? decoder.decode([DownloadRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) { try? data.write(to: indexURL, options: .atomic) }
    }

    /** Show the downloads of the account now in use. */
    func reload() {
        let profile = graph.auth.activeId
        records = all.filter { $0.profileId == profile }.sorted { $0.createdAt > $1.createdAt }
    }

    #if DEBUG
    /** For CI's screenshots only: show [items] as downloaded (or in [state]), in memory (no files, nothing saved). */
    func pretendDownloaded(_ items: [Item], state: DownloadState = .done, progress: Double = 1) {
        guard let profile = graph.auth.activeId else { return }
        for item in items where !records.contains(where: { $0.id == item.id }) {
            var record = DownloadRecord(id: item.id, profileId: profile, item: item, mediaSourceId: nil, kind: .original, quality: .original)
            record.state = state
            record.progress = progress
            record.bytes = state == .done ? 0 : Int64(progress * 900_000_000)
            records.append(record)
        }
    }
    #endif

    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = all.firstIndex(where: { $0.id == id && $0.profileId == graph.auth.activeId }) ?? all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        save()
        reload()
    }

    func record(_ id: String) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    var usedBytes: Int64 {
        all.filter(\.isDone).reduce(0) { $0 + $1.bytes }
    }

    var active: [DownloadRecord] { records.filter { !$0.isDone } }

    /**
     * How much of [item] is on this phone. A film or an episode is whole or
     * not; a show or a season is whole when every episode not watched yet is
     * downloaded, and partly when only some of its episodes are.
     */
    func coverage(of item: Item) -> DownloadCoverage {
        switch item.kind {
        case .series, .season:
            let episodes = records.filter { record in
                record.isDone && (item.kind == .series ? record.item.seriesId == item.id : record.item.seasonId == item.id)
            }
            guard !episodes.isEmpty else { return .none }
            let unwatched = item.unplayedCount ?? 0
            let downloadedUnwatched = episodes.filter { !graph.library.isPlayed($0.item) }.count
            return unwatched > 0 && downloadedUnwatched >= unwatched ? .full : .partial
        default:
            return record(item.id)?.isDone == true ? .full : .none
        }
    }

    // -------------------------------------------------------------- files --

    func fileURL(for record: DownloadRecord) -> URL? {
        guard let file = record.file else { return nil }
        let url: URL
        if record.kind == .hls {
            // Movie packages are kept where AVFoundation put them, relative to the app's home.
            url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(file)
        } else {
            url = Self.folder.appendingPathComponent(file)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func subtitleURL(_ record: DownloadRecord, _ subtitle: DownloadedSubtitle) -> URL? {
        let url = Self.folder.appendingPathComponent(subtitle.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func imageURL(_ file: String?) -> URL? {
        guard let file else { return nil }
        let url = Self.folder.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // ---------------------------------------------------------- downloading --

    /** Download [items] at [quality], in [audioLanguage] where the server makes a copy ("": the usual one). */
    func download(_ items: [Item], quality: DownloadQuality, audioLanguage: String = "") {
        if graph.network.metered && !graph.settings.settings.downloadOnCellular {
            graph.messages.show("Downloads wait for Wi-Fi (change this in Settings → Downloads).")
        }
        let added = enqueue(items, quality: quality, automatic: false, audioLanguage: audioLanguage)
        if added > 0 {
            graph.messages.show(added == 1 ? "Downloading “\(items.first?.name ?? "")”" : "Downloading \(added) episodes", .success)
        } else {
            graph.messages.show("Already downloaded.")
        }
        // A show downloaded from now has its next episodes kept, too.
        Task { await keepNextEpisodes() }
    }

    /** Queue the ones of [items] not downloaded yet; how many were. */
    @discardableResult
    private func enqueue(_ items: [Item], quality: DownloadQuality, automatic: Bool, audioLanguage: String) -> Int {
        guard let profile = graph.auth.activeId else { return 0 }
        var added = 0
        for item in items where item.isPlayable {
            if all.contains(where: { $0.id == item.id && $0.profileId == profile }) { continue }
            var record = DownloadRecord(id: item.id, profileId: profile, item: item, mediaSourceId: item.primarySource?.id, kind: .original, quality: quality)
            record.state = .queued
            record.automatic = automatic ? true : nil
            record.audioLanguage = audioLanguage.isEmpty ? nil : audioLanguage
            all.append(record)
            added += 1
            // Its intro and credits, kept for watching offline.
            graph.onlineSegments.prefetch(item)
        }
        if added > 0 {
            save()
            reload()
            pump()
        }
        return added
    }

    // ------------------------------------------------- the next episodes --

    @ObservationIgnored private var keeping = false

    /**
     * Settings → Downloads → Keep the next episodes: for every show with an
     * episode downloaded, have the next ones (after the last watched)
     * downloaded too, at the usual quality, and let go of the ones
     * downloaded that way once they're watched. Runs when Kinema comes to
     * the front, after watching, and when a download is added.
     */
    func keepNextEpisodes() async {
        let settings = graph.settings.settings
        guard settings.keepNextEpisodes > 0, !keeping, graph.network.online, graph.auth.canDownload,
              let client = graph.auth.client else { return }
        keeping = true
        defer { keeping = false }
        let shows = Set(records.compactMap { $0.item.kind == .episode ? $0.item.seriesId : nil })
        var wanted: [Item] = []
        for seriesId in shows.sorted() {
            guard let episodes = try? await client.episodes(seriesId: seriesId) else { continue }
            // Watched here and not told to the server yet counts as watched.
            let isPlayed: (Item) -> Bool = { episode in
                self.graph.library.isPlayed(episode) || self.record(episode.id)?.localPlayed == true
            }
            let next = NextEpisodes.toKeep(episodes, count: settings.keepNextEpisodes, isPlayed: isPlayed)
            wanted += next.filter { record($0.id) == nil }
            if settings.removeWatchedDownloads {
                let watched = Set(episodes.filter(isPlayed).map(\.id))
                for record in records where record.automatic == true && watched.contains(record.id) && graph.player.item?.id != record.id {
                    remove(record.id)
                }
            }
        }
        enqueue(wanted, quality: settings.downloadQuality, automatic: true, audioLanguage: settings.downloadAudioLanguage)
    }

    /** Start queued downloads, as many at once as Settings → Downloads allows. */
    private func pump() {
        let limit = max(1, min(5, graph.settings.settings.concurrentDownloads))
        let running = all.filter { $0.state == .downloading }.count
        guard running < limit, !pausedForPlayback, connectionAllows else { return }
        let queued = all.filter { $0.state == .queued && $0.profileId == graph.auth.activeId }.prefix(limit - running)
        for record in queued {
            update(record.id) { $0.state = .downloading; $0.error = nil }
            Task { await begin(record.id) }
        }
    }

    private func begin(_ id: String) async {
        guard let client = graph.auth.client, let record = all.first(where: { $0.id == id }) else { return }
        do {
            // Fresh details: the file's tracks, chapters and the user's progress.
            let item = (try? await client.item(id)) ?? record.item
            let source = item.mediaSources?.first { $0.id == record.mediaSourceId } ?? item.primarySource
            update(id) {
                $0.item = item
                $0.mediaSourceId = source?.id
            }
            await saveExtras(item, source: source, id: id)
            let original = record.quality == .original
            // Mobile data is also refused by the system itself, for when Kinema isn't running.
            let cellular = graph.settings.settings.downloadOnCellular
            let token = UUID().uuidString
            update(id) {
                $0.taskToken = token
                $0.cellularAllowed = cellular
            }
            let description = Self.describe(id, token)
            // The server's copy can hold one audio track: the language asked for, else the usual one.
            let language = DownloadAudio.wanted(record.audioLanguage, watching: graph.settings.settings.audioLanguage, server: graph.auth.user?.configuration?.audioLanguagePreference)
            let audio = source.flatMap { StreamResolver.audioIndex($0, language: language) }
            if original, let source, StreamResolver.offlinePlayable(source), let url = client.downloadURL(itemId: id) {
                update(id) {
                    $0.kind = .original
                    $0.expectedBytes = source.size
                    $0.audioIndex = nil
                }
                var request = URLRequest(url: url)
                request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
                request.allowsCellularAccess = cellular
                request.allowsExpensiveNetworkAccess = cellular
                let task = fileSession.downloadTask(with: request)
                task.taskDescription = description
                liveTasks.insert(id)
                launch(task, id)
            } else {
                // Repackaged (Original) or converted (the lower qualities) by the server, as HLS.
                let bitrate = record.quality.maxBitrate ?? StreamingQuality.maximum
                let profile = DeviceProfileBuilder.build(DeviceSupport.capabilities, maxBitrate: bitrate, allowDirectPlay: false)
                let response = try await client.playbackInfo(id, PlaybackInfoRequest(
                    userId: client.userId ?? "", maxStreamingBitrate: bitrate, startTimeTicks: 0,
                    audioStreamIndex: audio,
                    subtitleStreamIndex: -1, mediaSourceId: source?.id, deviceProfile: profile,
                    enableDirectPlay: false, enableDirectStream: true, enableTranscoding: true,
                    allowVideoStreamCopy: original, allowAudioStreamCopy: original, autoOpenLiveStream: true,
                    alwaysBurnInSubtitleWhenTranscoding: false
                ))
                guard let stream = StreamResolver.resolve(response, itemId: id, sourceId: source?.id, client: client), stream.isHLS else {
                    throw JellyfinError.server(0, "The server didn't offer a stream to download.")
                }
                let asset = AVURLAsset(url: stream.url, options: [
                    AVURLAssetAllowsCellularAccessKey: cellular,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: cellular,
                ])
                var options: [String: Any] = [:]
                options[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = min(bitrate, 200_000_000)
                guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: item.name, assetArtworkData: nil, options: options) else {
                    throw JellyfinError.server(0, "Couldn't start the download.")
                }
                task.taskDescription = description
                liveTasks.insert(id)
                update(id) {
                    $0.kind = .hls
                    $0.expectedBytes = Int64(Double(bitrate) / 8 * item.runtime)
                    $0.audioIndex = audio
                }
                launch(task, id)
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.error = JellyfinError.from(error).localizedDescription
            }
            pump()
        }
    }

    /** The poster, backdrop and text subtitles, saved next to the video. */
    private func saveExtras(_ item: Item, source: MediaSource?, id: String) async {
        guard let client = graph.auth.client else { return }
        let fm = FileManager.default
        func fetch(_ url: URL?, as name: String) async -> String? {
            guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { return nil }
            let target = Self.folder.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            return (try? data.write(to: target)) != nil ? name : nil
        }
        let poster = await fetch(item.posterImage.flatMap { client.imageURL($0, maxWidth: 540) }, as: "\(id)-poster.jpg")
        let backdrop = await fetch((item.landscapeImage ?? item.backdropImage).flatMap { client.imageURL($0, maxWidth: 1080) }, as: "\(id)-backdrop.jpg")
        var subtitles: [DownloadedSubtitle] = []
        if graph.settings.settings.downloadSubtitles, let source {
            for stream in source.subtitleStreams where !stream.isImageSubtitle {
                let name = "\(id)-sub-\(stream.index).srt"
                if let saved = await fetch(client.subtitleURL(itemId: id, mediaSourceId: source.id, index: stream.index), as: name) {
                    subtitles.append(DownloadedSubtitle(index: stream.index, file: saved, language: stream.language, title: stream.label, isForced: stream.isForced, isDefault: stream.isDefault))
                }
            }
        }
        update(id) {
            $0.posterFile = poster
            $0.backdropFile = backdrop
            $0.subtitles = subtitles
        }
    }

    /** Find the background tasks still running from before the app was closed. */
    private func reattach() {
        forEachTask { tasks in
            let current = tasks.filter { task, id, token in
                guard let record = self.all.first(where: { $0.id == id }), !record.isDone,
                      token == nil || record.taskToken == nil || token == record.taskToken else {
                    // Left over from a download that was deleted or started again.
                    task.cancel()
                    return false
                }
                return true
            }
            self.liveTasks = Set(current.map { $0.1 })
            // Anything "downloading" with no task is queued again.
            for record in self.all where record.state == .downloading && !self.liveTasks.contains(record.id) {
                self.update(record.id) { $0.state = .queued }
            }
            self.applyTaskStates()
            self.pump()
        }
    }

    /** "id" alone (older versions) or "id", a line break and the task's token. */
    private static func describe(_ id: String, _ token: String) -> String { "\(id)\n\(token)" }

    nonisolated fileprivate static func parse(_ description: String?) -> (id: String, token: String?)? {
        guard let description, !description.isEmpty else { return nil }
        let parts = description.split(separator: "\n", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    /** Whether news from the task named [token] is about the download as it is now. */
    private func isCurrent(_ id: String, _ token: String?) -> Bool {
        guard let record = all.first(where: { $0.id == id }) else { return false }
        return token == nil || record.taskToken == nil || token == record.taskToken
    }

    /** Every background task of both sessions, with the download each is for. */
    private func forEachTask(_ body: @escaping @MainActor ([(URLSessionTask, String, String?)]) -> Void) {
        let sessions = [fileSession as URLSession?, hlsSession as URLSession?].compactMap { $0 }
        Task {
            var found: [(URLSessionTask, String, String?)] = []
            for session in sessions {
                for task in await session.allTasks {
                    if let parsed = Self.parse(task.taskDescription) { found.append((task, parsed.id, parsed.token)) }
                }
            }
            body(found)
        }
    }

    /** Set a new task going, unless it has to wait (paused, a video playing, or mobile data). */
    private func launch(_ task: URLSessionTask, _ id: String) {
        if connectionAllows && !pausedForPlayback && all.first(where: { $0.id == id })?.state == .downloading {
            task.resume()
        }
    }

    func remove(_ id: String) {
        guard let record = all.first(where: { $0.id == id && $0.profileId == graph.auth.activeId }) ?? all.first(where: { $0.id == id }) else { return }
        cancelTasks(of: id)
        deleteFiles(record)
        all.removeAll { $0.id == id && $0.profileId == record.profileId }
        save()
        reload()
        pump()
    }

    @ObservationIgnored private var pausedForPlayback = false

    /** Hold downloads while a video plays (Settings → Downloads), and carry on after. */
    func pauseForPlayback(_ paused: Bool) {
        guard paused != pausedForPlayback, started else { return }
        pausedForPlayback = paused
        applyTaskStates()
        if !paused { pump() }
    }

    // ---------------------------------------------------- pausing, mobile data --

    /** Whether downloads may use the connection there is now (Settings → Downloads → Download on mobile data). */
    var connectionAllows: Bool {
        let network = graph.network
        return network.known && network.online && (!network.metered || graph.settings.settings.downloadOnCellular)
    }

    /** Waiting for Wi-Fi: on mobile data with downloading on it turned off. */
    var waitingForWiFi: Bool {
        graph.network.known && graph.network.online && graph.network.metered && !graph.settings.settings.downloadOnCellular
    }

    /**
     * Run the tasks that should run and hold the rest: the ones paused, all
     * of them while a video plays (if so set) or on mobile data when that's
     * turned off.
     */
    private func applyTaskStates() {
        guard started else { return }
        let allowed = connectionAllows && !pausedForPlayback
        forEachTask { tasks in
            for (task, id, token) in tasks {
                guard self.isCurrent(id, token) else { continue }
                let run = allowed && self.all.first(where: { $0.id == id })?.state == .downloading
                if run, task.state == .suspended {
                    task.resume()
                } else if !run, task.state == .running {
                    task.suspend()
                }
            }
        }
    }

    private func cancelTasks(of id: String) {
        liveTasks.remove(id)
        forEachTask { tasks in
            for (task, taskId, _) in tasks where taskId == id { task.cancel() }
        }
    }

    private func connectionChanged() {
        applyTaskStates()
        pump()
        Task { await keepNextEpisodes() }
    }

    /**
     * Settings → Downloads → Download on mobile data was changed. Downloads
     * started while it was off are refused mobile data by the system too, so
     * with it on, the ones waiting on mobile data now start again.
     */
    func cellularSettingChanged() {
        if graph.settings.settings.downloadOnCellular && graph.network.metered {
            for record in all where !record.isDone && record.state != .failed && record.cellularAllowed == false && liveTasks.contains(record.id) {
                cancelTasks(of: record.id)
                update(record.id) {
                    if $0.state == .downloading { $0.state = .queued }
                    $0.taskToken = nil
                    $0.progress = 0
                    $0.bytes = 0
                }
            }
        }
        applyTaskStates()
        pump()
    }

    func pause(_ id: String) {
        update(id) { if $0.state == .downloading || $0.state == .queued { $0.state = .paused } }
        applyTaskStates()
        pump()
    }

    func resume(_ id: String) {
        guard all.first(where: { $0.id == id })?.state == .paused else { return }
        let hasTask = liveTasks.contains(id)
        update(id) { $0.state = hasTask ? .downloading : .queued }
        applyTaskStates()
        pump()
    }

    /** Whether every download not finished (and not failed) is paused. */
    var allPaused: Bool {
        let unfinished = active.filter { $0.state != .failed }
        return !unfinished.isEmpty && unfinished.allSatisfy { $0.state == .paused }
    }

    func pauseAll() {
        for record in active where record.state == .downloading || record.state == .queued {
            update(record.id) { $0.state = .paused }
        }
        applyTaskStates()
    }

    func resumeAll() {
        for record in active where record.state == .paused {
            let hasTask = liveTasks.contains(record.id)
            update(record.id) { $0.state = hasTask ? .downloading : .queued }
        }
        applyTaskStates()
        pump()
    }

    func retry(_ id: String) {
        cancelTasks(of: id)
        update(id) {
            $0.state = .queued
            $0.error = nil
            $0.progress = 0
            $0.taskToken = nil
        }
        pump()
    }

    func removeAll() {
        for record in records { remove(record.id) }
    }

    private func deleteFiles(_ record: DownloadRecord) {
        let fm = FileManager.default
        if let url = fileURL(for: record) { try? fm.removeItem(at: url) }
        for name in [record.posterFile, record.backdropFile].compactMap({ $0 }) + record.subtitles.map(\.file) {
            try? fm.removeItem(at: Self.folder.appendingPathComponent(name))
        }
    }

    /** Forget everything stored for an account that was signed out. */
    func deleteDataFor(_ profileId: String) {
        for record in all where record.profileId == profileId { deleteFiles(record) }
        all.removeAll { $0.profileId == profileId }
        save()
        reload()
    }

    // --------------------------------------------------- subtitles added later --

    /**
     * Save the text subtitles the server has for a finished download that
     * weren't there when it was downloaded (found online in the player, or
     * added on the server since), when Settings → Downloads says so or with
     * [force]. The download as it is afterwards, and how many were added.
     */
    @discardableResult
    func refreshSubtitles(_ id: String, force: Bool = false) async -> (record: DownloadRecord, added: Int)? {
        guard force || graph.settings.settings.saveNewSubtitles, let client = graph.auth.client, graph.network.online,
              let record = record(id), record.isDone, let fresh = try? await client.item(id),
              let source = fresh.mediaSources?.first(where: { $0.id == record.mediaSourceId }) ?? fresh.primarySource
        else { return nil }
        // The server numbers tracks again when a subtitle is added: carry the kept ones over first.
        let before = record.item.mediaSources?.first(where: { $0.id == record.mediaSourceId }) ?? record.item.primarySource
        let map = StreamRemap.indexMap(from: before?.streams ?? [], to: source.streams)
        let kept = record.subtitles.map { subtitle -> DownloadedSubtitle in
            var moved = subtitle
            moved.index = map[subtitle.index] ?? subtitle.index
            return moved
        }
        let have = Set(kept.map(\.index))
        var added: [DownloadedSubtitle] = []
        for stream in source.subtitleStreams where !stream.isImageSubtitle && !have.contains(stream.index) {
            let name = "\(id)-sub-\(stream.index).srt"
            guard let url = client.subtitleURL(itemId: id, mediaSourceId: source.id, index: stream.index),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300, !data.isEmpty,
                  (try? data.write(to: Self.folder.appendingPathComponent(name), options: .atomic)) != nil
            else { continue }
            added.append(DownloadedSubtitle(index: stream.index, file: name, language: stream.language, title: stream.label, isForced: stream.isForced, isDefault: stream.isDefault))
        }
        // The fresh details list the new tracks, so the player offers them.
        update(id) {
            $0.item = fresh
            $0.subtitles = kept + added
            $0.audioIndex = $0.audioIndex.map { map[$0] ?? $0 }
        }
        guard let updated = self.record(id) else { return nil }
        return (updated, added.count)
    }

    // ------------------------------------------------------ watched offline --

    /** Remember how far a download was watched, for the server later. */
    func noteWatched(_ id: String, ticks: Int64, duration: Double) {
        let played = duration > 0 && Ticks.seconds(ticks) / duration > 0.9
        update(id) {
            $0.localPositionTicks = played ? 0 : ticks
            $0.localPlayed = played
            $0.pendingSync = true
        }
        syncWatched()
    }

    /** Send what was watched offline to the server, once it can be reached. */
    func syncWatched() {
        guard let client = graph.auth.client, graph.network.online else { return }
        let pending = records.filter(\.pendingSync)
        guard !pending.isEmpty else { return }
        Task {
            for record in pending {
                let update = UserDataUpdate(
                    playbackPositionTicks: record.localPlayed == true ? 0 : record.localPositionTicks,
                    played: record.localPlayed,
                    isFavorite: nil,
                    lastPlayedDate: ISO8601DateFormatter().string(from: Date())
                )
                do {
                    try await client.updateUserData(record.id, update)
                    self.update(record.id) { $0.pendingSync = false }
                } catch {
                    return
                }
            }
            graph.library.invalidate()
        }
    }

    // ------------------------------------------------------------ helpers --

    fileprivate func finished(_ id: String, token: String?, file: String, kind: DownloadKind, bytes: Int64) {
        guard isCurrent(id, token), all.first(where: { $0.id == id })?.isDone == false else {
            // A download deleted or started again since: what came in isn't wanted.
            let base = kind == .hls ? URL(fileURLWithPath: NSHomeDirectory()) : Self.folder
            try? FileManager.default.removeItem(at: base.appendingPathComponent(file))
            return
        }
        liveTasks.remove(id)
        update(id) {
            $0.state = .done
            $0.file = file
            $0.kind = kind
            $0.bytes = bytes
            $0.progress = 1
        }
        if let record = record(id) { graph.messages.show("Downloaded “\(record.item.name)”", .success) }
        pump()
    }

    fileprivate func failed(_ id: String, token: String?, _ error: Error?) {
        if let error = error as? URLError, error.code == .cancelled { return }
        guard isCurrent(id, token) else { return }
        liveTasks.remove(id)
        update(id) {
            $0.state = .failed
            $0.error = error.map { JellyfinError.from($0).localizedDescription } ?? "The download stopped."
        }
        pump()
    }

    fileprivate func progressed(_ id: String, token: String?, _ fraction: Double, bytes: Int64?) {
        guard isCurrent(id, token), let index = all.firstIndex(where: { $0.id == id }) else { return }
        // Not saved on every step; the index is written when the state changes.
        all[index].progress = min(0.999, max(0, fraction))
        if let bytes { all[index].bytes = bytes }
        if let shown = records.firstIndex(where: { $0.id == id }) {
            records[shown].progress = all[index].progress
            records[shown].bytes = all[index].bytes
        }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns, so it is moved now, on this thread.
        guard let (id, token) = DownloadManager.parse(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard (response?.statusCode ?? 200) < 300 else {
            let status = response?.statusCode ?? 0
            Task { @MainActor in self.failed(id, token: token, JellyfinError.server(status, nil)) }
            return
        }
        let suggested = response?.suggestedFilename.flatMap { $0.split(separator: ".").last.map(String.init) } ?? "mp4"
        let name = "\(id).\(suggested.lowercased())"
        let target = DownloadManager.folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            let bytes = DownloadManager.size(of: target)
            Task { @MainActor in self.finished(id, token: token, file: name, kind: .original, bytes: bytes) }
        } catch {
            Task { @MainActor in self.failed(id, token: token, error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, token) = DownloadManager.parse(downloadTask.taskDescription) else { return }
        Task { @MainActor in
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (self.record(id)?.expectedBytes ?? 0)
            self.progressed(id, token: token, expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0, bytes: totalBytesWritten)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (id, token) = DownloadManager.parse(task.taskDescription) else { return }
        Task { @MainActor in self.failed(id, token: token, error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, token) = DownloadManager.parse(assetDownloadTask.taskDescription) else { return }
        // Kept relative to the app's home: the full path changes between app updates.
        let home = NSHomeDirectory()
        let relative = location.path.hasPrefix(home) ? String(location.path.dropFirst(home.count + 1)) : location.relativePath
        let bytes = DownloadManager.size(of: location)
        Task { @MainActor in self.finished(id, token: token, file: relative, kind: .hls, bytes: bytes) }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let (id, token) = DownloadManager.parse(assetDownloadTask.taskDescription) else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        Task { @MainActor in
            self.progressed(id, token: token, expected > 0 ? loaded / expected : 0, bytes: nil)
        }
    }
}
