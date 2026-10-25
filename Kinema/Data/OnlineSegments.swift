import Foundation
import Observation

/**
 * Intros and credits found in the online databases (Settings → Playback →
 * Find intros and credits online), kept on disk by item, so they're there for
 * downloads played offline and the database is asked once per episode.
 */
@MainActor
@Observable
final class OnlineSegments {
    private struct Entry: Codable {
        var found: [IntroDatabase.Found]
        var fetched: Date
    }

    /** Found stretches are kept a month; "not in the database" for three days, as entries are added all the time. */
    private static let foundLifetime: TimeInterval = 30 * 86_400
    private static let missingLifetime: TimeInterval = 3 * 86_400

    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var seriesIds: [String: [String: String]] = [:]
    @ObservationIgnored private var inFlight: [String: Task<[IntroDatabase.Found], Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var draining = false

    /** How many items have stretches kept, for Settings → Storage. */
    private(set) var count = 0

    private static var file: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("online-segments.json")
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "Kinema/\(version) (iOS; +https://github.com/evropiani/Kinema)"
    }()

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored.filter { !Self.expired($0.value) }
        }
        count = entries.values.filter { !$0.found.isEmpty }.count
    }

    private static func expired(_ entry: Entry) -> Bool {
        let lifetime = entry.found.isEmpty ? missingLifetime : foundLifetime
        return Date().timeIntervalSince(entry.fetched) > lifetime
    }

    /** What's kept for [itemId], without asking anyone. */
    func cached(_ itemId: String) -> [IntroDatabase.Found]? {
        guard let entry = entries[itemId], !Self.expired(entry) else { return nil }
        return entry.found
    }

    /**
     * The stretches the databases have for [item] (a film or an episode):
     * kept ones, or asked for now. Empty when there are none, or offline.
     */
    func find(_ item: Item) async -> [IntroDatabase.Found] {
        if let kept = cached(item.id) { return kept }
        if let running = inFlight[item.id] { return await running.value }
        guard AppGraph.shared.network.online, item.kind == .episode || item.kind == .movie else { return [] }
        let task = Task { await self.lookUp(item) }
        inFlight[item.id] = task
        let found = await task.value
        inFlight[item.id] = nil
        return found
    }

    /**
     * Look [item] up ahead of time (a download, the next episode), so it's
     * ready later. One at a time, so a whole season stays within the
     * databases' limits.
     */
    func prefetch(_ item: Item) {
        guard AppGraph.shared.settings.settings.onlineSegments, cached(item.id) == nil,
              !queue.contains(where: { $0.id == item.id }) else { return }
        queue.append(item)
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty {
                _ = await find(queue.removeFirst())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            draining = false
        }
    }

    private func lookUp(_ item: Item) async -> [IntroDatabase.Found] {
        var ids: [String: String]?
        if item.kind == .episode {
            guard let seriesId = item.seriesId else { return [] }
            ids = await providerIds(ofSeries: seriesId)
            if ids == nil { return [] }
        }
        guard let lookup = IntroDatabase.Lookup(item: item, seriesIds: ids) else {
            remember(item.id, [])
            return []
        }
        switch await IntroDatabase.fetch(lookup, userAgent: Self.userAgent) {
        case .found(let found):
            remember(item.id, found)
            return found
        case .missing:
            remember(item.id, [])
            return []
        case .failed:
            // Not kept: try again next time.
            return []
        }
    }

    /** A show's TVDB, TMDB and IMDb ids (an episode's own are the episode's). */
    private func providerIds(ofSeries seriesId: String) async -> [String: String]? {
        if let known = seriesIds[seriesId] { return known }
        guard let client = AppGraph.shared.auth.client, let series = try? await client.item(seriesId) else { return nil }
        let ids = series.providerIds ?? [:]
        seriesIds[seriesId] = ids
        return ids
    }

    private func remember(_ itemId: String, _ found: [IntroDatabase.Found]) {
        entries[itemId] = Entry(found: found, fetched: Date())
        count = entries.values.filter { !$0.found.isEmpty }.count
        scheduleSave()
    }

    func clearAll() {
        entries = [:]
        seriesIds = [:]
        count = 0
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}
