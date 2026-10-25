import Foundation

// Jellyfin's data, as the server sends it (PascalCase JSON). Every field is
// read leniently: a value that is missing, null or of an unexpected type
// becomes nil instead of failing the whole response, because servers differ
// between versions and plugins add their own surprises.

extension KeyedDecodingContainer {
    /** The value at [key], or nil when it is missing, null or not of the expected type. */
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /** A number that may arrive as an integer, a decimal or a string. */
    func number(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func int(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        return number(key).flatMap { $0.isFinite ? Int($0) : nil }
    }

    func int64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        return number(key).flatMap { $0.isFinite ? Int64($0) : nil }
    }
}

/** One second in Jellyfin's ticks (100 ns). */
let ticksPerSecond: Int64 = 10_000_000

enum Ticks {
    static func seconds(_ ticks: Int64?) -> Double {
        Double(ticks ?? 0) / Double(ticksPerSecond)
    }

    static func from(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * Double(ticksPerSecond)).rounded())
    }
}

// ------------------------------------------------------------------ items --

/** What kind of thing an item is, from Jellyfin's `Type`. */
enum ItemKind: String, Codable, Hashable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case person = "Person"
    case video = "Video"
    case musicVideo = "MusicVideo"
    case trailer = "Trailer"
    case collectionFolder = "CollectionFolder"
    case userView = "UserView"
    case folder = "Folder"
    case playlist = "Playlist"
    case genre = "Genre"
    case studio = "Studio"
    case tvChannel = "TvChannel"
    case audio = "Audio"
    case musicAlbum = "MusicAlbum"
    case other = ""

    init(type: String?) {
        self = ItemKind(rawValue: type ?? "") ?? .other
    }

    /** Things that play by themselves, as opposed to things that hold other things. */
    var isPlayable: Bool {
        switch self {
        case .movie, .episode, .video, .musicVideo, .trailer: return true
        default: return false
        }
    }
}

/** The image kinds Kinema shows. */
enum ImageType: String, Codable, Hashable, CaseIterable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
    case banner = "Banner"
    case chapter = "Chapter"
}

/** Where one image of one item is, with the tag that changes whenever the image does. */
struct ImageRef: Hashable, Codable {
    var itemId: String
    var type: ImageType
    var tag: String?
    var index: Int?
    var blurHash: String?

    init(itemId: String, type: ImageType, tag: String?, index: Int? = nil, blurHash: String? = nil) {
        self.itemId = itemId
        self.type = type
        self.tag = tag
        self.index = index
        self.blurHash = blurHash
    }
}

struct NameIdPair: Codable, Hashable {
    var name: String?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name", id = "Id"
    }
}

struct ExternalUrl: Codable, Hashable {
    var name: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name", url = "Url"
    }
}

/** Someone in the cast or crew. */
struct Person: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var role: String?
    var type: String?
    var primaryImageTag: String?
    var imageBlurHashes: [String: [String: String]]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", role = "Role", type = "Type", primaryImageTag = "PrimaryImageTag", imageBlurHashes = "ImageBlurHashes"
    }

    init(id: String, name: String, role: String? = nil, type: String? = nil, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.type = type
        self.primaryImageTag = primaryImageTag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        role = c.lenient(String.self, .role)
        type = c.lenient(String.self, .type)
        primaryImageTag = c.lenient(String.self, .primaryImageTag)
        imageBlurHashes = c.lenient([String: [String: String]].self, .imageBlurHashes)
    }

    var image: ImageRef? {
        guard let tag = primaryImageTag else { return nil }
        return ImageRef(itemId: id, type: .primary, tag: tag, blurHash: imageBlurHashes?["Primary"]?[tag])
    }

    var isCast: Bool { type == "Actor" || type == "GuestStar" }
}

/** What this user has done with an item: watched, how far, favourite. */
struct UserData: Codable, Hashable {
    var playedPercentage: Double?
    var unplayedItemCount: Int?
    var playbackPositionTicks: Int64
    var playCount: Int?
    var isFavorite: Bool
    var played: Bool
    var lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playedPercentage = "PlayedPercentage", unplayedItemCount = "UnplayedItemCount"
        case playbackPositionTicks = "PlaybackPositionTicks", playCount = "PlayCount"
        case isFavorite = "IsFavorite", played = "Played", lastPlayedDate = "LastPlayedDate"
    }

    init(playbackPositionTicks: Int64 = 0, isFavorite: Bool = false, played: Bool = false) {
        self.playbackPositionTicks = playbackPositionTicks
        self.isFavorite = isFavorite
        self.played = played
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playedPercentage = c.number(.playedPercentage)
        unplayedItemCount = c.int(.unplayedItemCount)
        playbackPositionTicks = c.int64(.playbackPositionTicks) ?? 0
        playCount = c.int(.playCount)
        isFavorite = c.lenient(Bool.self, .isFavorite) ?? false
        played = c.lenient(Bool.self, .played) ?? false
        lastPlayedDate = c.lenient(String.self, .lastPlayedDate)
    }
}

