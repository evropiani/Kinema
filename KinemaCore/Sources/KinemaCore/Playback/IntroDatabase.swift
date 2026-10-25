import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/**
 * Intros, recaps and credits from the community databases on the web, for
 * films and episodes the server knows nothing about: TheIntroDB
 * (theintrodb.org, by TVDB, TMDB or IMDb id) first, then IntroDB
 * (introdb.app, by IMDb id). Neither needs an account.
 */
enum IntroDatabase {
    /** What identifies a film or an episode to the databases. */
    struct Lookup: Hashable {
        var isMovie: Bool
        /** The film's ids, or the show's (not the episode's). */
        var tvdbId: String?
        var tmdbId: String?
        var imdbId: String?
        var season: Int?
        var episode: Int?
        /** TVDB's id for the episode itself, which pins it whatever the numbering. */
        var tvdbEpisodeId: String?
        var durationMs: Int64?

        /**
         * The lookup for [item]; for an episode, [seriesIds] are its show's
         * provider ids. Nil when there's nothing to look it up by.
         */
        init?(item: Item, seriesIds: [String: String]?) {
            let positive: (String?) -> String? = { id in
                guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id != "0" else { return nil }
                return id
            }
            durationMs = item.runTimeTicks.map { $0 / 10_000 }.flatMap { $0 > 0 ? $0 : nil }
            switch item.kind {
            case .movie:
                isMovie = true
                tvdbId = positive(item.providerIds?["Tvdb"])
                tmdbId = positive(item.providerIds?["Tmdb"])
                imdbId = positive(item.providerIds?["Imdb"])
            case .episode:
                guard let season = item.parentIndexNumber, let episode = item.indexNumber, let ids = seriesIds else { return nil }
                isMovie = false
                self.season = season
                self.episode = episode
                tvdbId = positive(ids["Tvdb"])
                tmdbId = positive(ids["Tmdb"])
                imdbId = positive(ids["Imdb"])
                tvdbEpisodeId = positive(item.providerIds?["Tvdb"])
            default:
                return nil
            }
            if tvdbId == nil && tmdbId == nil && imdbId == nil { return nil }
        }

        /**
         * TheIntroDB's address. A TVDB id is used when the episode's own TVDB
         * id pins it (TVDB numbering can differ from the library's); otherwise
         * TMDB, whose numbering is Jellyfin's default, then TVDB, then IMDb.
         */
        func theIntroDBURL() -> URL? {
            var items: [URLQueryItem] = []
            if let tvdbId, isMovie || tvdbEpisodeId != nil || tmdbId == nil {
                items.append(URLQueryItem(name: "tvdb_id", value: tvdbId))
                if !isMovie, let tvdbEpisodeId { items.append(URLQueryItem(name: "tvdb_episode_id", value: tvdbEpisodeId)) }
            } else if let tmdbId {
                items.append(URLQueryItem(name: "tmdb_id", value: tmdbId))
            } else if let imdbId {
                items.append(URLQueryItem(name: "imdb_id", value: imdbId))
            } else {
                return nil
            }
            if !isMovie, let season, let episode {
                items.append(URLQueryItem(name: "season", value: String(season)))
                items.append(URLQueryItem(name: "episode", value: String(episode)))
            }
            if let durationMs { items.append(URLQueryItem(name: "duration_ms", value: String(durationMs))) }
            var components = URLComponents(string: "https://api.theintrodb.org/v4/media")
            components?.queryItems = items
            return components?.url
        }

        /** IntroDB's address: it knows shows and films by IMDb id only. */
        func introDBURL() -> URL? {
            guard let imdbId else { return nil }
            var items = [URLQueryItem(name: "imdb_id", value: imdbId)]
            if !isMovie, let season, let episode {
                items.append(URLQueryItem(name: "season", value: String(season)))
                items.append(URLQueryItem(name: "episode", value: String(episode)))
            }
            var components = URLComponents(string: "https://api.introdb.app/segments")
            components?.queryItems = items
            return components?.url
        }
    }

    /** One stretch from a database. No start means from the beginning; no end, to the end. */
    struct Found: Codable, Hashable {
        /** Jellyfin's segment type: Intro, Recap, Outro or Preview. */
        var type: String
        var startMs: Int64?
        var endMs: Int64?
        /** Which database it came from, for the player's info. */
        var source: String
    }

    // ------------------------------------------------------------- parsing --

    private struct TheIntroDBResponse: Decodable {
        struct Stamp: Decodable {
            var start_ms: Int64?
            var end_ms: Int64?
        }
        var intro: [Stamp]?
        var recap: [Stamp]?
        var credits: [Stamp]?
        var preview: [Stamp]?
    }

