import XCTest
@testable import KinemaCore

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let info = ClientInfo(version: "1.0.0", deviceName: "Test", deviceId: "device-1")

final class ModelTests: XCTestCase {
    func testDecodesMoviesFromAServer() throws {
        let result = try JSONDecoder().decode(QueryResult<Item>.self, from: fixture("movies"))
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.totalRecordCount, 11)
        let movie = result.items[0]
        XCTAssertEqual(movie.kind, .movie)
        XCTAssertEqual(movie.name, "The Boy in the Plastic Bubble")
        XCTAssertEqual(movie.productionYear, 1976)
        XCTAssertTrue(movie.isPlayable)
        XCTAssertNotNil(movie.image(.primary))
        XCTAssertEqual(movie.logoImage?.type, .logo)
        XCTAssertEqual(movie.backdropImage?.index, 0)
        XCTAssertNotNil(movie.image(.primary)?.blurHash)
        XCTAssertFalse(movie.cast.isEmpty)
        XCTAssertNotNil(movie.progress)
        let source = try XCTUnwrap(movie.primarySource)
        XCTAssertEqual(source.fileExtension, "mp4")
        XCTAssertEqual(source.videoStream?.codec, "h264")
        XCTAssertTrue(StreamResolver.directPlayIsSafe(source))
        XCTAssertTrue(StreamResolver.offlinePlayable(source))
        let trickplay = try XCTUnwrap(movie.trickplayInfo(mediaSourceId: source.id))
        XCTAssertEqual(trickplay.width, 320)
        let spot = try XCTUnwrap(trickplay.locate(125))
        XCTAssertEqual(spot.tile, 0)
        XCTAssertEqual(spot.column, 2)
        XCTAssertEqual(spot.row, 1)
    }

    func testDecodesEpisodesWithTheirSeriesArt() throws {
        let result = try JSONDecoder().decode(QueryResult<Item>.self, from: fixture("episodes"))
        let episode = try XCTUnwrap(result.items.first)
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(episode.episodeLabel, "S1 E1")
        XCTAssertEqual(episode.posterImage?.itemId, episode.seriesId)
        XCTAssertEqual(episode.landscapeImage?.itemId, episode.id)
        XCTAssertEqual(Format.episodeLong(episode), "Season 1 · Episode 1")
    }

    func testDecodesLibraries() throws {
        let result = try JSONDecoder().decode(QueryResult<Item>.self, from: fixture("views"))
        XCTAssertEqual(result.items.map(\.collectionType), ["movies", "music", "playlists", "tvshows"])
    }

    func testToleratesOddValues() throws {
        let json = #"{"Id":"1","Name":"X","ProductionYear":"1999","CommunityRating":"7.5","RunTimeTicks":12.0,"UserData":{"Played":"yes","PlaybackPositionTicks":50},"Genres":null}"#
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(item.productionYear, 1999)
        XCTAssertEqual(item.communityRating, 7.5)
        XCTAssertEqual(item.runTimeTicks, 12)
        XCTAssertEqual(item.userData?.played, false)
        XCTAssertEqual(item.userData?.playbackPositionTicks, 50)
        XCTAssertNil(item.genres)
    }

    func testRoundTripsForOfflineStorage() throws {
        let result = try JSONDecoder().decode(QueryResult<Item>.self, from: fixture("movies"))
        let movie = result.items[0]
        let again = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(movie))
        XCTAssertEqual(again, movie)
    }

    func testParsesJellyfinDates() {
        XCTAssertNotNil(JellyfinDate.parse("2026-10-25T14:24:30.8296621Z"))
        XCTAssertNotNil(JellyfinDate.parse("2011-03-28T00:00:00.0000000Z"))
        XCTAssertNotNil(JellyfinDate.parse("2011-03-28T00:00:00Z"))
        XCTAssertNotNil(JellyfinDate.parse("2011-03-28"))
        XCTAssertNil(JellyfinDate.parse(""))
    }
}