struct Chapter: Codable, Hashable {
    var startPositionTicks: Int64
    var name: String?
    var imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks", name = "Name", imageTag = "ImageTag"
    }

    init(startPositionTicks: Int64, name: String?, imageTag: String? = nil) {
        self.startPositionTicks = startPositionTicks
        self.name = name
        self.imageTag = imageTag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startPositionTicks = c.int64(.startPositionTicks) ?? 0
        name = c.lenient(String.self, .name)
        imageTag = c.lenient(String.self, .imageTag)
    }

    var start: Double { Ticks.seconds(startPositionTicks) }
}

/** The sheet of scrubbing thumbnails the server made for a video (Jellyfin 10.9 and later). */
struct TrickplayInfo: Codable, Hashable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    /** Milliseconds between thumbnails. */
    var interval: Int
    var bandwidth: Int?

    enum CodingKeys: String, CodingKey {
        case width = "Width", height = "Height", tileWidth = "TileWidth", tileHeight = "TileHeight"
        case thumbnailCount = "ThumbnailCount", interval = "Interval", bandwidth = "Bandwidth"
    }

    init(width: Int, height: Int, tileWidth: Int, tileHeight: Int, thumbnailCount: Int, interval: Int, bandwidth: Int? = nil) {
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.thumbnailCount = thumbnailCount
        self.interval = interval
        self.bandwidth = bandwidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = c.int(.width) ?? 0
        height = c.int(.height) ?? 0
        tileWidth = c.int(.tileWidth) ?? 1
        tileHeight = c.int(.tileHeight) ?? 1
        thumbnailCount = c.int(.thumbnailCount) ?? 0
        interval = c.int(.interval) ?? 10_000
        bandwidth = c.int(.bandwidth)
    }

    /** Thumbnails in one tile image. */
    var perTile: Int { max(1, tileWidth * tileHeight) }

    /** Which tile image, and where in it, shows the moment [seconds]. */
    func locate(_ seconds: Double) -> (tile: Int, column: Int, row: Int)? {
        guard thumbnailCount > 0, interval > 0 else { return nil }
        let index = min(thumbnailCount - 1, max(0, Int(seconds * 1000) / interval))
        let inTile = index % perTile
        return (index / perTile, inTile % max(1, tileWidth), inTile / max(1, tileWidth))
    }
}

