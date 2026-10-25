import SwiftUI

/**
 * Search: films, shows, episodes, people and collections as you type, and
 * genres and recent searches before you do.
 */
struct SearchScreen: View {
    @Environment(\.kinema) private var theme
    @State private var movies: [Item] = []
    @State private var shows: [Item] = []
    @State private var episodes: [Item] = []
    @State private var people: [Item] = []
    @State private var collections: [Item] = []
    @State private var genres: [Item] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "search.recent") ?? []

    var body: some View {
        let graph = AppGraph.shared
        let query = graph.ui.searchQuery.trimmingCharacters(in: .whitespaces)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isEmpty {
                    browse
                } else if searching && searched != query {
                    LoadingView()
                } else if nothingFound {
                    EmptyState(icon: "magnifyingglass", title: "No results", message: "Nothing on your server matches “\(query)”.")
                } else {
                    results
                }
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .kinemaScreen()
        .task(id: query) { await search(query) }
        .task(id: graph.auth.generation) {
            if genres.isEmpty, let client = graph.auth.client {
                genres = (try? await client.genres(parentId: nil, types: ["Movie", "Series"])) ?? []
            }
        }
    }

    private var nothingFound: Bool {
        movies.isEmpty && shows.isEmpty && episodes.isEmpty && people.isEmpty && collections.isEmpty
    }

    @ViewBuilder
    private var results: some View {
        MediaShelf(title: "Movies", icon: "film", items: movies, cardWidth: theme.posterWidth) { PosterCard(item: $0) }
        MediaShelf(title: "Shows", icon: "tv", items: shows, cardWidth: theme.posterWidth) { PosterCard(item: $0) }
        MediaShelf(title: "Episodes", icon: "list.number", items: episodes, cardWidth: 240) { LandscapeCard(item: $0, plays: false) }
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader("People", icon: "person.2.fill")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(people) { person in
                            PersonCard(person: Person(id: person.id, name: person.name, role: nil, type: nil, primaryImageTag: person.imageTags?["Primary"]))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
        }
        MediaShelf(title: "Collections", icon: "square.stack.fill", items: collections, cardWidth: theme.posterWidth) { PosterCard(item: $0) }
    }

    private var browse: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 0) {
            if !recent.isEmpty {
                SectionHeader("Recent", icon: "clock.arrow.circlepath") {
                    Button("Clear") {
                        recent = []
                        UserDefaults.standard.removeObject(forKey: "search.recent")
                    }
                    .font(KFont.labelLarge)
                    .foregroundStyle(c.accent)
                }
                ForEach(recent, id: \.self) { term in
                    Button { graph.ui.searchQuery = term } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(c.ink3)
                            Text(term).foregroundStyle(c.ink)
                            Spacer()
                            Image(systemName: "arrow.up.left").foregroundStyle(c.ink4)
                        }
                        .font(KFont.bodyLarge)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            if !genres.isEmpty {
                SectionHeader("Browse by Genre", icon: "theatermasks.fill").padding(.top, 12)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(genres) { genre in
                        Button {
                            graph.actions.navigate(.genre(name: genre.name, parentId: nil, types: ["Movie", "Series"]))
                        } label: {
                            Text(genre.name)
                                .font(KFont.titleSmall)
                                .foregroundStyle(c.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.radii.md, style: .continuous)
                                        .fill(LinearGradient(colors: [genreColor(genre.name).opacity(0.55), genreColor(genre.name).opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                                .overlay(RoundedRectangle(cornerRadius: theme.radii.md, style: .continuous).strokeBorder(c.edge, lineWidth: 1))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /** A steady colour per genre, so the grid isn't all one shade. */
    private func genreColor(_ name: String) -> Color {
        let palette: [UInt32] = [0x6F8FEF, 0xE5734A, 0x4BB38A, 0xC35BD1, 0xE2B13C, 0x4AA8D8, 0xD9536F, 0x8A7CF0]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Color(argb: palette[hash % palette.count])
    }

    private func search(_ query: String) async {
        guard !query.isEmpty, let client = AppGraph.shared.auth.client else {
            searched = ""
            return
        }
        searching = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        func items(_ types: [String], limit: Int = 24) async -> [Item] {
            var q = ItemQuery(includeTypes: types)
            q.searchTerm = query
            q.limit = limit
            q.totalCount = false
            return (try? await client.items(q).items) ?? []
        }
        async let moviesLoad = items(["Movie"])
        async let showsLoad = items(["Series"])
        async let episodesLoad = items(["Episode"], limit: 16)
        async let collectionsLoad = items(["BoxSet"], limit: 12)
        async let peopleLoad = (try? await client.persons(searchTerm: query, limit: 16)) ?? []
        let found = await (moviesLoad, showsLoad, episodesLoad, collectionsLoad, peopleLoad)
        guard !Task.isCancelled else { return }
        movies = found.0
        shows = found.1
        episodes = found.2
        collections = found.3
        people = found.4
        searched = query
        searching = false
        if !nothingFound { remember(query) }
        #if DEBUG
        ScreenshotDriver.noteLoaded("found")
        #endif
    }

    private func remember(_ query: String) {
        guard query.count >= 3 else { return }
        var list = recent.filter { $0.lowercased() != query.lowercased() && !query.lowercased().hasPrefix($0.lowercased()) }
        list.insert(query, at: 0)
        recent = Array(list.prefix(8))
        UserDefaults.standard.set(recent, forKey: "search.recent")
    }
}
