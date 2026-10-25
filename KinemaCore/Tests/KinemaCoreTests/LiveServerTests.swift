import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import KinemaCore

/**
 * Against a real server, only when KINEMA_LIVE_SERVER is set (for example to
 * https://demo.jellyfin.org/stable, with KINEMA_LIVE_USER=demo and an empty
 * KINEMA_LIVE_PASS). Skipped otherwise, so the suite runs offline.
 */
final class LiveServerTests: XCTestCase {
    private func signIn() async throws -> JellyfinClient {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["KINEMA_LIVE_SERVER"], !server.isEmpty else { throw XCTSkip("KINEMA_LIVE_SERVER not set") }
        let info = ClientInfo(version: "1.0.0", deviceName: "Kinema tests", deviceId: "kinema-core-tests")
        let (url, system) = try await JellyfinClient.probe(server, info: info)
        XCTAssertNotNil(system.version)
        let anonymous = JellyfinClient(baseURL: url, info: info)
        let auth = try await anonymous.authenticate(username: env["KINEMA_LIVE_USER"] ?? "demo", password: env["KINEMA_LIVE_PASS"] ?? "")
        return anonymous.signedIn(token: auth.accessToken, userId: auth.user.id)
    }

    func testBrowsesAndResolvesPlayback() async throws {
        let client = try await signIn()
        let me = try await client.me()
        XCTAssertFalse(me.name.isEmpty)
        let views = try await client.views()
        XCTAssertFalse(views.isEmpty)
        let movieLibrary = views.first { $0.collectionType == "movies" }

        var query = ItemQuery(parentId: movieLibrary?.id, includeTypes: ["Movie"])
        query.sortBy = ["SortName"]
        query.limit = 5
        let movies = try await client.items(query)
        let first = try XCTUnwrap(movies.items.first)
        XCTAssertGreaterThan(movies.totalRecordCount ?? 0, 0)

        let detail = try await client.item(first.id)
        XCTAssertFalse(detail.mediaSources?.isEmpty ?? true)
        _ = try await client.latest(parentId: movieLibrary?.id, limit: 5)
        _ = try await client.resume(limit: 5)
        _ = try await client.nextUp(limit: 5)
        _ = try await client.similar(first.id)
        _ = try await client.genres(parentId: movieLibrary?.id, types: ["Movie"])
        _ = try await client.years(parentId: movieLibrary?.id, types: ["Movie"])
        _ = await client.mediaSegments(first.id)
        let counts = try await client.itemCounts()
        XCTAssertGreaterThan(counts.movies, 0)

        let profile = DeviceProfileBuilder.build(DeviceCapabilities(), maxBitrate: 120_000_000)
        func info(direct: Bool) async throws -> PlaybackInfoResponse {
            try await client.playbackInfo(first.id, PlaybackInfoRequest(
                userId: client.userId ?? "", maxStreamingBitrate: 120_000_000, startTimeTicks: 0,
                audioStreamIndex: nil, subtitleStreamIndex: nil, mediaSourceId: nil, deviceProfile: profile,
                enableDirectPlay: direct, enableDirectStream: true, enableTranscoding: true,
                allowVideoStreamCopy: true, allowAudioStreamCopy: true, autoOpenLiveStream: true,
                alwaysBurnInSubtitleWhenTranscoding: false
            ))
        }
        let direct = try await info(direct: true)
        let stream = try XCTUnwrap(StreamResolver.resolve(direct, itemId: first.id, sourceId: nil, client: client))
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue([200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0), "\(stream.url)")

        let hls = try await info(direct: false)
        let converted = try XCTUnwrap(StreamResolver.resolve(hls, itemId: first.id, sourceId: nil, client: client))
        XCTAssertTrue(converted.isHLS)
        let (playlist, _) = try await URLSession.shared.data(from: converted.url)
        XCTAssertTrue(String(decoding: playlist, as: UTF8.self).hasPrefix("#EXTM3U"))

        var search = ItemQuery(includeTypes: ["Movie", "Series", "Episode"])
        search.searchTerm = String(first.name.prefix(4))
        search.limit = 10
        let found = try await client.items(search)
        XCTAssertFalse(found.items.isEmpty)
        _ = try await client.persons(searchTerm: "a", limit: 5)

        let shows = try await client.items({ var q = ItemQuery(includeTypes: ["Series"]); q.limit = 1; return q }())
        if let series = shows.items.first {
            let seasons = try await client.seasons(seriesId: series.id)
            let episodes = try await client.episodes(seriesId: series.id, seasonId: seasons.first?.id)
            XCTAssertFalse(episodes.isEmpty)
        }
    }

    func testQuickConnectAnswers() async throws {
        let client = try await signIn()
        _ = await client.quickConnectEnabled()
        let users = try await JellyfinClient(baseURL: client.baseURL, info: client.info).publicUsers()
        XCTAssertNotNil(users)
    }

    /** Against the two intro databases, only when KINEMA_LIVE_INTRODB is set. */
    func testFindsIntrosOnline() async throws {
        guard ProcessInfo.processInfo.environment["KINEMA_LIVE_INTRODB"] != nil else { throw XCTSkip("KINEMA_LIVE_INTRODB not set") }
        var episode = Item(id: "e", name: "Cat's in the Bag...", type: "Episode")
        episode.parentIndexNumber = 1
        episode.indexNumber = 2
        let lookup = try XCTUnwrap(IntroDatabase.Lookup(item: episode, seriesIds: ["Tmdb": "1396", "Imdb": "tt0903747"]))
        guard case .found(let found) = await IntroDatabase.fetch(lookup, userAgent: "KinemaTests/1.0") else { return XCTFail("nothing found") }
        XCTAssertTrue(found.contains { $0.type == "Intro" })

        var imdbOnly = lookup
        imdbOnly.tmdbId = nil
        let fromIntroDB = await IntroDatabase.fetch(imdbOnly, userAgent: "KinemaTests/1.0")
        if case .found(let more) = fromIntroDB { XCTAssertFalse(more.isEmpty) } else { XCTFail("\(fromIntroDB)") }
    }
}