/** A movie, show, season, episode, collection, library… anything the server lists. */
struct Item: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var originalTitle: String?
    var serverId: String?
    var type: String?
    var collectionType: String?
    var mediaType: String?
    var isFolder: Bool?

    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var studios: [NameIdPair]?
    var people: [Person]?
    var providerIds: [String: String]?
    var externalUrls: [ExternalUrl]?
    var remoteTrailers: [ExternalUrl]?
    var tags: [String]?

    var productionYear: Int?
    var premiereDate: String?
    var endDate: String?
    var dateCreated: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var status: String?

    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var indexNumberEnd: Int?
    var parentIndexNumber: Int?
    var parentId: String?

    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var imageBlurHashes: [String: [String: String]]?
    var primaryImageAspectRatio: Double?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentPrimaryImageItemId: String?
    var parentPrimaryImageTag: String?
    var seriesPrimaryImageTag: String?
    var seriesThumbImageTag: String?

    var userData: UserData?
    var mediaSources: [MediaSource]?
    var mediaStreams: [MediaStream]?
    var chapters: [Chapter]?
    var trickplay: [String: [String: TrickplayInfo]]?

    var childCount: Int?
    var recursiveItemCount: Int?
    var container: String?
    var videoType: String?
    var locationType: String?
    var width: Int?
    var height: Int?
    var canDownload: Bool?
    var localTrailerCount: Int?
    var specialFeatureCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", originalTitle = "OriginalTitle", serverId = "ServerId", type = "Type"
        case collectionType = "CollectionType", mediaType = "MediaType", isFolder = "IsFolder"
        case overview = "Overview", taglines = "Taglines", genres = "Genres", studios = "Studios", people = "People"
        case providerIds = "ProviderIds", externalUrls = "ExternalUrls", remoteTrailers = "RemoteTrailers", tags = "Tags"
        case productionYear = "ProductionYear", premiereDate = "PremiereDate", endDate = "EndDate", dateCreated = "DateCreated"
        case officialRating = "OfficialRating", communityRating = "CommunityRating", criticRating = "CriticRating"
        case runTimeTicks = "RunTimeTicks", status = "Status"
        case seriesId = "SeriesId", seriesName = "SeriesName", seasonId = "SeasonId", seasonName = "SeasonName"
        case indexNumber = "IndexNumber", indexNumberEnd = "IndexNumberEnd", parentIndexNumber = "ParentIndexNumber", parentId = "ParentId"
        case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags", imageBlurHashes = "ImageBlurHashes"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case parentBackdropItemId = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemId = "ParentLogoItemId", parentLogoImageTag = "ParentLogoImageTag"
        case parentThumbItemId = "ParentThumbItemId", parentThumbImageTag = "ParentThumbImageTag"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId", parentPrimaryImageTag = "ParentPrimaryImageTag"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag", seriesThumbImageTag = "SeriesThumbImageTag"
        case userData = "UserData", mediaSources = "MediaSources", mediaStreams = "MediaStreams", chapters = "Chapters", trickplay = "Trickplay"
        case childCount = "ChildCount", recursiveItemCount = "RecursiveItemCount", container = "Container", videoType = "VideoType"
        case locationType = "LocationType", width = "Width", height = "Height", canDownload = "CanDownload"
        case localTrailerCount = "LocalTrailerCount", specialFeatureCount = "SpecialFeatureCount"
    }

    init(id: String, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        originalTitle = c.lenient(String.self, .originalTitle)
        serverId = c.lenient(String.self, .serverId)
        type = c.lenient(String.self, .type)
        collectionType = c.lenient(String.self, .collectionType)
        mediaType = c.lenient(String.self, .mediaType)
        isFolder = c.lenient(Bool.self, .isFolder)
        overview = c.lenient(String.self, .overview)
        taglines = c.lenient([String].self, .taglines)
        genres = c.lenient([String].self, .genres)
        studios = c.lenient([NameIdPair].self, .studios)
        people = c.lenient([Person].self, .people)
        providerIds = c.lenient([String: String].self, .providerIds)
        externalUrls = c.lenient([ExternalUrl].self, .externalUrls)
        remoteTrailers = c.lenient([ExternalUrl].self, .remoteTrailers)
        tags = c.lenient([String].self, .tags)
        productionYear = c.int(.productionYear)
        premiereDate = c.lenient(String.self, .premiereDate)
        endDate = c.lenient(String.self, .endDate)
        dateCreated = c.lenient(String.self, .dateCreated)
        officialRating = c.lenient(String.self, .officialRating)
        communityRating = c.number(.communityRating)
        criticRating = c.number(.criticRating)
        runTimeTicks = c.int64(.runTimeTicks)
        status = c.lenient(String.self, .status)
        seriesId = c.lenient(String.self, .seriesId)
        seriesName = c.lenient(String.self, .seriesName)
        seasonId = c.lenient(String.self, .seasonId)
        seasonName = c.lenient(String.self, .seasonName)
        indexNumber = c.int(.indexNumber)
        indexNumberEnd = c.int(.indexNumberEnd)
        parentIndexNumber = c.int(.parentIndexNumber)
        parentId = c.lenient(String.self, .parentId)
        imageTags = c.lenient([String: String].self, .imageTags)
        backdropImageTags = c.lenient([String].self, .backdropImageTags)
        imageBlurHashes = c.lenient([String: [String: String]].self, .imageBlurHashes)
        primaryImageAspectRatio = c.number(.primaryImageAspectRatio)
        parentBackdropItemId = c.lenient(String.self, .parentBackdropItemId)
        parentBackdropImageTags = c.lenient([String].self, .parentBackdropImageTags)
        parentLogoItemId = c.lenient(String.self, .parentLogoItemId)
        parentLogoImageTag = c.lenient(String.self, .parentLogoImageTag)
        parentThumbItemId = c.lenient(String.self, .parentThumbItemId)
        parentThumbImageTag = c.lenient(String.self, .parentThumbImageTag)
        parentPrimaryImageItemId = c.lenient(String.self, .parentPrimaryImageItemId)
        parentPrimaryImageTag = c.lenient(String.self, .parentPrimaryImageTag)
        seriesPrimaryImageTag = c.lenient(String.self, .seriesPrimaryImageTag)
        seriesThumbImageTag = c.lenient(String.self, .seriesThumbImageTag)
        userData = c.lenient(UserData.self, .userData)
        mediaSources = c.lenient([MediaSource].self, .mediaSources)
        mediaStreams = c.lenient([MediaStream].self, .mediaStreams)
        chapters = c.lenient([Chapter].self, .chapters)
        trickplay = c.lenient([String: [String: TrickplayInfo]].self, .trickplay)
        childCount = c.int(.childCount)
        recursiveItemCount = c.int(.recursiveItemCount)
        container = c.lenient(String.self, .container)
        videoType = c.lenient(String.self, .videoType)
        locationType = c.lenient(String.self, .locationType)
        width = c.int(.width)
        height = c.int(.height)
        canDownload = c.lenient(Bool.self, .canDownload)
        localTrailerCount = c.int(.localTrailerCount)
        specialFeatureCount = c.int(.specialFeatureCount)
    }
}

extension Item {
    var kind: ItemKind { ItemKind(type: type) }

    var isPlayable: Bool { kind.isPlayable || (mediaType == "Video" && isFolder != true) }

    var isFavorite: Bool { userData?.isFavorite ?? false }
    var isPlayed: Bool { userData?.played ?? false }

    var runtime: Double { Ticks.seconds(runTimeTicks) }
    var resumePosition: Double { Ticks.seconds(userData?.playbackPositionTicks) }

    /** How far through it is (0..1), when it has been started and not finished. */
    var progress: Double? {
        guard let data = userData, data.playbackPositionTicks > 0, !data.played else { return nil }
        if let percentage = data.playedPercentage { return min(1, max(0, percentage / 100)) }
        guard let total = runTimeTicks, total > 0 else { return nil }
        return min(1, Double(data.playbackPositionTicks) / Double(total))
    }