final class ClientTests: XCTestCase {
    func testBuildsAddressesForWhatWasTyped() {
        XCTAssertEqual(JellyfinClient.candidates("jelly.example.com").map(\.absoluteString), [
            "https://jelly.example.com", "http://jelly.example.com", "http://jelly.example.com:8096",
        ])
        XCTAssertEqual(JellyfinClient.candidates("https://example.com/jellyfin/web/index.html#/home").map(\.absoluteString), ["https://example.com/jellyfin"])
        XCTAssertEqual(JellyfinClient.candidates("192.168.1.5:8096/").map(\.absoluteString), ["https://192.168.1.5:8096", "http://192.168.1.5:8096"])
        XCTAssertTrue(JellyfinClient.candidates("  ").isEmpty)
    }

    func testBuildsURLsUnderABasePath() {
        let client = JellyfinClient(baseURL: URL(string: "https://example.com/jellyfin/")!, info: info, token: "abc", userId: "u1")
        XCTAssertEqual(client.url("/Items", [URLQueryItem(name: "searchTerm", value: "a+b & c")])?.absoluteString,
                       "https://example.com/jellyfin/Items?searchTerm=a%2Bb%20%26%20c")
        let image = client.imageURL(ImageRef(itemId: "i1", type: .backdrop, tag: "t", index: 0), maxWidth: 1280)
        XCTAssertEqual(image?.absoluteString, "https://example.com/jellyfin/Items/i1/Images/Backdrop/0?maxWidth=1280&quality=90&tag=t")
        XCTAssertEqual(client.absolute("/videos/x/master.m3u8?a=1")?.absoluteString, "https://example.com/jellyfin/videos/x/master.m3u8?a=1")
        XCTAssertEqual(client.subtitleURL(itemId: "i", mediaSourceId: "m", index: 3)?.absoluteString,
                       "https://example.com/jellyfin/Videos/i/m/Subtitles/3/0/Stream.srt?ApiKey=abc")
    }

    func testSendsTheAuthorizationHeader() {
        let client = JellyfinClient(baseURL: URL(string: "https://e.com")!, info: info, token: "tok")
        XCTAssertEqual(client.authorization, "MediaBrowser Client=\"Kinema\", Device=\"Test\", DeviceId=\"device-1\", Version=\"1.0.0\", Token=\"tok\"")
    }

    func testBuildsItemQueries() {
        var query = ItemQuery(parentId: "p", includeTypes: ["Movie", "Series"])
        query.sortBy = ["SortName"]
        query.genres = ["Drama", "Comedy"]
        query.limit = 50
        let items = Dictionary(uniqueKeysWithValues: query.queryItems(userId: "u").map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["includeItemTypes"], "Movie,Series")
        XCTAssertEqual(items["sortOrder"], "Ascending")
        XCTAssertEqual(items["genres"], "Drama|Comedy")
        XCTAssertEqual(items["userId"], "u")
        XCTAssertEqual(items["limit"], "50")
        XCTAssertNil(items["searchTerm"])
    }
}

