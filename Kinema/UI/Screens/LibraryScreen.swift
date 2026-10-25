import SwiftUI

/** How a library grid is sorted. */
enum LibrarySort: String, CaseIterable, Hashable {
    case name, dateAdded, releaseDate, rating, criticRating, runtime, lastPlayed, random

    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .rating: return "Rating"
        case .criticRating: return "Critics' Rating"
        case .runtime: return "Runtime"
        case .lastPlayed: return "Last Watched"
        case .random: return "Random"
        }
    }

    var fields: [String] {
        switch self {
        case .name: return ["SortName"]
        case .dateAdded: return ["DateCreated", "SortName"]
        case .releaseDate: return ["PremiereDate", "ProductionYear", "SortName"]
        case .rating: return ["CommunityRating", "SortName"]
        case .criticRating: return ["CriticRating", "SortName"]
        case .runtime: return ["Runtime", "SortName"]
        case .lastPlayed: return ["DatePlayed", "SortName"]
        case .random: return ["Random"]
        }
    }

    /** The direction that feels natural: A to Z, newest first, best first. */
    var naturallyDescending: Bool { self != .name && self != .random }
}

/** Which items a library grid shows. */
enum LibraryFilter: String, CaseIterable, Hashable {
    case all, unwatched, watched, inProgress, favorites

    var label: String {
        switch self {
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .watched: return "Watched"
        case .inProgress: return "In Progress"
        case .favorites: return "Favorites"
        }
    }

    var filters: [String] {
        switch self {
        case .all: return []
        case .unwatched: return ["IsUnplayed"]
        case .watched: return ["IsPlayed"]
        case .inProgress: return ["IsResumable"]
        case .favorites: return ["IsFavorite"]
        }
    }
}

/**
 * The Library tab: the user's libraries as tabs along the top, and the one
 * chosen as a grid of posters below.
 */
struct LibraryScreen: View {
    @Environment(\.kinema) private var theme
    @State private var selected: String?

    private static let favoritesId = "kinema.favorites"
    private static let collectionsId = "kinema.collections"

    var body: some View {
        let graph = AppGraph.shared
        let views = graph.library.videoViews.filter { $0.collectionType != "boxsets" }
        var tabs = views
        tabs.append(Item(id: Self.collectionsId, name: "Collections", type: "UserView"))
        tabs.append(Item(id: Self.favoritesId, name: "Favorites", type: "UserView"))
        let current = tabs.first { $0.id == selected } ?? tabs.first
        return Group {
            if let current, graph.library.viewsLoaded {
                LibraryGrid(view: pseudo(current), header: AnyView(tabBar(tabs, current: current)))
                    .id(current.id)
            } else if graph.library.viewsLoaded {
                EmptyState(icon: "square.stack", title: "No libraries", message: "This account can't see any film or show libraries on the server.")
                    .kinemaScreen()
            } else {
                LoadingView().kinemaScreen()
            }
        }
        .navigationTitle("Library")
        .task(id: graph.auth.generation) { await graph.library.loadViews() }
    }

    /** Favorites and Collections aren't libraries on the server; they're filters across all of them. */
    private func pseudo(_ item: Item) -> Item {
        var copy = item
        if item.id == Self.favoritesId { copy.collectionType = "kinema.favorites" }
        if item.id == Self.collectionsId { copy.collectionType = "boxsets" }
        return copy
    }