    /** Episodes and seasons left to watch, for a series or season. */
    var unplayedCount: Int? { userData?.unplayedItemCount }

    /** "S1 E3", or "S1 E3–4" for a double episode. */
    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        let season = parentIndexNumber.map { "S\($0)" }
        var episode = indexNumber.map { "E\($0)" }
        if let end = indexNumberEnd, let start = indexNumber, end != start { episode = "E\(start)–\(end)" }
        let parts = [season, episode].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /** The year, or the years a series ran. */
    var yearText: String? {
        guard let year = productionYear else { return nil }
        if kind == .series {
            if status == "Continuing" { return "\(year)–" }
            if let end = endDate.flatMap(JellyfinDate.parse), let endYear = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: end).year, endYear != year {
                return "\(year)–\(endYear)"
            }
        }
        return String(year)
    }

    private func blurHash(_ type: ImageType, _ tag: String?) -> String? {
        guard let tag else { return nil }
        return imageBlurHashes?[type.rawValue]?[tag]
    }

    /** The item's own image of [type], if it has one. */
    func image(_ type: ImageType) -> ImageRef? {
        if type == .backdrop {
            guard let tag = backdropImageTags?.first else { return nil }
            return ImageRef(itemId: id, type: .backdrop, tag: tag, index: 0, blurHash: blurHash(.backdrop, tag))
        }
        guard let tag = imageTags?[type.rawValue] else { return nil }
        return ImageRef(itemId: id, type: type, tag: tag, blurHash: blurHash(type, tag))
    }

    /** A portrait poster: the series' for an episode, the season's or series' for a season. */
    var posterImage: ImageRef? {
        switch kind {
        case .episode:
            if let seriesId, let tag = seriesPrimaryImageTag {
                return ImageRef(itemId: seriesId, type: .primary, tag: tag, blurHash: blurHash(.primary, tag))
            }
            return image(.primary)
        case .season:
            if let own = image(.primary) { return own }
            if let seriesId, let tag = seriesPrimaryImageTag { return ImageRef(itemId: seriesId, type: .primary, tag: tag) }
            return nil
        default:
            return image(.primary)
        }
    }

    /** The wide picture behind a page: its own backdrop, or its series'. */
    var backdropImage: ImageRef? {
        if let own = image(.backdrop) { return own }
        if let parent = parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return ImageRef(itemId: parent, type: .backdrop, tag: tag, index: 0, blurHash: blurHash(.backdrop, tag))
        }
        return nil
    }

    /**
     * A landscape picture for a wide card: an episode's own still, a movie's
     * thumb or backdrop, falling back to the series' art.
     */
    var landscapeImage: ImageRef? {
        if kind == .episode, let still = image(.primary) { return still }
        if let thumb = image(.thumb) { return thumb }
        if let parent = parentThumbItemId, let tag = parentThumbImageTag {
            return ImageRef(itemId: parent, type: .thumb, tag: tag, blurHash: blurHash(.thumb, tag))
        }
        if let seriesId, let tag = seriesThumbImageTag { return ImageRef(itemId: seriesId, type: .thumb, tag: tag) }
        if let backdrop = backdropImage { return backdrop }
        if let primary = image(.primary), (primaryImageAspectRatio ?? 0) > 1.2 { return primary }
        return nil
    }

    /** The title logo, the item's own or its series'. */
    var logoImage: ImageRef? {
        if let own = image(.logo) { return own }
        if let parent = parentLogoItemId, let tag = parentLogoImageTag {
            return ImageRef(itemId: parent, type: .logo, tag: tag)
        }
        return nil
    }

    /** The first media source, the one played unless another version is chosen. */
    var primarySource: MediaSource? { mediaSources?.first }

    /** The streams of the first source, or the item's own list. */
    var streams: [MediaStream] { primarySource?.mediaStreams ?? mediaStreams ?? [] }

    var videoStream: MediaStream? { streams.first { $0.type == .video } }

    /** The trickplay sheet with the smallest width at least [minWidth] wide, for [mediaSourceId]. */
    func trickplayInfo(mediaSourceId: String?, minWidth: Int = 240) -> TrickplayInfo? {
        guard let trickplay else { return nil }
        let sheets = (mediaSourceId.flatMap { trickplay[$0] } ?? trickplay.values.first) ?? [:]
        let sorted = sheets.values.sorted { $0.width < $1.width }
        return sorted.first { $0.width >= minWidth } ?? sorted.last
    }

    var directors: [Person] { (people ?? []).filter { $0.type == "Director" } }
    var writers: [Person] { (people ?? []).filter { $0.type == "Writer" } }
    var cast: [Person] { (people ?? []).filter(\.isCast) }

    var tmdbId: String? { providerIds?["Tmdb"] }
    var imdbId: String? { providerIds?["Imdb"] }
}

// ---------------------------------------------------------------- streams --

enum StreamType: String, Codable, Hashable {
    case video = "Video"
    case audio = "Audio"
    case subtitle = "Subtitle"
    case embeddedImage = "EmbeddedImage"
    case data = "Data"
    case lyric = "Lyric"
    case other = ""
}

