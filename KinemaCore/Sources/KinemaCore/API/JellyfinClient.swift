import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/** Who is calling: sent with every request, so the server can list this phone under Devices. */
struct ClientInfo: Hashable, Codable {
    var name = "Kinema"
    var version: String
    var deviceName: String
    var deviceId: String
}

enum JellyfinError: LocalizedError, Equatable {
    case invalidAddress
    case notJellyfin
    case unauthorized
    case forbidden
    case notFound
    case server(Int, String?)
    case network(String)
    case decoding(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "That doesn't look like a server address."
        case .notJellyfin: return "There is a server there, but it doesn't answer like Jellyfin."
        case .unauthorized: return "The server didn't accept the sign-in. Check the username and password."
        case .forbidden: return "This account isn't allowed to do that."
        case .notFound: return "The server couldn't find it."
        case .server(let status, let message):
            if let message, !message.isEmpty { return "The server answered with an error (\(status)): \(message)" }
            return "The server answered with an error (\(status))."
        case .network(let message): return message
        case .decoding(let message): return "The server's answer couldn't be read: \(message)"
        case .cancelled: return "Cancelled."
        }
    }

    static func from(_ error: Error) -> JellyfinError {
        if let error = error as? JellyfinError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet: return .network("You're offline.")
            case .timedOut: return .network("The server took too long to answer.")
            case .cannotFindHost, .dnsLookupFailed: return .network("Couldn't find that server. Check the address.")
            case .cannotConnectToHost: return .network("Couldn't connect to the server. Is it running, and is the port right?")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .network("The server's HTTPS certificate isn't trusted.")
            case .appTransportSecurityRequiresSecureConnection: return .network("This connection isn't allowed without HTTPS.")
            default: return .network(error.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}

/** The filters, sorting and paging of an /Items query. */
struct ItemQuery: Hashable {
    var parentId: String?
    var includeTypes: [String] = []
    var excludeTypes: [String] = []
    var recursive = true
    var sortBy: [String] = []
    var descending = false
    var filters: [String] = []
    var genres: [String] = []
    var years: [Int] = []
    var nameStartsWith: String?
    var nameStartsWithOrGreater: String?
    var searchTerm: String?
    var imageTypes: [String] = []
    var personIds: [String] = []
    var ids: [String] = []
    var isFavorite: Bool?
    var isPlayed: Bool?
    var hasTrailer: Bool?
    var startIndex: Int?
    var limit: Int?
    var fields: [String] = ItemFields.card
    var imageTypeLimit: Int? = 1
    var enableImageTypes: [String] = ["Primary", "Backdrop", "Thumb", "Logo"]
    var collapseBoxSetItems: Bool?
    var totalCount = true

    init(parentId: String? = nil, includeTypes: [String] = [], recursive: Bool = true) {
        self.parentId = parentId
        self.includeTypes = includeTypes
        self.recursive = recursive
    }

    func queryItems(userId: String?) -> [URLQueryItem] {
        var q: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { q.append(URLQueryItem(name: name, value: value)) }
        }
        add("userId", userId)
        add("parentId", parentId)
        add("includeItemTypes", includeTypes.joined(separator: ","))
        add("excludeItemTypes", excludeTypes.joined(separator: ","))
        add("recursive", recursive ? "true" : "false")
        add("sortBy", sortBy.joined(separator: ","))
        if !sortBy.isEmpty { add("sortOrder", descending ? "Descending" : "Ascending") }
        add("filters", filters.joined(separator: ","))
        add("genres", genres.joined(separator: "|"))
        add("years", years.map(String.init).joined(separator: ","))
        add("nameStartsWith", nameStartsWith)
        add("nameStartsWithOrGreater", nameStartsWithOrGreater)
        add("imageTypes", imageTypes.joined(separator: ","))
        add("searchTerm", searchTerm)
        add("personIds", personIds.joined(separator: ","))
        add("ids", ids.joined(separator: ","))
        add("isFavorite", isFavorite.map { $0 ? "true" : "false" })
        add("isPlayed", isPlayed.map { $0 ? "true" : "false" })
        add("hasTrailer", hasTrailer.map { $0 ? "true" : "false" })
        add("startIndex", startIndex.map(String.init))
        add("limit", limit.map(String.init))
        add("fields", fields.joined(separator: ","))
        add("imageTypeLimit", imageTypeLimit.map(String.init))
        add("enableImageTypes", enableImageTypes.joined(separator: ","))
        add("collapseBoxSetItems", collapseBoxSetItems.map { $0 ? "true" : "false" })
        add("enableTotalRecordCount", totalCount ? "true" : "false")
        add("enableUserData", "true")
        return q
    }
}