    private struct IntroDBResponse: Decodable {
        struct Stamp: Decodable {
            var start_ms: Int64?
            var end_ms: Int64?
            var start_sec: Double?
            var end_sec: Double?

            var start: Int64? { start_ms ?? start_sec.map { Int64(($0 * 1000).rounded()) } }
            var end: Int64? { end_ms ?? end_sec.map { Int64(($0 * 1000).rounded()) } }
        }
        var intro: Stamp?
        var recap: Stamp?
        var outro: Stamp?
    }

    static func parseTheIntroDB(_ data: Data) -> [Found] {
        guard let response = try? JSONDecoder().decode(TheIntroDBResponse.self, from: data) else { return [] }
        var found: [Found] = []
        let groups: [(String, [TheIntroDBResponse.Stamp]?)] = [
            ("Intro", response.intro), ("Recap", response.recap), ("Outro", response.credits), ("Preview", response.preview),
        ]
        for (type, stamps) in groups {
            for stamp in stamps ?? [] where stamp.start_ms != nil || stamp.end_ms != nil {
                found.append(Found(type: type, startMs: stamp.start_ms, endMs: stamp.end_ms, source: "TheIntroDB"))
            }
        }
        return found
    }

    static func parseIntroDB(_ data: Data) -> [Found] {
        guard let response = try? JSONDecoder().decode(IntroDBResponse.self, from: data) else { return [] }
        let groups: [(String, IntroDBResponse.Stamp?)] = [("Intro", response.intro), ("Recap", response.recap), ("Outro", response.outro)]
        return groups.compactMap { type, stamp in
            guard let stamp, stamp.start != nil || stamp.end != nil else { return nil }
            return Found(type: type, startMs: stamp.start, endMs: stamp.end, source: "IntroDB")
        }
    }

    /**
     * The stretches as segments of a video [duration] seconds long, leaving
     * out any that don't fit it (they were timed on another cut).
     */
    static func segments(_ found: [Found], duration: Double) -> [MediaSegment] {
        var result: [MediaSegment] = []
        for (i, stretch) in found.enumerated() {
            let start = Double(stretch.startMs ?? 0) / 1000
            var end: Double
            if let endMs = stretch.endMs {
                end = Double(endMs) / 1000
            } else if duration > 0 {
                end = duration
            } else {
                continue
            }
            if duration > 0 {
                // A little slack for a different encode; well past the end means another version.
                guard start < duration - 1, end <= duration + 20 else { continue }
                end = min(end, duration)
            }
            guard end - start >= 2 else { continue }
            result.append(MediaSegment(id: "online-\(stretch.type.lowercased())-\(i)", type: stretch.type, start: start, end: end))
        }
        return result.sorted { $0.startTicks < $1.startTicks }
    }

    // ------------------------------------------------------------ fetching --

    enum Outcome: Equatable {
        case found([Found])
        /** Neither database has it. */
        case missing
        /** A database couldn't be reached or refused (rate limit); worth trying again later. */
        case failed
    }

    /** Ask TheIntroDB, then IntroDB when TheIntroDB has nothing. */
    static func fetch(_ lookup: Lookup, userAgent: String, session: URLSession = .shared) async -> Outcome {
        var failed = false
        if let url = lookup.theIntroDBURL() {
            switch await get(url, userAgent: userAgent, session: session) {
            case .some(let data):
                let found = parseTheIntroDB(data)
                if !found.isEmpty { return .found(found) }
            case .none:
                failed = true
            }
        }
        if let url = lookup.introDBURL() {
            switch await get(url, userAgent: userAgent, session: session) {
            case .some(let data):
                let found = parseIntroDB(data)
                if !found.isEmpty { return .found(found) }
            case .none:
                failed = true
            }
        }
        return failed ? .failed : .missing
    }

    /** The body of a 200, empty for a 404 (not in the database), nil when it failed. */
    private static func get(_ url: URL, userAgent: String, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200..<300: return data
        case 404: return Data()
        default: return nil
        }
    }

    // ------------------------------------------------------------- merging --

    /**
     * The segments to use: for each kind (intro, credits…), the server's own
     * if it has any, else the ones marked by hand, else the database's.
     */
    static func merge(server: [MediaSegment], marked: [MediaSegment], online: [MediaSegment]) -> [MediaSegment] {
        var result = server
        var have = Set(server.map(\.type))
        for segment in marked where !have.contains(segment.type) { result.append(segment) }
        have.formUnion(marked.map(\.type))
        for segment in online where !have.contains(segment.type) { result.append(segment) }
        return result.sorted { $0.startTicks < $1.startTicks }
    }
}