/** One track inside a file: the video, an audio language, a subtitle. */
struct MediaStream: Codable, Hashable, Identifiable {
    var index: Int
    var type: StreamType
    var codec: String?
    var codecTag: String?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool
    var isForced: Bool
    var isExternal: Bool
    var isHearingImpaired: Bool
    var isTextSubtitleStream: Bool?
    var supportsExternalStream: Bool?
    var deliveryMethod: String?
    var deliveryUrl: String?
    var isExternalUrl: Bool?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var bitDepth: Int?
    var averageFrameRate: Double?
    var realFrameRate: Double?
    var profile: String?
    var level: Double?
    var videoRange: String?
    var videoRangeType: String?
    var videoDoViTitle: String?
    var channels: Int?
    var channelLayout: String?
    var sampleRate: Int?
    var audioSpatialFormat: String?
    var aspectRatio: String?
    var isInterlaced: Bool?
    var path: String?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index = "Index", type = "Type", codec = "Codec", codecTag = "CodecTag", language = "Language", title = "Title"
        case displayTitle = "DisplayTitle", isDefault = "IsDefault", isForced = "IsForced", isExternal = "IsExternal"
        case isHearingImpaired = "IsHearingImpaired", isTextSubtitleStream = "IsTextSubtitleStream"
        case supportsExternalStream = "SupportsExternalStream", deliveryMethod = "DeliveryMethod", deliveryUrl = "DeliveryUrl"
        case isExternalUrl = "IsExternalUrl", width = "Width", height = "Height", bitRate = "BitRate", bitDepth = "BitDepth"
        case averageFrameRate = "AverageFrameRate", realFrameRate = "RealFrameRate", profile = "Profile", level = "Level"
        case videoRange = "VideoRange", videoRangeType = "VideoRangeType", videoDoViTitle = "VideoDoViTitle"
        case channels = "Channels", channelLayout = "ChannelLayout", sampleRate = "SampleRate"
        case audioSpatialFormat = "AudioSpatialFormat", aspectRatio = "AspectRatio", isInterlaced = "IsInterlaced", path = "Path"
    }

    init(index: Int, type: StreamType, codec: String? = nil, language: String? = nil, title: String? = nil, displayTitle: String? = nil, isDefault: Bool = false, isForced: Bool = false, isExternal: Bool = false) {
        self.index = index
        self.type = type
        self.codec = codec
        self.language = language
        self.title = title
        self.displayTitle = displayTitle
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.isHearingImpaired = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.int(.index) ?? -1
        type = StreamType(rawValue: c.lenient(String.self, .type) ?? "") ?? .other
        codec = c.lenient(String.self, .codec)
        codecTag = c.lenient(String.self, .codecTag)
        language = c.lenient(String.self, .language)
        title = c.lenient(String.self, .title)
        displayTitle = c.lenient(String.self, .displayTitle)
        isDefault = c.lenient(Bool.self, .isDefault) ?? false
        isForced = c.lenient(Bool.self, .isForced) ?? false
        isExternal = c.lenient(Bool.self, .isExternal) ?? false
        isHearingImpaired = c.lenient(Bool.self, .isHearingImpaired) ?? false
        isTextSubtitleStream = c.lenient(Bool.self, .isTextSubtitleStream)
        supportsExternalStream = c.lenient(Bool.self, .supportsExternalStream)
        deliveryMethod = c.lenient(String.self, .deliveryMethod)
        deliveryUrl = c.lenient(String.self, .deliveryUrl)
        isExternalUrl = c.lenient(Bool.self, .isExternalUrl)
        width = c.int(.width)
        height = c.int(.height)
        bitRate = c.int(.bitRate)
        bitDepth = c.int(.bitDepth)
        averageFrameRate = c.number(.averageFrameRate)
        realFrameRate = c.number(.realFrameRate)
        profile = c.lenient(String.self, .profile)
        level = c.number(.level)
        videoRange = c.lenient(String.self, .videoRange)
        videoRangeType = c.lenient(String.self, .videoRangeType)
        videoDoViTitle = c.lenient(String.self, .videoDoViTitle)
        channels = c.int(.channels)
        channelLayout = c.lenient(String.self, .channelLayout)
        sampleRate = c.int(.sampleRate)
        audioSpatialFormat = c.lenient(String.self, .audioSpatialFormat)
        aspectRatio = c.lenient(String.self, .aspectRatio)
        isInterlaced = c.lenient(Bool.self, .isInterlaced)
        path = c.lenient(String.self, .path)
    }

    /** Subtitles drawn as pictures (Blu-ray PGS, DVD VobSub): the server has to burn them in. */
    var isImageSubtitle: Bool {
        guard type == .subtitle else { return false }
        if let text = isTextSubtitleStream { return !text }
        let image: Set<String> = ["pgs", "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "sup", "xsub"]
        return image.contains((codec ?? "").lowercased())
    }

    /** The language's name in the phone's language, or nil for "und". */
    var languageName: String? { Format.languageName(language) }

    /** What to call this track in a menu. */
    var label: String {
        switch type {
        case .audio:
            var parts: [String] = []
            if let name = languageName { parts.append(name) }
            if let title, !title.isEmpty, title.lowercased() != languageName?.lowercased() { parts.append(title) }
            if parts.isEmpty { parts.append(displayTitle ?? "Track \(index)") }
            return parts.joined(separator: " · ")
        case .subtitle:
            var name = languageName ?? title ?? displayTitle ?? "Track \(index)"
            if let title, !title.isEmpty, languageName != nil, title.lowercased() != languageName?.lowercased() { name += " · \(title)" }
            return name
        default:
            return displayTitle ?? title ?? "Track \(index)"
        }
    }

    /** The details under the label: codec, channels, forced, SDH, external. */
    var detail: String {
        var parts: [String] = []
        switch type {
        case .audio:
            if let format = Format.audioFormat(codec: codec, profile: profile, spatial: audioSpatialFormat) { parts.append(format) }
            if let channels = Format.channels(channels, layout: channelLayout) { parts.append(channels) }
        case .subtitle:
            if isForced { parts.append("Forced") }
            if isHearingImpaired { parts.append("SDH") }
            if let codec { parts.append(Format.subtitleFormat(codec)) }
            if isExternal { parts.append("External") }
        case .video:
            if let resolution = Format.resolution(width: width, height: height) { parts.append(resolution) }
            if let codec { parts.append(codec.uppercased()) }
            if let range = Format.dynamicRange(videoRangeType) { parts.append(range) }
        default:
            break
        }
        if isDefault && type != .video { parts.append("Default") }
        return parts.joined(separator: " · ")
    }
}