final class PlaybackTests: XCTestCase {
    func testDeviceProfileSpeaksJellyfin() throws {
        let profile = DeviceProfileBuilder.build(DeviceCapabilities(hevc: true, av1: false, dolbyVision: true), maxBitrate: 40_000_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(json["MaxStreamingBitrate"] as? Int, 40_000_000)
        let transcoding = try XCTUnwrap((json["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(transcoding["Protocol"] as? String, "hls")
        XCTAssertEqual(transcoding["Container"] as? String, "mp4")
        XCTAssertEqual(transcoding["VideoCodec"] as? String, "h264,hevc")
        let direct = try XCTUnwrap((json["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(direct["VideoCodec"] as? String, "h264,hevc")
        let subtitles = try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])
        XCTAssertTrue(subtitles.contains { $0["Format"] as? String == "pgssub" && $0["Method"] as? String == "Encode" })
        XCTAssertTrue(subtitles.contains { $0["Format"] as? String == "srt" && $0["Method"] as? String == "External" })
        let noDirect = DeviceProfileBuilder.build(DeviceCapabilities(), maxBitrate: 1, allowDirectPlay: false)
        XCTAssertTrue(noDirect.directPlayProfiles.isEmpty)
    }

    func testResolvesARemuxedStream() throws {
        let response = try JSONDecoder().decode(PlaybackInfoResponse.self, from: fixture("playbackinfo"))
        let client = JellyfinClient(baseURL: URL(string: "https://demo.example/stable")!, info: info, token: "TOKEN", userId: "u")
        let stream = try XCTUnwrap(StreamResolver.resolve(response, itemId: "f717d85df782816c2ab75423e32f740b", sourceId: nil, client: client))
        XCTAssertEqual(stream.method, .transcode)
        XCTAssertTrue(stream.isHLS)
        XCTAssertTrue(stream.isRemux)
        XCTAssertEqual(stream.methodLabel, "Remux")
        XCTAssertEqual(stream.transcodeReasons, ["ContainerNotSupported"])
        XCTAssertTrue(stream.url.absoluteString.hasPrefix("https://demo.example/stable/videos/"))
        XCTAssertEqual(stream.playSessionId, response.playSessionId)
    }

    func testResolvesDirectPlay() throws {
        var source = MediaSource(id: "m1", container: "mov,mp4,m4a,3gp,3g2,mj2", mediaStreams: [MediaStream(index: 0, type: .video, codec: "h264")])
        source.path = "/media/movie.mp4"
        source.eTag = "e"
        let response = PlaybackInfoResponse(mediaSources: [source], playSessionId: "s")
        let client = JellyfinClient(baseURL: URL(string: "https://x.example")!, info: info, token: "k")
        let stream = try XCTUnwrap(StreamResolver.resolve(response, itemId: "item", sourceId: "m1", client: client))
        XCTAssertEqual(stream.method, .directPlay)
        XCTAssertEqual(stream.url.absoluteString, "https://x.example/Videos/item/stream.mp4?static=true&mediaSourceId=m1&deviceId=device-1&ApiKey=k&Tag=e")
    }

    func testKeepsUntaggedHEVCAwayFromDirectPlay() {
        var hev1 = MediaStream(index: 0, type: .video, codec: "hevc")
        hev1.codecTag = "hev1"
        XCTAssertFalse(StreamResolver.directPlayIsSafe(MediaSource(id: "a", container: "mp4", mediaStreams: [hev1])))
        hev1.codecTag = "hvc1"
        XCTAssertTrue(StreamResolver.directPlayIsSafe(MediaSource(id: "a", container: "mp4", mediaStreams: [hev1])))
        XCTAssertFalse(StreamResolver.offlinePlayable(MediaSource(id: "a", container: "mkv", mediaStreams: [hev1])))
    }

    func testChoosesTracks() {
        let source = MediaSource(id: "m", container: "mkv", mediaStreams: [
            MediaStream(index: 0, type: .video, codec: "h264"),
            MediaStream(index: 1, type: .audio, codec: "eac3", language: "eng", isDefault: true),
            MediaStream(index: 2, type: .audio, codec: "aac", language: "ger"),
            MediaStream(index: 3, type: .subtitle, codec: "subrip", language: "eng", isForced: true),
            MediaStream(index: 4, type: .subtitle, codec: "subrip", language: "eng"),
            MediaStream(index: 5, type: .subtitle, codec: "subrip", language: "deu"),
        ])
        XCTAssertEqual(StreamResolver.audioIndex(source, language: "deu"), 2)
        XCTAssertEqual(StreamResolver.audioIndex(source, language: "fra"), 1)
        XCTAssertEqual(StreamResolver.audioIndex(source, language: nil), 1)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .always, language: "ger", audioLanguage: "eng"), 5)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .onlyForced, language: "eng", audioLanguage: "eng"), 3)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .smart, language: "deu", audioLanguage: "eng"), 5)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .smart, language: "eng", audioLanguage: "eng"), 3)
        XCTAssertNil(StreamResolver.subtitleIndex(source, mode: .none, language: "eng", audioLanguage: "eng"))
        XCTAssertTrue(Languages.same("ger", "de"))
        XCTAssertTrue(Languages.same("pt-BR", "por"))
        XCTAssertFalse(Languages.same("und", "und"))
    }

    func testDescribesTranscodeReasons() {
        XCTAssertEqual(StreamResolver.transcodeReasons("/a?b=1&TranscodeReasons=AudioCodecNotSupported%2CContainerNotSupported"),
                       ["AudioCodecNotSupported", "ContainerNotSupported"])
        XCTAssertEqual(StreamResolver.describe(reason: "AudioCodecNotSupported"), "Audio codec not supported")
    }
}

final class SubtitleTests: XCTestCase {
    func testReadsSubRip() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>Hello</i> there,
        friend.

