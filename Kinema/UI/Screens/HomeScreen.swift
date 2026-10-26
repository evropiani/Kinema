import SwiftUI

/** One library's newest additions, for its shelf on the home page. */
private struct LatestShelf: Identifiable {
    let library: Item
    let items: [Item]
    var id: String { library.id }
}

/**
 * The home page: featured titles in a big carousel at the top, then what you
 * were watching, what's next, and what's new in each library.
 */
struct HomeScreen: View {
    @Environment(\.kinema) private var theme
    @State private var featured: [Item] = []
    @State private var resume: [Item] = []
    @State private var nextUp: [Item] = []
    @State private var latest: [LatestShelf] = []
    @State private var favorites: [Item] = []
    @State private var collections: [Item] = []
    @State private var genres: [Item] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var heroIndex = 0
    @State private var hour = Calendar.current.component(.hour, from: Date())

    private var sections: [HomeSection] { theme.settings.homeSections }

    var body: some View {
        let graph = AppGraph.shared
        let heroShown = sections.contains(.hero) && !featured.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if heroShown {
                    HeroCarousel(items: featured, index: $heroIndex)
                } else {
                    header.padding(.top, 60)
                }
                if !loaded && error == nil {
                    LoadingView().padding(.top, heroShown ? 0 : 40)
                } else if let error, isEmpty {
                    EmptyState(icon: "wifi.exclamationmark", title: "Couldn't reach your server", message: error) {
                        HStack(spacing: 10) {
                            Pill("Try again", icon: "arrow.clockwise", accent: true) { Task { await load() } }
                            if !graph.downloads.records.isEmpty {
                                Pill("Downloads", icon: "arrow.down.circle") { graph.actions.selectTab(.downloads) }
                            }
                        }
                    }
                } else if isEmpty {
                    EmptyState(icon: "film.stack", title: "Nothing here yet", message: "When your server has films or shows, they'll show up here.")
                }
                ForEach(sections.filter { $0 != .hero }, id: \.self) { section in
                    shelf(section)
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: heroShown ? .top : [])
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) { AccountButton().padding(.trailing, 16).padding(.top, 4) }
        .refreshable { await load() }
        .kinemaScreen()
        .artworkTint(heroShown && featured.indices.contains(heroIndex) ? (featured[heroIndex].backdropImage ?? featured[heroIndex].posterImage) : nil)
        .task(id: "\(graph.auth.generation)-\(graph.library.version)") { await load() }
        .onAppear { hour = Calendar.current.component(.hour, from: Date()) }
    }

    private var isEmpty: Bool {
        featured.isEmpty && resume.isEmpty && nextUp.isEmpty && latest.allSatisfy { $0.items.isEmpty } && favorites.isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.greeting(hour))
                .font(KFont.headlineLarge)
                .foregroundStyle(theme.colors.ink)
            if let profile = AppGraph.shared.auth.active {
                Text("\(profile.username) · \(profile.serverName)")
                    .font(KFont.bodySmall)
                    .foregroundStyle(theme.colors.ink3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func shelf(_ section: HomeSection) -> some View {
        let graph = AppGraph.shared
        switch section {
        case .hero:
            EmptyView()
        case .continueWatching:
            let items = theme.settings.mergeNextUp ? merged : resume
            MediaShelf(title: "Continue Watching", icon: "play.circle.fill", items: items, cardWidth: 270, seeAll: items.count > 6 ? { graph.actions.navigate(.shelf(.continueWatching)) } : nil) {
                LandscapeCard(item: $0)
            }
        case .nextUp:
            if !theme.settings.mergeNextUp {
                MediaShelf(title: "Next Up", icon: "forward.end.fill", items: nextUp, cardWidth: 270, seeAll: nextUp.count > 6 ? { graph.actions.navigate(.shelf(.nextUp)) } : nil) {
                    LandscapeCard(item: $0)
                }
            }
        case .latest:
            ForEach(latest) { shelf in
                MediaShelf(title: "New in \(shelf.library.name)", icon: icon(shelf.library), items: shelf.items, cardWidth: theme.posterWidth, seeAll: { graph.actions.navigate(.library(shelf.library)) }) {
                    PosterCard(item: $0)
                }
            }
        case .favorites:
            MediaShelf(title: "Favorites", icon: "heart.fill", items: favorites, cardWidth: theme.posterWidth, seeAll: favorites.count > 8 ? { graph.actions.navigate(.shelf(.favorites)) } : nil) {
                PosterCard(item: $0)
            }
        case .collections:
            MediaShelf(title: "Collections", icon: "square.stack.fill", items: collections, cardWidth: theme.posterWidth) {
                PosterCard(item: $0)
            }
        case .genres:
            if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader("Genres", icon: "theatermasks.fill")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(genres) { genre in
                                Pill(genre.name) {
                                    graph.actions.navigate(.genre(name: genre.name, parentId: nil, types: ["Movie", "Series"]))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    /** Continue Watching and Next Up as one row, most recent first. */
    private var merged: [Item] {
        let resumeSeries = Set(resume.compactMap(\.seriesId))
        return resume + nextUp.filter { !resumeSeries.contains($0.seriesId ?? "") }
    }

    private func icon(_ library: Item) -> String {
        switch library.collectionType {
        case "tvshows": return "tv"
        case "boxsets": return "square.stack.fill"
        case "homevideos": return "video.fill"
        default: return "film"
        }
    }

    private func load() async {
        let graph = AppGraph.shared
        guard let client = graph.auth.client else { return }
        await graph.library.loadViews()
        let views = graph.library.videoViews.filter { !theme.settings.hiddenLibraries.contains($0.id) }
        let wanted = Set(sections)

        async let featuredLoad: [Item] = wanted.contains(.hero) ? await Self.featured(client) : []
        async let resumeLoad: [Item] = wanted.contains(.continueWatching) ? ((try? await client.resume(limit: 16)) ?? []) : []
        async let nextUpLoad: [Item] = wanted.contains(.nextUp) || theme.settings.mergeNextUp ? ((try? await client.nextUp(limit: 16)) ?? []) : []
        async let favoritesLoad: [Item] = wanted.contains(.favorites) ? await Self.favorites(client) : []
        async let collectionsLoad: [Item] = wanted.contains(.collections) ? await Self.collections(client) : []
        async let genresLoad: [Item] = wanted.contains(.genres) ? ((try? await client.genres(parentId: nil, types: ["Movie", "Series"])) ?? []) : []

        var shelves: [LatestShelf] = []
        if wanted.contains(.latest) {
            await withTaskGroup(of: (Int, LatestShelf?).self) { group in
                for (index, view) in views.enumerated() where view.collectionType != "boxsets" {
                    group.addTask {
                        let items = (try? await client.latest(parentId: view.id, limit: 16)) ?? []
                        return (index, items.isEmpty ? nil : LatestShelf(library: view, items: items))
                    }
                }
                var collected: [(Int, LatestShelf)] = []
                for await (index, shelf) in group {
                    if let shelf { collected.append((index, shelf)) }
                }
                shelves = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }

        let results = await (featuredLoad, resumeLoad, nextUpLoad, favoritesLoad, collectionsLoad, genresLoad)
        // A server that answered nothing at all is probably unreachable.
        if views.isEmpty && results.0.isEmpty && results.1.isEmpty {
            do {
                _ = try await client.views()
            } catch {
                self.error = JellyfinError.from(error).localizedDescription
                loaded = true
                return
            }
        }
        error = nil
        featured = results.0
        if heroIndex >= featured.count { heroIndex = 0 }
        resume = results.1
        nextUp = results.2
        favorites = results.3
        collections = results.4
        genres = results.5
        latest = shelves
        loaded = true
        #if DEBUG
        ScreenshotDriver.noteLoaded("home")
        #endif
    }

    /** Recently added films and shows that have a backdrop to show off. */
    private static func featured(_ client: JellyfinClient) async -> [Item] {
        var query = ItemQuery(includeTypes: ["Movie", "Series"])
        query.sortBy = ["DateCreated"]
        query.descending = true
        query.imageTypes = ["Backdrop"]
        query.limit = 10
        query.fields = ItemFields.card + ["Taglines"]
        query.imageTypeLimit = 1
        let items = (try? await client.items(query).items) ?? []
        return items.filter { $0.backdropImage != nil }
    }

    private static func favorites(_ client: JellyfinClient) async -> [Item] {
        var query = ItemQuery(includeTypes: ["Movie", "Series", "BoxSet", "Episode"])
        query.filters = ["IsFavorite"]
        query.sortBy = ["SortName"]
        query.limit = 24
        return (try? await client.items(query).items) ?? []
    }

    private static func collections(_ client: JellyfinClient) async -> [Item] {
        var query = ItemQuery(includeTypes: ["BoxSet"])
        query.sortBy = ["SortName"]
        query.limit = 24
        return (try? await client.items(query).items) ?? []
    }
}

/**
 * The big carousel at the top of Home: each title's backdrop across the
 * screen, its logo, a line about it, and Play / More. Moves on by itself
 * every few seconds unless you're swiping.
 */
private struct HeroCarousel: View {
    @Environment(\.kinema) private var theme
    let items: [Item]
    @Binding var index: Int
    @State private var interacting = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    HeroPage(item: item, width: width)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? theme.colors.ink : theme.colors.ink4)
                            .frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                .animation(theme.spring, value: index)
                .padding(.bottom, 2)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in interacting = true }.onEnded { _ in interacting = false })
        }
        .frame(height: Self.height)
        .task(id: index) {
            // On by itself, unless someone is swiping or motion is reduced.
            guard !theme.reduceMotion, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled, !interacting else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
    }

    static var height: CGFloat {
        let screen = UIScreen.main.bounds
        let width = min(screen.width, screen.height)
        return min(640, max(470, width * 1.32))
    }
}

private struct HeroPage: View {
    @Environment(\.kinema) private var theme
    let item: Item
    let width: CGFloat

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        ZStack(alignment: .bottom) {
            ArtworkImage(image: item.backdropImage, width: 1280, label: item.name)
                .frame(width: width, height: HeroCarousel.height)
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: c.background.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.45),
                    .init(color: c.background.opacity(0.8), location: 0.78),
                    .init(color: c.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 10) {
                if let logo = item.logoImage {
                    LogoImage(image: logo, maxWidth: min(300, width * 0.72), maxHeight: 110)
                } else {
                    Text(item.name)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(c.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                }
                HStack(spacing: 6) {
                    Text(meta)
                        .font(KFont.labelMedium)
                        .foregroundStyle(c.ink2)
                        .lineLimit(1)
                    DownloadBadge(item: item, size: 13)
                }
                GlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        WideGlassButton(title: graph.library.resumeTicks(item) > 0 ? "Resume" : "Play", icon: "play.fill", prominent: true) {
                            graph.actions.play(item)
                        }
                        .frame(maxWidth: 190)
                        GlassIconButton(icon: "info", size: 48, label: "More about \(item.name)") {
                            graph.actions.open(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 26)
        }
        .frame(width: width, height: HeroCarousel.height)
        .contentShape(Rectangle())
        .onTapGesture { graph.actions.open(item) }
    }

    private var meta: String {
        var parts: [String] = []
        parts.append(item.kind == .series ? "Series" : "Film")
        if let year = item.yearText { parts.append(year) }
        if let genres = item.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        if item.kind != .series, item.runtime > 0 { parts.append(Format.runtime(item.runtime)) }
        return parts.joined(separator: " · ")
    }
}

/** The round button at the top of Home: who's signed in, and switching accounts. */
struct AccountButton: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let auth = AppGraph.shared.auth
        let ui = AppGraph.shared.ui
        Menu {
            if let active = auth.active {
                Section("\(active.username) on \(active.serverName)") {
                    ForEach(auth.profiles.filter { $0.id != active.id }) { profile in
                        Button { auth.switchTo(profile.id) } label: {
                            Label("\(profile.username) · \(profile.serverName)", systemImage: "person.crop.circle")
                        }
                    }
                }
            }
            Button { ui.login = LoginRequest() } label: {
                Label("Add a server or user", systemImage: "plus")
            }
            Button { AppGraph.shared.actions.selectTab(.settings); AppGraph.shared.actions.navigate(.settings(.accounts)) } label: {
                Label("Accounts", systemImage: "person.2")
            }
        } label: {
            ZStack {
                Text(Format.initials(auth.active?.username ?? "?"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.colors.ink)
                if let user = auth.user, let client = auth.client, let url = client.userImageURL(user, maxWidth: 120) {
                    RemoteImage(url: url, pixelSize: 120).clipShape(Circle())
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .kinemaGlass(Circle(), interactive: true)
        .accessibilityLabel("Account")
    }
}