/** One version of an item: a file (or stream), with its tracks. */
struct MediaSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var path: String?
    var `protocol`: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var eTag: String?
    var supportsDirectPlay: Bool
    var supportsDirectStream: Bool
    var supportsTranscoding: Bool
    var transcodingUrl: String?
    var transcodingSubProtocol: String?
    var transcodingContainer: String?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var videoType: String?
    var isRemote: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", path = "Path", `protocol` = "Protocol", container = "Container", size = "Size"
        case bitrate = "Bitrate", runTimeTicks = "RunTimeTicks", eTag = "ETag"
        case supportsDirectPlay = "SupportsDirectPlay", supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding", transcodingUrl = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol", transcodingContainer = "TranscodingContainer"
        case mediaStreams = "MediaStreams", defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex", videoType = "VideoType", isRemote = "IsRemote"
    }

    init(id: String, container: String? = nil, mediaStreams: [MediaStream] = []) {
        self.id = id
        self.container = container
        self.mediaStreams = mediaStreams
        supportsDirectPlay = true
        supportsDirectStream = true
        supportsTranscoding = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        name = c.lenient(String.self, .name)
        path = c.lenient(String.self, .path)
        `protocol` = c.lenient(String.self, .protocol)
        container = c.lenient(String.self, .container)
        size = c.int64(.size)
        bitrate = c.int(.bitrate)
        runTimeTicks = c.int64(.runTimeTicks)
        eTag = c.lenient(String.self, .eTag)
        supportsDirectPlay = c.lenient(Bool.self, .supportsDirectPlay) ?? false
        supportsDirectStream = c.lenient(Bool.self, .supportsDirectStream) ?? false
        supportsTranscoding = c.lenient(Bool.self, .supportsTranscoding) ?? false
        transcodingUrl = c.lenient(String.self, .transcodingUrl)
        transcodingSubProtocol = c.lenient(String.self, .transcodingSubProtocol)
        transcodingContainer = c.lenient(String.self, .transcodingContainer)
        mediaStreams = c.lenient([MediaStream].self, .mediaStreams)
        defaultAudioStreamIndex = c.int(.defaultAudioStreamIndex)
        defaultSubtitleStreamIndex = c.int(.defaultSubtitleStreamIndex)
        videoType = c.lenient(String.self, .videoType)
        isRemote = c.lenient(Bool.self, .isRemote)
    }

    var streams: [MediaStream] { mediaStreams ?? [] }
    var videoStream: MediaStream? { streams.first { $0.type == .video } }
    var audioStreams: [MediaStream] { streams.filter { $0.type == .audio } }
    var subtitleStreams: [MediaStream] { streams.filter { $0.type == .subtitle } }

    /** The file's container, as one extension ("mov,mp4,m4a" → the one the file ends in, or the first). */
    var fileExtension: String {
        let fromPath = path.flatMap { $0.split(separator: ".").last.map { String($0).lowercased() } }
        let options = (container ?? "").lowercased().split(separator: ",").map(String.init)
        if let fromPath, options.contains(fromPath) || options.isEmpty, fromPath.count <= 4 { return fromPath }
        return options.first ?? "mp4"
    }

    /** "4K · HEVC · Dolby Vision", to tell versions apart. */
    var summary: String {
        var parts: [String] = []
        if let video = videoStream {
            if let resolution = Format.resolution(width: video.width, height: video.height) { parts.append(resolution) }
            if let codec = video.codec { parts.append(codec.uppercased()) }
            if let range = Format.dynamicRange(video.videoRangeType) { parts.append(range) }
        }
        if let size { parts.append(Format.fileSize(size)) }
        return parts.joined(separator: " · ")
    }
}