        2
        00:00:03,000 --> 00:00:05,000
        {\\an8}Overlapping
        3
        00:00:06,000 --> 00:00:07,000
        Tom &amp; Jerry
        """
        let track = SubtitleTrack.parse(srt)
        XCTAssertEqual(track.cues.count, 3)
        XCTAssertEqual(track.cues[0].text, "Hello there,\nfriend.")
        XCTAssertEqual(track.cues[0].runs.first, SubtitleRun(text: "Hello", italic: true))
        XCTAssertTrue(track.cues[1].top)
        XCTAssertEqual(track.cues[2].text, "Tom & Jerry")
        XCTAssertEqual(track.cues(at: 3.2).map(\.text), ["Hello there,\nfriend.", "Overlapping"])
        XCTAssertEqual(track.cues(at: 5.5).count, 0)
        XCTAssertEqual(track.cues(at: 0.5).count, 0)
        XCTAssertEqual(track.nextStart(after: 4), 6)
    }

    func testReadsWebVTT() {
        let vtt = """
        WEBVTT

        NOTE a comment

        00:01.000 --> 00:02.000 line:0
        <v Bob>Up top</v>

        intro
        00:00:02.500 --> 00:00:04.000
        <c.yellow>Below</c>
        """
        let track = SubtitleTrack.parse(vtt)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertTrue(track.cues[0].top)
        XCTAssertEqual(track.cues[0].text, "Up top")
        XCTAssertEqual(track.cues[1].text, "Below")
        XCTAssertEqual(track.cues[1].start, 2.5)
    }

    func testReadsSubStationAlpha() {
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\i1}Hi{\\i0}, you\\Nthere
        Dialogue: 0,0:00:03.00,0:00:04.00,Sign,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\an8}Commas, are, fine
        """
        let track = SubtitleTrack.parse(ass)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].text, "Hi, you\nthere")
        XCTAssertEqual(track.cues[0].runs.first?.italic, true)
        XCTAssertEqual(track.cues[1].text, "Commas, are, fine")
        XCTAssertTrue(track.cues[1].top)
    }

    func testDecodesLegacyEncodings() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(SubtitleParser.decodeText(latin1), "café")
        XCTAssertEqual(SubtitleParser.decodeText(Data([0xEF, 0xBB, 0xBF, 0x41])), "A")
    }
}

final class FormatTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Format.runtime(8040), "2h 14m")
        XCTAssertEqual(Format.runtime(2880), "48m")
        XCTAssertEqual(Format.runtime(3600), "1h")
        XCTAssertEqual(Format.clock(3723), "1:02:03")
        XCTAssertEqual(Format.clock(123.9), "2:03")
        XCTAssertEqual(Format.fileSize(1_234_000_000), "1.2 GB")
        XCTAssertEqual(Format.bitrate(12_400_000), "12.4 Mbps")
        XCTAssertEqual(Format.resolution(width: 3840, height: 1600), "4K")
        XCTAssertEqual(Format.resolution(width: 1920, height: 800), "1080p")
        XCTAssertEqual(Format.resolution(width: 640, height: 480), "480p")
        XCTAssertEqual(Format.dynamicRange("DOVIWithHDR10"), "Dolby Vision")
        XCTAssertEqual(Format.dynamicRange("HDR10Plus"), "HDR10+")
        XCTAssertNil(Format.dynamicRange("SDR"))
        XCTAssertEqual(Format.audioFormat(codec: "truehd", profile: "TrueHD + Dolby Atmos", spatial: "DolbyAtmos"), "TrueHD Atmos")
        XCTAssertEqual(Format.audioFormat(codec: "dts", profile: "DTS-HD MA", spatial: nil), "DTS-HD MA")
        XCTAssertEqual(Format.channels(6), "5.1")
        XCTAssertEqual(Format.channels(2, layout: "stereo"), "Stereo")
        XCTAssertEqual(Format.initials("The Boy in the Plastic Bubble"), "TB")
        XCTAssertEqual(Format.greeting(9), "Good morning")
        XCTAssertEqual(Format.count(1, "episode"), "1 episode")
        XCTAssertEqual(Format.count(1200, "movie"), "1,200 movies")
    }
}

