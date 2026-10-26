#if DEBUG
import Foundation
import SwiftUI

/**
 * For CI's simulator screenshots only (Debug builds). With KINEMA_DEMO_SERVER
 * set in the environment, Kinema signs in to that server, opens the screen
 * named by KINEMA_SCREEN and then drops a marker file in Documents so the
 * script knows when to take the picture. Release builds leave this out.
 */
@MainActor
enum ScreenshotDriver {
    nonisolated private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var screen: String? {
        guard env["KINEMA_DEMO_SERVER"]?.isEmpty == false else { return nil }
        return env["KINEMA_SCREEN"]
    }

    /** The welcome starts at the server step for the "server" screenshot. */
    static var welcomeStep: Int { screen == "server" ? 1 : 0 }

    /** The address the server step fills in by itself, for the "server" screenshot. */
    static var serverPrefill: String? { screen == "server" ? env["KINEMA_DEMO_SERVER"] : nil }

    /** For the "lens" screenshot: a finger held on the tab bar, between Home and Library. */
    nonisolated static var lensFinger: CGFloat? {
        ProcessInfo.processInfo.environment["KINEMA_SCREEN"] == "lens" ? 120 : nil
    }

    private static var loaded: Set<String> = []

    /** A screen has its content. */
    static func noteLoaded(_ name: String) {
        loaded.insert(name)
    }

    static func noteServerShown() {
        loaded.insert("server")
    }

    static func start() {
        guard let server = env["KINEMA_DEMO_SERVER"], let screen else { return }
        Task { @MainActor in
            let graph = AppGraph.shared
            let look: ThemeMode = env["KINEMA_LOOK"] == "light" ? .light : .dark
            if graph.settings.settings.theme != look { graph.settings.update { $0.theme = look } }
            if screen == "welcome" || screen == "server" {
                if screen == "server" { await waitFor("server", seconds: 30) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                mark(screen, "ok")
                return
            }
            graph.ui.finishWelcome()
            if graph.auth.client == nil {
                do {
                    let (url, system) = try await JellyfinClient.probe(server, info: graph.auth.info)
                    let result = try await graph.auth.anonymousClient(url).authenticate(username: env["KINEMA_DEMO_USER"] ?? "demo", password: env["KINEMA_DEMO_PASS"] ?? "")
                    graph.auth.signedIn(result, server: url, system: system)
                } catch {
                    mark(screen, "login failed: \(error)")
                    return
                }
            }
            let expected = await open(screen, graph)
            if let expected { await waitFor(expected, seconds: 40) }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if screen == "player" { graph.player.controlsVisible = false }
            try? await Task.sleep(nanoseconds: 500_000_000)
            mark(screen, expected.map { loaded.contains($0) ? "ok" : "content not loaded: \($0)" } ?? "ok")
        }
    }

    private static func waitFor(_ name: String, seconds: Int) async {
        for _ in 0..<(seconds * 4) {
            if loaded.contains(name) { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /** Go to [screen]; returns what has to load before the picture is taken. */
    private static func open(_ screen: String, _ graph: AppGraph) async -> String? {
        let actions = graph.actions
        let client = graph.auth.client
        func first(_ types: [String], backdrop: Bool = false) async -> Item? {
            guard let client else { return nil }
            var query = ItemQuery(includeTypes: types)
            query.sortBy = ["DateCreated"]
            query.descending = true
            if backdrop { query.imageTypes = ["Backdrop"] }
            query.limit = 5
            return try? await client.items(query).items.first
        }
        switch screen {
        case "home", "lens":
            actions.selectTab(.home)
            return "home"
        case "library":
            actions.selectTab(.library)
            return "library"
        case "movie":
            actions.selectTab(.home)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let movie = await first(["Movie"], backdrop: true) { actions.open(movie) }
            return "movie"
        case "series":
            actions.selectTab(.home)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let series = await first(["Series"]) { actions.open(series) }
            return "series"
        case "episodes":
            actions.selectTab(.home)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let series = await first(["Series"]), let episode = try? await client?.episodes(seriesId: series.id, limit: 2).last {
                actions.open(episode)
            }
            return "episode"
        case "badges", "badges-series":
            // Some films and episodes shown as downloaded, for the badges: the
            // newest films whole, the show's next episode whole, the show itself in part.
            var movieQuery = ItemQuery(includeTypes: ["Movie"])
            movieQuery.limit = 50
            let movies = (try? await client?.items(movieQuery).items) ?? []
            var pretend = movies
            if let series = await first(["Series"]), let episodes = try? await client?.episodes(seriesId: series.id) {
                pretend += Array(episodes.prefix(2))
                if let next = try? await client?.nextUp(seriesId: series.id, limit: 1).first { pretend.append(next) }
                if screen == "badges-series" {
                    graph.downloads.pretendDownloaded(pretend)
                    actions.selectTab(.home)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    actions.open(series)
                    return "series"
                }
            }
            graph.downloads.pretendDownloaded(pretend)
            actions.selectTab(.home)
            return "home"
        case "search":
            actions.selectTab(.search)
            return nil
        case "found":
            actions.selectTab(.search)
            try? await Task.sleep(nanoseconds: 800_000_000)
            graph.ui.searchQuery = "the"
            return "found"
        case "settings":
            actions.selectTab(.settings)
            return nil
        case "settings-general", "settings-appearance", "settings-playback", "settings-player", "settings-accounts":
            actions.selectTab(.settings)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let page: SettingsPage = switch screen {
            case "settings-general": .general
            case "settings-appearance": .appearance
            case "settings-playback": .playback
            case "settings-accounts": .accounts
            default: .gestures
            }
            actions.navigate(.settings(page))
            return nil
        case "downloads":
            actions.selectTab(.downloads)
            return nil
        case "player", "player-controls":
            actions.selectTab(.home)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let movie = await first(["Movie"], backdrop: true) {
                graph.player.open(movie, startTicks: Ticks.from(300), mediaSourceId: nil)
            }
            if screen == "player-controls" {
                Task { @MainActor in
                    await waitFor("player", seconds: 40)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    graph.player.pause()
                    graph.player.controlsVisible = true
                }
            }
            return "player"
        default:
            actions.selectTab(.home)
            return "home"
        }
    }

    private static func mark(_ screen: String, _ note: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? note.write(to: documents.appendingPathComponent("kinema-ready-\(screen)"), atomically: true, encoding: .utf8)
    }
}
#endif
