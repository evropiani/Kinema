import Foundation
import Observation
import SwiftUI

/** The tabs. Search is last: it sits beside the bar as its own round button. */
enum MainTab: String, CaseIterable, Hashable {
    case home, library, downloads, settings, search

    /** The tabs inside the bar; search sits beside it. */
    static let bar: [MainTab] = [.home, .library, .downloads, .settings]

    var label: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.stack.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

/** A list of things the home page can show in full. */
enum ShelfKind: Hashable {
    case continueWatching
    case nextUp
    case latest(libraryId: String, name: String)
    case favorites
}

/** The pages a tab can open on top of its start page. */
enum Route: Hashable {
    case item(Item)
    case person(id: String, name: String)
    case library(Item)
    case genre(name: String, parentId: String?, types: [String])
    case shelf(ShelfKind)
    case downloadedSeries(seriesId: String, name: String)
    case settings(SettingsPage)
}

enum SettingsPage: String, Hashable, CaseIterable {
    case accounts, appearance, home, playback, gestures, subtitles, downloads, storage, about
}

/** Where the sign-in screen should start when it is opened over the app. */
struct LoginRequest: Equatable {
    var url = ""
    var user = ""
}

/** Navigation and the sheets any screen can ask for; the root view shows them. */
@MainActor
@Observable
final class AppUI {
    var tab: MainTab = .home
    /** Each tab keeps its own stack of pages, like any iOS app. */
    var paths: [MainTab: [Route]] = [:]
    var playerOpen = false
    /** What is typed in the search field, kept while you look at other tabs. */
    var searchQuery = ""
    /** The tab you came to search from; the collapsed tab bar goes back to it. */
    var previousTab: MainTab = .home
    /** Signing in to another server, over the app. */
    var login: LoginRequest?
    /** The new version being looked at, on the update page. */
    var update: AppRelease?
    /** Asking whether to resume or start over. */
    var resumePrompt: Item?
    /** Choosing what to download (quality) for these items. */
    var downloadPrompt: [Item]?

    /** Whether the welcome has been seen. */
    private(set) var welcomed = UserDefaults.standard.bool(forKey: "ui.welcomed")

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "ui.welcomed")
        welcomed = true
    }

    /** The pages open on top of the current tab's start page. */
    var path: [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    func path(for tab: MainTab) -> [Route] { paths[tab] ?? [] }

    func setPath(_ path: [Route], for tab: MainTab) { paths[tab] = path }

    /** Forget every open page, in every tab (a different server has a different library). */
    func resetPaths() { paths = [:] }
}

/**
 * Everything a screen can ask the app to do: navigate, play, change the
 * library. Screens reach it as `graph.actions`.
 */
@MainActor
final class AppActions {
    private unowned let graph: AppGraph

    init(graph: AppGraph) {
        self.graph = graph
    }

    private var ui: AppUI { graph.ui }
    private var messages: UiMessages { graph.messages }

    // --------------------------------------------------------- navigation --

    func navigate(_ route: Route) {
        if ui.path.last == route { return }
        ui.path.append(route)
    }

    func back() {
        if !ui.path.isEmpty { ui.path.removeLast() }
    }

    /** Switch tabs; choosing the tab you are on goes back to its start page. */
    func selectTab(_ tab: MainTab) {
        if ui.tab == tab {
            ui.setPath([], for: tab)
        } else {
            if tab == .search { ui.previousTab = ui.tab }
            ui.tab = tab
        }
    }

    /** Open a title's page (an episode opens its own page too). */
    func open(_ item: Item) {
        switch item.kind {
        case .person:
            navigate(.person(id: item.id, name: item.name))
        case .collectionFolder, .userView:
            navigate(.library(item))
        default:
            navigate(.item(item))
        }
    }

    func openSeries(of episode: Item) {
        guard let id = episode.seriesId else { return }
        navigate(.item(Item(id: id, name: episode.seriesName ?? "", type: "Series")))
    }

    // ------------------------------------------------------------ playing --

    /**
     * Play [item]: a movie or episode itself, a series from its next episode,
     * a season or collection from its first unwatched item. [fromStart]
     * ignores where it was left.
     */
    func play(_ item: Item, fromStart: Bool? = nil, mediaSourceId: String? = nil) {
        Task {
            guard let target = await playable(for: item) else {
                messages.show("Nothing to play here yet.")
                return
            }
            let current = graph.library.current(target)
            let position = graph.library.resumeTicks(current)
            if fromStart == nil, position > 0, graph.settings.settings.resume == .ask {
                ui.resumePrompt = current
                return
            }
            let start: Int64
            if fromStart == true || graph.settings.settings.resume == .restart && fromStart == nil {
                start = 0
            } else {
                start = position
            }
            graph.player.open(current, startTicks: start, mediaSourceId: mediaSourceId)
        }
    }

    /** What playing [item] means: itself, or the right episode or film inside it. */
    private func playable(for item: Item) async -> Item? {
        if item.isPlayable { return item }
        guard let client = graph.auth.client else { return nil }
        switch item.kind {
        case .series:
            if let next = try? await client.nextUp(seriesId: item.id, limit: 1).first { return next }
            return try? await client.episodes(seriesId: item.id, limit: 1).first
        case .season:
            let episodes = (try? await client.episodes(seriesId: item.seriesId ?? item.parentId ?? "", seasonId: item.id)) ?? []
            return episodes.first { !graph.library.isPlayed($0) } ?? episodes.first
        default:
            var query = ItemQuery(parentId: item.id, includeTypes: ["Movie", "Episode", "Video"])
            query.sortBy = ["SortName"]
            query.limit = 50
            let children = (try? await client.items(query).items) ?? []
            return children.first { !graph.library.isPlayed($0) } ?? children.first
        }
    }

    func playTrailer(_ item: Item) {
        Task {
            if let client = graph.auth.client, (item.localTrailerCount ?? 0) > 0,
               let trailer = try? await client.localTrailers(item.id).first {
                graph.player.open(trailer, startTicks: 0, mediaSourceId: nil)
                return
            }
            if let remote = item.remoteTrailers?.first?.url, let url = URL(string: remote) {
                _ = await UIApplication.shared.open(url)
            } else {
                messages.show("No trailer for this one.")
            }
        }
    }

    // ------------------------------------------------------------ library --

    func setPlayed(_ item: Item, _ played: Bool) {
        Haptics.tap()
        Task {
            if let error = await graph.library.setPlayed(item, played) {
                messages.error(error)
            }
        }
    }

    func setFavorite(_ item: Item, _ favorite: Bool) {
        Haptics.tap()
        Task {
            if let error = await graph.library.setFavorite(item, favorite) {
                messages.error(error)
            } else if favorite {
                messages.show("Added to Favorites", .success)
            }
        }
    }

    /** Download [items] (a film, episodes, a season), asking for the quality first. */
    func download(_ items: [Item]) {
        guard !items.isEmpty else { return }
        guard graph.auth.canDownload else {
            messages.error("Your account isn't allowed to download from this server.")
            return
        }
        ui.downloadPrompt = items
    }

    /** Download every episode of a season or series. */
    func downloadAll(in item: Item) {
        Task {
            guard let client = graph.auth.client else { return }
            var episodes: [Item] = []
            switch item.kind {
            case .series: episodes = (try? await client.episodes(seriesId: item.id)) ?? []
            case .season: episodes = (try? await client.episodes(seriesId: item.seriesId ?? item.parentId ?? "", seasonId: item.id)) ?? []
            default: episodes = [item]
            }
            download(episodes.filter { $0.locationType != "Virtual" })
        }
    }
}