// ---------------------------------------------------------- server / users --

struct PublicSystemInfo: Codable, Hashable {
    var serverName: String?
    var version: String?
    var id: String?
    var productName: String?
    var localAddress: String?
    var startupWizardCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName", version = "Version", id = "Id", productName = "ProductName"
        case localAddress = "LocalAddress", startupWizardCompleted = "StartupWizardCompleted"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverName = c.lenient(String.self, .serverName)
        version = c.lenient(String.self, .version)
        id = c.lenient(String.self, .id)
        productName = c.lenient(String.self, .productName)
        localAddress = c.lenient(String.self, .localAddress)
        startupWizardCompleted = c.lenient(Bool.self, .startupWizardCompleted)
    }
}

/** The user's playback preferences, as kept on the server. */
struct UserConfiguration: Codable, Hashable {
    var audioLanguagePreference: String?
    var playDefaultAudioTrack: Bool?
    var subtitleLanguagePreference: String?
    var subtitleMode: String?
    var enableNextEpisodeAutoPlay: Bool?
    var orderedViews: [String]?
    var myMediaExcludes: [String]?
    var latestItemsExcludes: [String]?
    var hidePlayedInLatest: Bool?

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference", playDefaultAudioTrack = "PlayDefaultAudioTrack"
        case subtitleLanguagePreference = "SubtitleLanguagePreference", subtitleMode = "SubtitleMode"
        case enableNextEpisodeAutoPlay = "EnableNextEpisodeAutoPlay", orderedViews = "OrderedViews"
        case myMediaExcludes = "MyMediaExcludes", latestItemsExcludes = "LatestItemsExcludes", hidePlayedInLatest = "HidePlayedInLatest"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioLanguagePreference = c.lenient(String.self, .audioLanguagePreference)
        playDefaultAudioTrack = c.lenient(Bool.self, .playDefaultAudioTrack)
        subtitleLanguagePreference = c.lenient(String.self, .subtitleLanguagePreference)
        subtitleMode = c.lenient(String.self, .subtitleMode)
        enableNextEpisodeAutoPlay = c.lenient(Bool.self, .enableNextEpisodeAutoPlay)
        orderedViews = c.lenient([String].self, .orderedViews)
        myMediaExcludes = c.lenient([String].self, .myMediaExcludes)
        latestItemsExcludes = c.lenient([String].self, .latestItemsExcludes)
        hidePlayedInLatest = c.lenient(Bool.self, .hidePlayedInLatest)
    }
}

struct UserPolicy: Codable, Hashable {
    var isAdministrator: Bool?
    var enableContentDownloading: Bool?
    var enableSubtitleManagement: Bool?
    var enableMediaPlayback: Bool?

    enum CodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator", enableContentDownloading = "EnableContentDownloading"
        case enableSubtitleManagement = "EnableSubtitleManagement", enableMediaPlayback = "EnableMediaPlayback"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isAdministrator = c.lenient(Bool.self, .isAdministrator)
        enableContentDownloading = c.lenient(Bool.self, .enableContentDownloading)
        enableSubtitleManagement = c.lenient(Bool.self, .enableSubtitleManagement)
        enableMediaPlayback = c.lenient(Bool.self, .enableMediaPlayback)
    }
}

struct UserDto: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var serverId: String?
    var primaryImageTag: String?
    var hasPassword: Bool?
    var configuration: UserConfiguration?
    var policy: UserPolicy?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", serverId = "ServerId", primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword", configuration = "Configuration", policy = "Policy"
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        serverId = c.lenient(String.self, .serverId)
        primaryImageTag = c.lenient(String.self, .primaryImageTag)
        hasPassword = c.lenient(Bool.self, .hasPassword)
        configuration = c.lenient(UserConfiguration.self, .configuration)
        policy = c.lenient(UserPolicy.self, .policy)
    }
}

struct AuthenticationResult: Decodable {
    var user: UserDto
    var accessToken: String
    var serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User", accessToken = "AccessToken", serverId = "ServerId"
    }
}

struct QuickConnectResult: Decodable, Hashable {
    var authenticated: Bool
    var secret: String
    var code: String

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated", secret = "Secret", code = "Code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authenticated = c.lenient(Bool.self, .authenticated) ?? false
        secret = c.lenient(String.self, .secret) ?? ""
        code = c.lenient(String.self, .code) ?? ""
    }
}

/** A page of a longer list. */
struct QueryResult<T: Decodable>: Decodable {
    var items: [T]
    var totalRecordCount: Int?
    var startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items", totalRecordCount = "TotalRecordCount", startIndex = "StartIndex"
    }

    init(items: [T], totalRecordCount: Int? = nil) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lenient([T].self, .items) ?? []
        totalRecordCount = c.int(.totalRecordCount)
        startIndex = c.int(.startIndex)
    }
}

// --------------------------------------------------------------- playback --

struct PlaybackInfoResponse: Decodable {
    var mediaSources: [MediaSource]
    var playSessionId: String?
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources", playSessionId = "PlaySessionId", errorCode = "ErrorCode"
    }

    init(mediaSources: [MediaSource], playSessionId: String?) {
        self.mediaSources = mediaSources
        self.playSessionId = playSessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = c.lenient([MediaSource].self, .mediaSources) ?? []
        playSessionId = c.lenient(String.self, .playSessionId)
        errorCode = c.lenient(String.self, .errorCode)
    }
}