final class SettingsTests: XCTestCase {
    func testFallsBackToDefaults() throws {
        let json = #"{"theme":"light","homeSections":["hero","somethingNew","nextUp"],"skipBack":"oops","holdSpeed":3}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.homeSections, [.hero, .nextUp])
        XCTAssertEqual(settings.skipBack, 10)
        XCTAssertEqual(settings.holdSpeed, 3)
        XCTAssertEqual(settings.subtitleMode, .serverDefault)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
        XCTAssertEqual(Settings().maxBitrate(metered: false), StreamingQuality.maximum)
        XCTAssertEqual(Settings().maxBitrate(metered: true), 8_000_000)
    }
}

final class BlurHashTests: XCTestCase {
    func testDecodesAHash() throws {
        let pixels = try XCTUnwrap(BlurHash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 8, height: 6))
        XCTAssertEqual(pixels.count, 8 * 6 * 4)
        XCTAssertEqual(pixels[3], 255)
        XCTAssertNil(BlurHash.decode("bad", width: 4, height: 4))
        XCTAssertNotNil(BlurHash.averageColor("LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
    }
}

final class VersionTests: XCTestCase {
    func testComparesVersions() {
        XCTAssertTrue(Versions.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Versions.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertFalse(Versions.isNewer("1.0.0-beta", than: "1.0.0"))
    }
}

final class VidHubSettingsTests: XCTestCase {
    func testPrefersTheChosenKindOfSubtitles() {
        var external = MediaStream(index: 9, type: .subtitle, codec: "subrip", language: "eng", isExternal: true)
        external.isTextSubtitleStream = true
        let source = MediaSource(id: "m", container: "mkv", mediaStreams: [
            MediaStream(index: 0, type: .video, codec: "h264"),
            MediaStream(index: 1, type: .audio, codec: "aac", language: "eng"),
            MediaStream(index: 2, type: .subtitle, codec: "subrip", language: "eng"),
            external,
        ])
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .always, language: "eng", audioLanguage: "eng"), 2)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .always, language: "eng", audioLanguage: "eng", prefer: .external), 9)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .always, language: "eng", audioLanguage: "eng", prefer: .embedded), 2)
        XCTAssertEqual(StreamResolver.subtitleIndex(source, mode: .always, language: "eng", audioLanguage: "eng", embedded: false), 9)
    }

    func testTurnsMarkersIntoSegments() {
        let markers = SkipMarkers(introEnd: 90, creditsFromEnd: 120)
        let segments = markers.segments(duration: 2700)
        XCTAssertEqual(segments.map(\.type), ["Intro", "Outro"])
        XCTAssertEqual(segments[0].end, 90, accuracy: 0.01)
        XCTAssertEqual(segments[1].start, 2580, accuracy: 0.01)
        XCTAssertTrue(SkipMarkers().segments(duration: 100).isEmpty)
        XCTAssertTrue(SkipMarkers(creditsFromEnd: 500).segments(duration: 300).isEmpty)
    }

    func testReadsNewSettingsAndBuffers() throws {
        let json = #"{"maxCacheMB":500,"rememberSpeed":true,"lastSpeed":1.5,"subtitleSource":"external","seekSensitivity":"high","concurrentDownloads":3}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.startSpeed, 1.5)
        XCTAssertEqual(settings.subtitleSource, .external)
        XCTAssertEqual(settings.seekSensitivity.factor, 2)
        XCTAssertEqual(settings.concurrentDownloads, 3)
        XCTAssertEqual(settings.forwardBuffer(bitrate: 20_000_000), 200, accuracy: 0.01)
        XCTAssertEqual(Settings().forwardBuffer(bitrate: 20_000_000), 0)
        XCTAssertTrue(Settings().preloadNextEpisode)
    }

    func testReadsItemCounts() throws {
        let counts = try JSONDecoder().decode(ItemCounts.self, from: Data(#"{"MovieCount":11,"SeriesCount":1,"EpisodeCount":"7"}"#.utf8))
        XCTAssertEqual(counts.movies, 11)
        XCTAssertEqual(counts.episodes, 7)
        XCTAssertEqual(counts.collections, 0)
    }

    func testLooksEpisodesUpByTheShowsIds() throws {
        var episode = Item(id: "e1", name: "Pilot", type: "Episode")
        episode.parentIndexNumber = 1
        episode.indexNumber = 2
        episode.runTimeTicks = 28_000_000_000
        XCTAssertNil(IntroDatabase.Lookup(item: episode, seriesIds: nil), "an episode needs its show's ids")

        let tmdb = try XCTUnwrap(IntroDatabase.Lookup(item: episode, seriesIds: ["Tmdb": "1396", "Tvdb": "81189", "Imdb": "tt0903747"]))
        let url = try XCTUnwrap(tmdb.theIntroDBURL()).absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=2"), url)
        XCTAssertTrue(url.hasSuffix("duration_ms=2800000"), url)
        XCTAssertEqual(tmdb.introDBURL()?.absoluteString, "https://api.introdb.app/segments?imdb_id=tt0903747&season=1&episode=2")

        // With TVDB's own id for the episode, TVDB pins it whatever the numbering.
        episode.providerIds = ["Tvdb": "349232"]
        let tvdb = try XCTUnwrap(IntroDatabase.Lookup(item: episode, seriesIds: ["Tmdb": "1396", "Tvdb": "81189"]))
        XCTAssertTrue(try XCTUnwrap(tvdb.theIntroDBURL()).absoluteString.contains("tvdb_id=81189&tvdb_episode_id=349232&season=1&episode=2"))
        XCTAssertNil(tvdb.introDBURL())

        var movie = Item(id: "m1", name: "Inception", type: "Movie")
        movie.providerIds = ["Tmdb": "27205", "Imdb": "tt1375666"]
        let film = try XCTUnwrap(IntroDatabase.Lookup(item: movie, seriesIds: nil))
        XCTAssertEqual(film.theIntroDBURL()?.absoluteString, "https://api.theintrodb.org/v4/media?tmdb_id=27205")
        XCTAssertNil(IntroDatabase.Lookup(item: Item(id: "m2", name: "No ids", type: "Movie"), seriesIds: nil))
    }

    func testReadsBothIntroDatabases() throws {
        let theIntroDB = IntroDatabase.parseTheIntroDB(Data(#"{"tvdb_id":81189,"type":"tv","season":1,"episode":2,"intro":[{"start_ms":314568,"end_ms":330969}],"credits":[{"start_ms":2843000,"end_ms":null}],"recap":[{"start_ms":null,"end_ms":45000}]}"#.utf8))
        XCTAssertEqual(theIntroDB.map(\.type), ["Intro", "Recap", "Outro"])
        let segments = IntroDatabase.segments(theIntroDB, duration: 2900)
        XCTAssertEqual(segments.map(\.type), ["Recap", "Intro", "Outro"])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[1].start, 314.568, accuracy: 0.001)
        XCTAssertEqual(segments[2].end, 2900, accuracy: 0.001)
        // Timed on a longer cut: the credits would start after this one ends.
        XCTAssertEqual(IntroDatabase.segments(theIntroDB, duration: 2000).map(\.type), ["Recap", "Intro"])

        let introDB = IntroDatabase.parseIntroDB(Data(#"{"imdb_id":"tt0944947","media_type":"tv","season":1,"episode":1,"intro":{"start_sec":437,"end_sec":531,"start_ms":437000,"end_ms":531000},"recap":null,"outro":{"start_sec":3631.5,"end_sec":3699.5},"post_credits":null}"#.utf8))
        XCTAssertEqual(introDB, [
            IntroDatabase.Found(type: "Intro", startMs: 437_000, endMs: 531_000, source: "IntroDB"),
            IntroDatabase.Found(type: "Outro", startMs: 3_631_500, endMs: 3_699_500, source: "IntroDB"),
        ])
        XCTAssertTrue(IntroDatabase.parseTheIntroDB(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(IntroDatabase.parseIntroDB(Data()).isEmpty)
    }

    func testPrefersTheServersSegmentsThenMarksThenTheDatabase() {
        let server = [MediaSegment(id: "s", type: "Intro", start: 60, end: 90)]
        let marked = [MediaSegment(id: "marker-intro", type: "Intro", start: 0, end: 80), MediaSegment(id: "marker-outro", type: "Outro", start: 2500, end: 2600)]
        let online = [MediaSegment(id: "online-outro-0", type: "Outro", start: 2400, end: 2600), MediaSegment(id: "online-recap-1", type: "Recap", start: 0, end: 40)]
        let merged = IntroDatabase.merge(server: server, marked: marked, online: online)
        XCTAssertEqual(merged.map(\.id), ["online-recap-1", "s", "marker-outro"])
    }
}