/** The extra fields Kinema asks for. */
enum ItemFields {
    /** Enough for a poster or a card, and the hero's line of text. */
    static let card = ["PrimaryImageAspectRatio", "Overview", "Genres", "ChildCount", "RecursiveItemCount"]
    /** Everything a detail page shows. */
    static let detail = [
        "PrimaryImageAspectRatio", "Overview", "Genres", "People", "Studios", "Taglines", "ProviderIds",
        "ExternalUrls", "RemoteTrailers", "MediaSources", "MediaStreams", "Chapters", "Trickplay", "OriginalTitle",
        "CanDownload", "ChildCount", "RecursiveItemCount", "LocalTrailerCount", "SpecialFeatureCount", "DateCreated", "Tags",
    ]
    /** What an episode row needs. */
    static let episode = ["PrimaryImageAspectRatio", "Overview", "MediaSources", "MediaStreams", "Chapters", "Trickplay", "CanDownload"]
}

/**
 * The Jellyfin REST API, as much of it as Kinema uses. Stateless apart from
 * the address and the sign-in; safe to use from any task.
 */
final class JellyfinClient: @unchecked Sendable {
    let baseURL: URL
    let info: ClientInfo
    let token: String?
    let userId: String?
    let session: URLSession

    init(baseURL: URL, info: ClientInfo, token: String? = nil, userId: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.info = info
        self.token = token
        self.userId = userId
        self.session = session
    }