/** A stretch of an episode the server knows about: the intro, the credits, a recap. */
struct MediaSegment: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var startTicks: Int64
    var endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id", type = "Type", startTicks = "StartTicks", endTicks = "EndTicks"
    }

    init(id: String, type: String, start: Double, end: Double) {
        self.id = id
        self.type = type
        startTicks = Ticks.from(start)
        endTicks = Ticks.from(end)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? UUID().uuidString
        type = c.lenient(String.self, .type) ?? "Unknown"
        startTicks = c.int64(.startTicks) ?? 0
        endTicks = c.int64(.endTicks) ?? 0
    }

    var start: Double { Ticks.seconds(startTicks) }
    var end: Double { Ticks.seconds(endTicks) }

    /** What the skip button says. */
    var skipLabel: String {
        switch type {
        case "Intro": return "Skip Intro"
        case "Outro": return "Skip Credits"
        case "Recap": return "Skip Recap"
        case "Preview": return "Skip Preview"
        case "Commercial": return "Skip Ad"
        default: return "Skip"
        }
    }
}

/** A subtitle the server's subtitle providers (OpenSubtitles…) can fetch. */
struct RemoteSubtitle: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var providerName: String?
    var format: String?
    var author: String?
    var comment: String?
    var language: String?
    var downloadCount: Int?
    var communityRating: Double?
    var isHashMatch: Bool?
    var forced: Bool?
    var hearingImpaired: Bool?
    var machineTranslated: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", providerName = "ProviderName", format = "Format", author = "Author"
        case comment = "Comment", language = "ThreeLetterISOLanguageName", downloadCount = "DownloadCount"
        case communityRating = "CommunityRating", isHashMatch = "IsHashMatch", forced = "Forced"
        case hearingImpaired = "HearingImpaired", machineTranslated = "MachineTranslated"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        name = c.lenient(String.self, .name)
        providerName = c.lenient(String.self, .providerName)
        format = c.lenient(String.self, .format)
        author = c.lenient(String.self, .author)
        comment = c.lenient(String.self, .comment)
        language = c.lenient(String.self, .language)
        downloadCount = c.int(.downloadCount)
        communityRating = c.number(.communityRating)
        isHashMatch = c.lenient(Bool.self, .isHashMatch)
        forced = c.lenient(Bool.self, .forced)
        hearingImpaired = c.lenient(Bool.self, .hearingImpaired)
        machineTranslated = c.lenient(Bool.self, .machineTranslated)
    }
}

/** Jellyfin's dates: ISO 8601, with up to seven digits of fractional seconds. */
enum JellyfinDate {
    static func parse(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        // Keep at most milliseconds: the formatters don't read seven digits.
        if let dot = value.firstIndex(of: ".") {
            var end = value.index(after: dot)
            while end < value.endIndex, value[end].isNumber { end = value.index(after: end) }
            let digits = value[value.index(after: dot)..<end]
            let kept = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            value.replaceSubrange(dot..<end, with: "." + kept)
        }
        if !value.hasSuffix("Z") && !value.contains("+") && value.count > 10 && value.dropFirst(10).range(of: "-") == nil {
            value += "Z"
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: String(value.prefix(10)))
    }
}

/** How many of each kind of thing the server has, for Settings. */
struct ItemCounts: Decodable, Hashable {
    var movies: Int
    var series: Int
    var episodes: Int
    var collections: Int

    enum CodingKeys: String, CodingKey {
        case movies = "MovieCount", series = "SeriesCount", episodes = "EpisodeCount", collections = "BoxSetCount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movies = c.int(.movies) ?? 0
        series = c.int(.series) ?? 0
        episodes = c.int(.episodes) ?? 0
        collections = c.int(.collections) ?? 0
    }
}

/**
 * Where a series' intro ends and its credits begin, marked by hand in the
 * player, for servers that don't find them. The credits are kept as a
 * distance from the end, so one mark fits every episode.
 */
struct SkipMarkers: Codable, Hashable {
    var introEnd: Double?
    var creditsFromEnd: Double?

    init(introEnd: Double? = nil, creditsFromEnd: Double? = nil) {
        self.introEnd = introEnd
        self.creditsFromEnd = creditsFromEnd
    }

    var isEmpty: Bool { introEnd == nil && creditsFromEnd == nil }

    /** The marks as segments of a video [duration] seconds long. */
    func segments(duration: Double) -> [MediaSegment] {
        var result: [MediaSegment] = []
        if let introEnd, introEnd > 1, duration <= 0 || introEnd < duration {
            result.append(MediaSegment(id: "marker-intro", type: "Intro", start: 0, end: introEnd))
        }
        if let fromEnd = creditsFromEnd, duration > 0, fromEnd > 1, fromEnd < duration {
            result.append(MediaSegment(id: "marker-outro", type: "Outro", start: duration - fromEnd, end: duration))
        }
        return result
    }
}
