import Foundation
import Observation

/**
 * What the pages share about the library: the user's libraries, and
 * watched / favourite changes made in this session, so every card showing
 * an item agrees the moment one of them is tapped, before the pages reload.
 */
@MainActor
@Observable
final class LibraryStore {
    private unowned let graph: AppGraph

    /** The user's libraries, in their order. */
    private(set) var views: [Item] = []
    private(set) var viewsLoaded = false
    /** Bumped when something changed that lists should reload for. */
    private(set) var version = 0

    /** Watched and favourite as last set here, by item id, ahead of what the pages loaded. */
    private(set) var playedOverrides: [String: Bool] = [:]
    private(set) var favoriteOverrides: [String: Bool] = [:]
    /** Resume positions as last played here (ticks), ahead of the pages. */
    private(set) var positionOverrides: [String: Int64] = [:]

    init(graph: AppGraph) {
        self.graph = graph
    }

    func reset() {
        views = []
        viewsLoaded = false
        playedOverrides = [:]
        favoriteOverrides = [:]
        positionOverrides = [:]
        version += 1
    }

    /** Something changed on the server (played, marked): lists reload. */
    func invalidate() {
        version += 1
    }

    /** Libraries Kinema can show: movies, shows, collections, mixed and home videos. */
    var videoViews: [Item] {
        views.filter { view in
            switch view.collectionType {
            case "movies", "tvshows", "boxsets", "homevideos", "musicvideos", nil, "mixed", "folders": return true
            default: return false
            }
        }
    }

    func loadViews(force: Bool = false) async {
        guard force || !viewsLoaded, let client = graph.auth.client else { return }
        if let loaded = try? await client.views() {
            views = loaded
            viewsLoaded = true
        }
    }

    // ------------------------------------------------------------ overrides --

    func isPlayed(_ item: Item) -> Bool { playedOverrides[item.id] ?? item.isPlayed }
    func isFavorite(_ item: Item) -> Bool { favoriteOverrides[item.id] ?? item.isFavorite }

    /** How far through [item] is, with what was just watched here. */
    func progress(_ item: Item) -> Double? {
        if isPlayed(item) { return nil }
        if let ticks = positionOverrides[item.id] {
            guard ticks > 0, let total = item.runTimeTicks, total > 0 else { return nil }
            return min(1, Double(ticks) / Double(total))
        }
        if playedOverrides[item.id] == false { return nil }
        return item.progress
    }

    func resumeTicks(_ item: Item) -> Int64 {
        if isPlayed(item) && positionOverrides[item.id] == nil { return 0 }
        return positionOverrides[item.id] ?? item.userData?.playbackPositionTicks ?? 0
    }

    /** The item with this session's changes applied, for pages that pass it on. */
    func current(_ item: Item) -> Item {
        var copy = item
        var data = copy.userData ?? UserData()
        data.played = isPlayed(item)
        data.isFavorite = isFavorite(item)
        data.playbackPositionTicks = resumeTicks(item)
        if positionOverrides[item.id] != nil { data.playedPercentage = nil }
        copy.userData = data
        return copy
    }

    func notePosition(_ id: String, ticks: Int64, played: Bool) {
        positionOverrides[id] = played ? 0 : ticks
        if played { playedOverrides[id] = true } else if ticks > 0 { playedOverrides[id] = false }
    }

    /** Watched or not, at once, and on the server; back if the server says no. */
    func setPlayed(_ item: Item, _ played: Bool) async -> String? {
        let before = playedOverrides[item.id]
        let beforePosition = positionOverrides[item.id]
        playedOverrides[item.id] = played
        // Either way it starts from the beginning next time.
        positionOverrides[item.id] = 0
        guard let client = graph.auth.client else { return "You're not signed in." }
        do {
            _ = try await client.setPlayed(item.id, played)
            version += 1
            return nil
        } catch {
            playedOverrides[item.id] = before
            positionOverrides[item.id] = beforePosition
            return JellyfinError.from(error).localizedDescription
        }
    }

    func setFavorite(_ item: Item, _ favorite: Bool) async -> String? {
        let before = favoriteOverrides[item.id]
        favoriteOverrides[item.id] = favorite
        guard let client = graph.auth.client else { return "You're not signed in." }
        do {
            _ = try await client.setFavorite(item.id, favorite)
            version += 1
            return nil
        } catch {
            favoriteOverrides[item.id] = before
            return JellyfinError.from(error).localizedDescription
        }
    }
}