    /** The same server, signed in. */
    func signedIn(token: String, userId: String) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, info: info, token: token, userId: userId, session: session)
    }

    // ------------------------------------------------------------ plumbing --

    /** The `Authorization` header Jellyfin expects from apps. */
    var authorization: String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        }
        var header = "MediaBrowser Client=\"\(clean(info.name))\", Device=\"\(clean(info.deviceName))\", DeviceId=\"\(clean(info.deviceId))\", Version=\"\(clean(info.version))\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()

    /** An absolute URL on this server for [path] and [query]. */
    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let slash = path.hasPrefix("/") ? "" : "/"
        var text = base + slash + path
        if !query.isEmpty {
            let encoded = query.map { item -> String in
                let name = item.name.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? item.name
                let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? ""
                return "\(name)=\(value)"
            }
            text += (text.contains("?") ? "&" : "?") + encoded.joined(separator: "&")
        }
        return URL(string: text)
    }

    /** A server-relative URL the server handed out (a transcoding or subtitle URL), made absolute. */
    func absolute(_ relative: String) -> URL? {
        if relative.hasPrefix("http://") || relative.hasPrefix("https://") { return URL(string: relative) }
        return url(relative)
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = url(path, query) else { throw JellyfinError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let request = try request(method, path, query: query, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JellyfinError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw JellyfinError.unauthorized
        case 403: throw JellyfinError.forbidden
        case 404: throw JellyfinError.notFound
        default:
            let message = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JellyfinError.server(http.statusCode, message)
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30) async throws -> T {
        let data = try await data("GET", path, query: query, timeout: timeout)
        return try Self.decode(type, data)
    }

    func post<T: Decodable, B: Encodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], body: B) async throws -> T {
        let data = try await data("POST", path, query: query, body: try JSONEncoder().encode(body))
        return try Self.decode(type, data)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error).prefix(200).description)
        }
    }

    private var user: [URLQueryItem] {
        userId.map { [URLQueryItem(name: "userId", value: $0)] } ?? []
    }

    // ------------------------------------------------------- finding a server --

    /**
     * The addresses worth trying for what was typed: as written when it has a
     * scheme, otherwise HTTPS first, then HTTP, then HTTP on Jellyfin's port.
     */
    static func candidates(_ input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return [] }
        // A link copied from the web app still finds the server.
        for suffix in ["/web/index.html", "/web/", "/web"] {
            if let range = text.range(of: suffix, options: [.caseInsensitive, .backwards]), range.upperBound == text.endIndex || text[range.upperBound...].hasPrefix("#") {
                text = String(text[..<range.lowerBound])
            }
        }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        while text.hasSuffix("/") { text.removeLast() }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text).map { [$0] } ?? []
        }
        var result: [URL] = []
        if let https = URL(string: "https://" + text) { result.append(https) }
        if let http = URL(string: "http://" + text) { result.append(http) }
        // "192.168.1.10" with no port: Jellyfin's own port is the likeliest.
        let host = text.split(separator: "/").first.map(String.init) ?? text
        if !host.contains(":"), let port = URL(string: "http://" + host + ":8096" + text.dropFirst(host.count)) {
            result.append(port)
        }
        return result
    }

    /** Find the Jellyfin server at [input], trying the likely addresses in turn. */
    static func probe(_ input: String, info: ClientInfo, session: URLSession = .shared) async throws -> (URL, PublicSystemInfo) {
        let candidates = candidates(input)
        guard !candidates.isEmpty else { throw JellyfinError.invalidAddress }
        var firstError: Error?
        for url in candidates {
            let client = JellyfinClient(baseURL: url, info: info, session: session)
            do {
                let system = try await client.publicInfo(timeout: 8)
                return (url, system)
            } catch {
                if Task.isCancelled { throw JellyfinError.cancelled }
                if firstError == nil || (firstError as? JellyfinError) == .notJellyfin { firstError = error }
            }
        }
        throw firstError.map(JellyfinError.from) ?? JellyfinError.invalidAddress
    }

    func publicInfo(timeout: TimeInterval = 15) async throws -> PublicSystemInfo {
        let data = try await data("GET", "/System/Info/Public", timeout: timeout)
        guard let system = try? JSONDecoder().decode(PublicSystemInfo.self, from: data), system.id != nil || system.version != nil else {
            throw JellyfinError.notJellyfin
        }
        if let product = system.productName, !product.lowercased().contains("jellyfin") { throw JellyfinError.notJellyfin }
        return system
    }

    // ------------------------------------------------------------- signing in --

    func publicUsers() async throws -> [UserDto] {
        try await get([UserDto].self, "/Users/Public")
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String

        enum CodingKeys: String, CodingKey {
            case username = "Username", password = "Pw"
        }
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        try await post(AuthenticationResult.self, "/Users/AuthenticateByName", body: Credentials(username: username, password: password))
    }

    func quickConnectEnabled() async -> Bool {
        guard let data = try? await data("GET", "/QuickConnect/Enabled", timeout: 10) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        let data = try await data("POST", "/QuickConnect/Initiate")
        return try Self.decode(QuickConnectResult.self, data)
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get(QuickConnectResult.self, "/QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)])
    }

    private struct QuickConnectSecret: Encodable {
        let secret: String

        enum CodingKeys: String, CodingKey {
            case secret = "Secret"
        }
    }

    func authenticate(quickConnectSecret secret: String) async throws -> AuthenticationResult {
        try await post(AuthenticationResult.self, "/Users/AuthenticateWithQuickConnect", body: QuickConnectSecret(secret: secret))
    }

    func me() async throws -> UserDto {
        try await get(UserDto.self, "/Users/Me")
    }

    /** End this session on the server; the token stops working. */
    func logout() async {
        _ = try? await data("POST", "/Sessions/Logout", timeout: 8)
    }

    // ---------------------------------------------------------------- browsing --

    /** The user's libraries, in the order they arranged them. */
    func views() async throws -> [Item] {
        try await get(QueryResult<Item>.self, "/UserViews", query: user).items
    }

    func items(_ query: ItemQuery) async throws -> QueryResult<Item> {
        try await get(QueryResult<Item>.self, "/Items", query: query.queryItems(userId: userId))
    }

    func item(_ id: String) async throws -> Item {
        try await get(Item.self, "/Items/\(id)", query: user)
    }

    /** What was added lately to [parentId] (a library), newest first. */
    func latest(parentId: String?, types: [String] = [], limit: Int = 20) async throws -> [Item] {
        var q = user
        if let parentId { q.append(URLQueryItem(name: "parentId", value: parentId)) }
        if !types.isEmpty { q.append(URLQueryItem(name: "includeItemTypes", value: types.joined(separator: ","))) }
        q += [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: ItemFields.card.joined(separator: ",")),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
            URLQueryItem(name: "groupItems", value: "true"),
        ]
        return try await get([Item].self, "/Items/Latest", query: q)
    }

    /** Started and not finished: Continue Watching. */
    func resume(limit: Int = 20, parentId: String? = nil) async throws -> [Item] {
        var q = user + [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            URLQueryItem(name: "fields", value: ItemFields.card.joined(separator: ",")),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]
        if let parentId { q.append(URLQueryItem(name: "parentId", value: parentId)) }
        return try await get(QueryResult<Item>.self, "/UserItems/Resume", query: q).items
    }

    /** The next episode of each series being watched, or of one series. */
    func nextUp(seriesId: String? = nil, limit: Int = 20, rewatching: Bool = false) async throws -> [Item] {
        var q = user + [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: ItemFields.card.joined(separator: ",")),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
            URLQueryItem(name: "enableResumable", value: "false"),
            URLQueryItem(name: "enableRewatching", value: rewatching ? "true" : "false"),
        ]
        if let seriesId { q.append(URLQueryItem(name: "seriesId", value: seriesId)) }
        return try await get(QueryResult<Item>.self, "/Shows/NextUp", query: q).items
    }

    func seasons(seriesId: String) async throws -> [Item] {
        let q = user + [
            URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio,ChildCount,Overview"),
            URLQueryItem(name: "enableUserData", value: "true"),
        ]
        return try await get(QueryResult<Item>.self, "/Shows/\(seriesId)/Seasons", query: q).items
    }

    func episodes(seriesId: String, seasonId: String? = nil, startItemId: String? = nil, limit: Int? = nil) async throws -> [Item] {
        var q = user + [
            URLQueryItem(name: "fields", value: ItemFields.episode.joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
        ]
        if let seasonId { q.append(URLQueryItem(name: "seasonId", value: seasonId)) }
        if let startItemId { q.append(URLQueryItem(name: "startItemId", value: startItemId)) }
        if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(QueryResult<Item>.self, "/Shows/\(seriesId)/Episodes", query: q).items
    }

    func similar(_ id: String, limit: Int = 16) async throws -> [Item] {
        let q = user + [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: ItemFields.card.joined(separator: ",")),
        ]
        return try await get(QueryResult<Item>.self, "/Items/\(id)/Similar", query: q).items
    }

    func specialFeatures(_ id: String) async throws -> [Item] {
        try await get([Item].self, "/Items/\(id)/SpecialFeatures", query: user)
    }

    func localTrailers(_ id: String) async throws -> [Item] {
        try await get([Item].self, "/Items/\(id)/LocalTrailers", query: user)
    }

    /** The genres in [parentId], for browsing by genre. */
    func genres(parentId: String?, types: [String] = []) async throws -> [Item] {
        var q = user + [
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "sortOrder", value: "Ascending"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]
        if let parentId { q.append(URLQueryItem(name: "parentId", value: parentId)) }
        if !types.isEmpty { q.append(URLQueryItem(name: "includeItemTypes", value: types.joined(separator: ","))) }
        return try await get(QueryResult<Item>.self, "/Genres", query: q).items
    }

    /** The years things in [parentId] came out, newest first, from the server's filter list. */
    func years(parentId: String?, types: [String]) async throws -> [Int] {
        struct Filters: Decodable {
            let years: [Int]?
            enum CodingKeys: String, CodingKey { case years = "Years" }
        }
        var q = user
        if let parentId { q.append(URLQueryItem(name: "parentId", value: parentId)) }
        if !types.isEmpty { q.append(URLQueryItem(name: "includeItemTypes", value: types.joined(separator: ","))) }
        let filters = try await get(Filters.self, "/Items/Filters", query: q)
        return (filters.years ?? []).sorted(by: >)
    }

    func persons(searchTerm: String, limit: Int = 20) async throws -> [Item] {
        let q = user + [
            URLQueryItem(name: "searchTerm", value: searchTerm),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]
        return try await get(QueryResult<Item>.self, "/Persons", query: q).items
    }

    // --------------------------------------------------------------- user data --

    func setPlayed(_ id: String, _ played: Bool) async throws -> UserData {
        let data = try await data(played ? "POST" : "DELETE", "/UserPlayedItems/\(id)", query: user)
        return (try? JSONDecoder().decode(UserData.self, from: data)) ?? UserData(played: played)
    }

    func setFavorite(_ id: String, _ favorite: Bool) async throws -> UserData {
        let data = try await data(favorite ? "POST" : "DELETE", "/UserFavoriteItems/\(id)", query: user)
        return (try? JSONDecoder().decode(UserData.self, from: data)) ?? UserData(isFavorite: favorite)
    }

    func updateUserData(_ id: String, _ update: UserDataUpdate) async throws {
        try await data("POST", "/UserItems/\(id)/UserData", query: user, body: try JSONEncoder().encode(update))
    }

    // ---------------------------------------------------------------- playback --

    func playbackInfo(_ id: String, _ request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        try await post(PlaybackInfoResponse.self, "/Items/\(id)/PlaybackInfo", query: user, body: request)
    }

    func reportStart(_ report: PlaybackReport) async {
        _ = try? await data("POST", "/Sessions/Playing", body: try? JSONEncoder().encode(report), timeout: 10)
    }

    func reportProgress(_ report: PlaybackReport) async {
        _ = try? await data("POST", "/Sessions/Playing/Progress", body: try? JSONEncoder().encode(report), timeout: 10)
    }

    func reportStopped(_ report: PlaybackReport) async {
        _ = try? await data("POST", "/Sessions/Playing/Stopped", body: try? JSONEncoder().encode(report), timeout: 10)
    }

    /** The intro, credits and recap of an episode (Jellyfin 10.10 and later; empty on older servers). */
    func mediaSegments(_ id: String) async -> [MediaSegment] {
        guard let result = try? await get(QueryResult<MediaSegment>.self, "/MediaSegments/\(id)", timeout: 10) else { return [] }
        return result.items.filter { $0.endTicks > $0.startTicks }.sorted { $0.startTicks < $1.startTicks }
    }

    func searchRemoteSubtitles(_ id: String, language: String) async throws -> [RemoteSubtitle] {
        try await get([RemoteSubtitle].self, "/Items/\(id)/RemoteSearch/Subtitles/\(language)", timeout: 60)
    }

    func downloadRemoteSubtitle(_ id: String, subtitleId: String) async throws {
        let escaped = subtitleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? subtitleId
        try await data("POST", "/Items/\(id)/RemoteSearch/Subtitles/\(escaped)", timeout: 60)
    }

    // ---------------------------------------------------------------- addresses --

    private var key: [URLQueryItem] {
        token.map { [URLQueryItem(name: "ApiKey", value: $0)] } ?? []
    }

    /** An image, scaled by the server to [maxWidth] pixels. */
    func imageURL(_ ref: ImageRef, maxWidth: Int, quality: Int = 90) -> URL? {
        var path = "/Items/\(ref.itemId)/Images/\(ref.type.rawValue)"
        if let index = ref.index { path += "/\(index)" }
        var q = [URLQueryItem(name: "maxWidth", value: String(maxWidth)), URLQueryItem(name: "quality", value: String(quality))]
        if let tag = ref.tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        return url(path, q)
    }

    func userImageURL(_ user: UserDto, maxWidth: Int = 200) -> URL? {
        guard let tag = user.primaryImageTag else { return nil }
        return url("/Users/\(user.id)/Images/Primary", [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxWidth", value: String(maxWidth))])
    }

    func chapterImageURL(itemId: String, index: Int, tag: String?, maxWidth: Int = 400) -> URL? {
        imageURL(ImageRef(itemId: itemId, type: .chapter, tag: tag, index: index), maxWidth: maxWidth)
    }

    /** The file itself, untouched. */
    func directStreamURL(itemId: String, source: MediaSource) -> URL? {
        var q = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: source.id),
            URLQueryItem(name: "deviceId", value: info.deviceId),
        ] + key
        if let tag = source.eTag { q.append(URLQueryItem(name: "Tag", value: tag)) }
        return url("/Videos/\(itemId)/stream.\(source.fileExtension)", q)
    }

    /** A text subtitle track, converted by the server to [format]. */
    func subtitleURL(itemId: String, mediaSourceId: String, index: Int, format: String = "srt") -> URL? {
        url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/0/Stream.\(format)", key)
    }

    /** One sheet of trickplay thumbnails. */
    func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String?) -> URL? {
        var q = key
        if let mediaSourceId { q.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId)) }
        return url("/Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", q)
    }

    /** The original file, for downloading. */
    func downloadURL(itemId: String) -> URL? {
        url("/Items/\(itemId)/Download", key)
    }
}