    private func tabBar(_ tabs: [Item], current: Item) -> some View {
        let c = theme.colors
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(tabs) { tab in
                        let on = tab.id == current.id
                        Button {
                            Haptics.select()
                            withAnimation(theme.ease) { selected = tab.id }
                        } label: {
                            VStack(spacing: 7) {
                                Text(tab.name)
                                    .font(.system(size: 17, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? c.ink : c.ink3)
                                Capsule()
                                    .fill(on ? c.accent : .clear)
                                    .frame(height: 3)
                            }
                            .fixedSize()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
            .overlay(alignment: .bottom) { Rule() }
            .onAppear { reader.scrollTo(current.id) }
        }
    }
}

/** One library on its own page (from "See all" or a library card). */
struct LibraryGridScreen: View {
    let view: Item

    var body: some View {
        LibraryGrid(view: view, header: nil)
            .navigationTitle(view.name)
            .navigationBarTitleDisplayMode(.large)
    }
}

/** Everything in a genre, across the libraries (or within one). */
struct GenreScreen: View {
    let name: String
    let parentId: String?
    let types: [String]

    var body: some View {
        var view = Item(id: parentId ?? "kinema.genre", name: name, type: "Genre")
        view.collectionType = "kinema.genre"
        view.genres = [name]
        view.tags = types
        return LibraryGrid(view: view, header: nil)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.large)
    }
}

/**
 * A grid of posters with filtering, sorting, an A–Z jump and paging: a
 * library, a genre, the favourites or the collections.
 */
struct LibraryGrid: View {
    @Environment(\.kinema) private var theme
    let view: Item
    var header: AnyView?

    @State private var items: [Item] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var failed: String?
    @State private var sort: LibrarySort = .name
    @State private var descending = false
    @State private var filter: LibraryFilter = .all
    @State private var genres: Set<String> = []
    @State private var years: Set<Int> = []
    @State private var letter: String?
    @State private var text = ""
    @State private var availableGenres: [String] = []
    @State private var availableYears: [Int] = []
    @State private var generation = 0

    private static let pageSize = 60
    private static let letters = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    private var queryKey: String {
        "\(view.id)|\(sort)|\(descending)|\(filter)|\(genres.sorted())|\(years.sorted())|\(letter ?? "")|\(text)|\(AppGraph.shared.library.version)"
    }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: minWidth, maximum: minWidth * 1.6), spacing: 12, alignment: .top)]
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if let header { header }
                    FilterField(text: $text, placeholder: "Filter \(noun(plural: true))")
                        .id("top")
                    controls
                    if items.isEmpty && loading {
                        LoadingView()
                    } else if items.isEmpty, let failed {
                        EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load this", message: failed) {
                            Pill("Try again", icon: "arrow.clockwise", accent: true) { reload() }
                        }
                    } else if items.isEmpty && !loading {
                        EmptyState(icon: "line.3.horizontal.decrease.circle", title: "Nothing matches", message: activeFilters ? "Try fewer filters." : "This library is empty.")
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(items) { item in
                            PosterCard(item: item, subtitle: subtitle(item))
                                .onAppear { if item.id == items.last?.id { loadMore() } }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.trailing, sort == .name ? 10 : 0)
                    if loading && !items.isEmpty {
                        ProgressView().tint(theme.colors.accent).frame(maxWidth: .infinity).padding(20)
                    }
                }
                .padding(.bottom, 32)
            }
            .overlay(alignment: .trailing) {
                if sort == .name && (total ?? 0) > 30 { alphabet(reader) }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { reload() }
        }
        .kinemaScreen()
        .task(id: queryKey) {
            // A short pause while typing, so each letter isn't a request.
            if !text.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .task(id: view.id) { await loadFilterOptions() }
        .onAppear {
            if items.isEmpty, view.collectionType == "kinema.favorites" { sort = .name }
        }
    }

    private var minWidth: CGFloat {
        switch theme.settings.posterSize {
        case .small: return 78
        case .medium: return 104
        case .large: return 150
        }
    }

    private var activeFilters: Bool {
        filter != .all || !genres.isEmpty || !years.isEmpty || letter != nil || !text.isEmpty
    }

    // ------------------------------------------------------------ controls --

    private var controls: some View {
        let c = theme.colors
        return HStack(spacing: 8) {
            Text(total.map { Format.count($0, noun(plural: false), plural: noun(plural: true)) } ?? " ")
                .font(KFont.bodyLarge)
                .foregroundStyle(c.ink3)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer()
            if let letter {
                Pill(letter, icon: "xmark") { self.letter = nil }
            }
            Menu {
                Picker("Sort by", selection: Binding(get: { sort }, set: { pick($0) })) {
                    ForEach(LibrarySort.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                if sort != .random {
                    Picker("Order", selection: $descending) {
                        Text(sort == .name ? "A to Z" : "Oldest / lowest first").tag(false)
                        Text(sort == .name ? "Z to A" : "Newest / highest first").tag(true)
                    }
                }
            } label: {
                chip(icon: "arrow.up.arrow.down", text: sort.label, on: false)
            }
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                if !availableGenres.isEmpty {
                    Menu("Genres\(genres.isEmpty ? "" : " (\(genres.count))")") {
                        if !genres.isEmpty { Button("Any genre") { genres = [] } }
                        ForEach(availableGenres, id: \.self) { genre in
                            Button { toggle(&genres, genre) } label: {
                                if genres.contains(genre) { Label(genre, systemImage: "checkmark") } else { Text(genre) }
                            }
                        }
                    }
                }
                if !availableYears.isEmpty {
                    Menu("Years\(years.isEmpty ? "" : " (\(years.count))")") {
                        if !years.isEmpty { Button("Any year") { years = [] } }
                        ForEach(availableYears, id: \.self) { year in
                            Button { toggle(&years, year) } label: {
                                if years.contains(year) { Label(String(year), systemImage: "checkmark") } else { Text(String(year)) }
                            }
                        }
                    }
                }
                if activeFilters {
                    Button(role: .destructive) {
                        filter = .all
                        genres = []
                        years = []
                        letter = nil
                        text = ""
                    } label: { Label("Clear filters", systemImage: "xmark.circle") }
                }
            } label: {
                chip(icon: "line.3.horizontal.decrease", text: filterLabel, on: filter != .all || !genres.isEmpty || !years.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var filterLabel: String {
        var parts: [String] = []
        if filter != .all { parts.append(filter.label) }
        if !genres.isEmpty { parts.append(genres.count == 1 ? genres.first! : "\(genres.count) genres") }
        if !years.isEmpty { parts.append(years.count == 1 ? String(years.first!) : "\(years.count) years") }
        return parts.isEmpty ? "Filter" : parts.joined(separator: " · ")
    }

    private func chip(icon: String, text: String, on: Bool) -> some View {
        let c = theme.colors
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(KFont.labelLarge).lineLimit(1)
        }
        .foregroundStyle(on ? c.onAccent : c.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(on ? c.accent : c.glass))
        .overlay(Capsule().strokeBorder(on ? .clear : c.edge, lineWidth: 1))
    }

    private func pick(_ option: LibrarySort) {
        sort = option
        descending = option.naturallyDescending
        if option != .name { letter = nil }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    /** The A–Z strip down the side: jump to where names start with a letter. */
    private func alphabet(_ reader: ScrollViewProxy) -> some View {
        let c = theme.colors
        return VStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { value in
                Button {
                    Haptics.select()
                    letter = value == "#" ? nil : value
                    descending = false
                    reader.scrollTo("top", anchor: .top)
                } label: {
                    Text(value)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(letter == value ? c.accent : c.ink3)
                        .frame(width: 18, height: 15)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(Capsule().fill(c.glass))
        .padding(.trailing, 2)
        .accessibilityLabel("Jump to letter")
    }

    // ------------------------------------------------------------- loading --

    private func noun(plural: Bool) -> String {
        switch view.collectionType {
        case "movies": return plural ? "movies" : "movie"
        case "tvshows": return plural ? "shows" : "show"
        case "boxsets": return plural ? "collections" : "collection"
        case "homevideos": return plural ? "videos" : "video"
        case "musicvideos": return plural ? "music videos" : "music video"
        default: return plural ? "titles" : "title"
        }
    }

    private var baseQuery: ItemQuery {
        var query = ItemQuery()
        switch view.collectionType {
        case "movies":
            query.parentId = view.id
            query.includeTypes = ["Movie"]
        case "tvshows":
            query.parentId = view.id
            query.includeTypes = ["Series"]
        case "boxsets":
            query.includeTypes = ["BoxSet"]
            if view.kind == .collectionFolder { query.parentId = view.id }
        case "homevideos":
            query.parentId = view.id
            query.includeTypes = ["Video"]
        case "musicvideos":
            query.parentId = view.id
            query.includeTypes = ["MusicVideo"]
        case "kinema.favorites":
            query.includeTypes = ["Movie", "Series", "BoxSet", "Episode", "Video"]
            query.filters = ["IsFavorite"]
        case "kinema.genre":
            query.includeTypes = view.tags ?? ["Movie", "Series"]
            query.genres = view.genres ?? []
            if view.id != "kinema.genre" { query.parentId = view.id }
        default:
            query.parentId = view.id
            query.includeTypes = ["Movie", "Series", "Video", "BoxSet"]
        }
        return query
    }

    private func makeQuery(start: Int) -> ItemQuery {
        var query = baseQuery
        query.sortBy = sort.fields
        query.descending = descending
        query.filters += filter.filters
        if !genres.isEmpty { query.genres = Array(genres).sorted() }
        if !years.isEmpty { query.years = Array(years).sorted() }
        if let letter { query.nameStartsWithOrGreater = letter }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { query.searchTerm = text.trimmingCharacters(in: .whitespaces) }
        query.startIndex = start
        query.limit = Self.pageSize
        return query
    }

    private func reload() {
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let client = AppGraph.shared.auth.client else { return }
        if reset {
            generation += 1
        } else if loading {
            return
        }
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let result = try await client.items(makeQuery(start: reset ? 0 : items.count))
            guard mine == generation else { return }
            failed = nil
            if reset { items = result.items } else { items += result.items.filter { new in !items.contains { $0.id == new.id } } }
            total = result.totalRecordCount ?? items.count
            #if DEBUG
            ScreenshotDriver.noteLoaded("library")
            #endif
        } catch {
            guard mine == generation else { return }
            if !(JellyfinError.from(error) == .cancelled) { failed = JellyfinError.from(error).localizedDescription }
        }
    }

    private func loadMore() {
        guard !loading, let total, items.count < total else { return }
        Task { await load(reset: false) }
    }

    private func loadFilterOptions() async {
        guard let client = AppGraph.shared.auth.client else { return }
        let base = baseQuery
        if let genres = try? await client.genres(parentId: base.parentId, types: base.includeTypes) {
            availableGenres = genres.map(\.name)
        }
        if let years = try? await client.years(parentId: base.parentId, types: base.includeTypes) {
            availableYears = years
        }
    }

    private func subtitle(_ item: Item) -> String? {
        switch sort {
        case .rating: return Format.rating(item.communityRating).map { "★ \($0)" } ?? item.yearText
        case .runtime: return item.runtime > 0 ? Format.runtime(item.runtime) : item.yearText
        case .dateAdded: return item.dateCreated.flatMap { Format.date($0) } ?? item.yearText
        default: return nil
        }
    }
}

/** A home shelf in full: everything in Continue Watching, Next Up or Favorites. */
struct ShelfScreen: View {
    @Environment(\.kinema) private var theme
    let kind: ShelfKind
    @State private var items: [Item] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if !loaded {
                LoadingView()
            } else if items.isEmpty {
                EmptyState(icon: "tray", title: "Nothing here", message: nil)
            } else if wide {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(items) { LandscapeCard(item: $0) }
                }
                .padding(16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(items) { PosterCard(item: $0) }
                }
                .padding(16)
            }
        }
        .navigationTitle(title)
        .kinemaScreen()
        .task(id: AppGraph.shared.library.version) { await load() }
    }

    private var wide: Bool {
        switch kind {
        case .continueWatching, .nextUp: return true
        default: return false
        }
    }

    private var title: String {
        switch kind {
        case .continueWatching: return "Continue Watching"
        case .nextUp: return "Next Up"
        case .latest(_, let name): return "New in \(name)"
        case .favorites: return "Favorites"
        }
    }

    private func load() async {
        guard let client = AppGraph.shared.auth.client else { return }
        switch kind {
        case .continueWatching: items = (try? await client.resume(limit: 100)) ?? []
        case .nextUp: items = (try? await client.nextUp(limit: 100)) ?? []
        case .latest(let id, _): items = (try? await client.latest(parentId: id, limit: 100)) ?? []
        case .favorites:
            var query = ItemQuery(includeTypes: ["Movie", "Series", "BoxSet", "Episode"])
            query.filters = ["IsFavorite"]
            query.sortBy = ["SortName"]
            query.limit = 300
            items = (try? await client.items(query).items) ?? []
        }
        loaded = true
    }
}
