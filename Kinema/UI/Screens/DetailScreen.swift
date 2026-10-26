import SwiftUI

/** Whether a detail page's title has scrolled up under the navigation bar. */
private struct HeaderGoneKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/**
 * A title's page: films, shows, seasons, episodes and collections. The
 * backdrop fills the top and stretches when pulled; the page takes its
 * colour from the artwork.
 */
struct DetailScreen: View {
    @Environment(\.kinema) private var theme
    let seed: Item

    @State private var item: Item
    @State private var loaded = false
    @State private var failed: String?
    @State private var seasons: [Item] = []
    @State private var seasonId: String?
    @State private var episodes: [Item] = []
    @State private var episodesLoading = false
    @State private var nextUp: Item?
    @State private var similar: [Item] = []
    @State private var extras: [Item] = []
    @State private var children: [Item] = []
    @State private var sourceId: String?
    @State private var titleShown = false
    @State private var overviewOpen = false

    init(seed: Item) {
        self.seed = seed
        _item = State(initialValue: seed)
    }

    var body: some View {
        let graph = AppGraph.shared
        let current = graph.library.current(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(item: current)
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock(current)
                    actions(current)
                    about(current)
                    if current.kind == .series || current.kind == .season { episodesSection }
                    if current.kind == .episode { seasonShelf(current) }
                    if current.kind == .boxSet { collectionGrid }
                    castShelf(current)
                    MediaShelf(title: "Extras", icon: "film.stack", items: extras, cardWidth: 240) { LandscapeCard(item: $0) }
                    MediaShelf(title: "More Like This", icon: "sparkles", items: similar, cardWidth: theme.posterWidth) { PosterCard(item: $0) }
                    infoSection(current)
                    mediaSection(current)
                }
                .padding(.bottom, 40)
            }
        }
        .coordinateSpace(name: "detail")
        .ignoresSafeArea(edges: .top)
        .onPreferenceChange(HeaderGoneKey.self) { gone in
            if gone != titleShown { withAnimation(theme.ease) { titleShown = gone } }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(titleShown ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(current.name)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)
                    .lineLimit(1)
                    .opacity(titleShown ? 1 : 0)
            }
        }
        .kinemaScreen(backdrop: current.backdropImage ?? current.posterImage)
        .artworkTint(current.backdropImage ?? current.posterImage)
        .task(id: "\(seed.id)-\(graph.library.version)") { await load() }
    }

    // ------------------------------------------------------------ the top --

    private func titleBlock(_ item: Item) -> some View {
        let c = theme.colors
        return VStack(spacing: 10) {
            if item.kind == .episode, let series = item.seriesName {
                Button { AppGraph.shared.actions.openSeries(of: item) } label: {
                    HStack(spacing: 4) {
                        Text(series)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(KFont.labelLarge)
                    .foregroundStyle(c.accent)
                }
                .buttonStyle(PressableStyle())
            }
            if let logo = item.logoImage, item.kind != .episode {
                LogoImage(image: logo, maxWidth: 290, maxHeight: 120)
                    .accessibilityLabel(item.name)
            } else {
                Text(item.kind == .episode ? item.name : item.name)
                    .font(.system(size: item.name.count > 28 ? 26 : 32, weight: .heavy))
                    .foregroundStyle(c.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Text(metaLine(item))
                .font(KFont.labelLarge)
                .foregroundStyle(c.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let genres = item.genres, !genres.isEmpty, item.kind != .episode {
                Text(genres.prefix(3).joined(separator: " · "))
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    .lineLimit(1)
            }
            MediaBadges(source: source(item))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, -70)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderGoneKey.self, value: proxy.frame(in: .global).minY < 60)
            }
        )
    }

    private func metaLine(_ item: Item) -> String {
        var parts: [String] = []
        if item.kind == .episode, let label = Format.episodeLong(item) { parts.append(label) }
        if let year = item.yearText, item.kind != .episode { parts.append(year) }
        if item.kind == .episode, let date = Format.date(item.premiereDate) { parts.append(date) }
        if let rating = item.officialRating, !rating.isEmpty { parts.append(rating) }
        if item.kind == .series {
            if let count = item.childCount, count > 0 { parts.append(Format.count(count, "season")) }
        } else if item.runtime > 0 {
            parts.append(Format.runtime(item.runtime))
        }
        if let score = Format.rating(item.communityRating) { parts.append("★ \(score)") }
        if let critics = item.criticRating, critics > 0 { parts.append("🍅 \(Int(critics))%") }
        return parts.joined(separator: "  ·  ")
    }

    private func source(_ item: Item) -> MediaSource? {
        item.mediaSources?.first { $0.id == sourceId } ?? item.mediaSources?.first
    }

    // ------------------------------------------------------------ actions --

    private func actions(_ item: Item) -> some View {
        let graph = AppGraph.shared
        let library = graph.library
        let c = theme.colors
        let target = playTarget(item)
        let resumeTicks = target.map { library.resumeTicks($0) } ?? 0
        let resume = resumeTicks > 0 && theme.settings.resume != .restart
        let played = library.isPlayed(item)
        let favorite = library.isFavorite(item)
        return VStack(spacing: 14) {
            Button {
                Haptics.tap()
                if let target {
                    graph.actions.play(target, mediaSourceId: target.id == item.id ? sourceId : nil)
                } else {
                    graph.actions.play(item)
                }
            } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(playLabel(item, target: target, resume: resume))
                            .lineLimit(1)
                    }
                    .font(.system(size: 17, weight: .bold))
                    if resume, let target, let progress = library.progress(target) {
                        HStack(spacing: 8) {
                            WatchProgress(value: progress, height: 3).frame(width: 70)
                            Text(Format.remaining(target.runtime * (1 - progress)))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .opacity(0.85)
                    }
                }
                .foregroundStyle(glassTints ? .white : c.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: resume ? 60 : 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(glassTints ? .clear : c.accent))
            .kinemaGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: c.accent, interactive: true, shadow: false)
            .accessibilityLabel(playLabel(item, target: target, resume: resume))

            GlassGroup(spacing: 14) {
                HStack(spacing: 0) {
                    actionButton(played ? "checkmark.circle.fill" : "checkmark.circle", played ? "Watched" : "Unwatched", on: played) {
                        graph.actions.setPlayed(item, !played)
                    }
                    actionButton(favorite ? "heart.fill" : "heart", "Favorite", on: favorite) {
                        graph.actions.setFavorite(item, !favorite)
                    }
                    if item.isPlayable || item.kind == .series || item.kind == .season {
                        downloadButton(item)
                    }
                    if (item.localTrailerCount ?? 0) > 0 || !(item.remoteTrailers ?? []).isEmpty {
                        actionButton("film", "Trailer", on: false) { graph.actions.playTrailer(item) }
                    }
                    moreMenu(item, resumeTicks: resumeTicks, target: target)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var glassTints: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /** What the big button plays: the item, or for a series the next episode. */
    private func playTarget(_ item: Item) -> Item? {
        switch item.kind {
        case .series: return nextUp ?? episodes.first { !AppGraph.shared.library.isPlayed($0) } ?? episodes.first
        case .season: return episodes.first { !AppGraph.shared.library.isPlayed($0) } ?? episodes.first
        case .boxSet: return children.first { $0.isPlayable && !AppGraph.shared.library.isPlayed($0) } ?? children.first { $0.isPlayable }
        default: return item.isPlayable ? item : nil
        }
    }

    private func playLabel(_ item: Item, target: Item?, resume: Bool) -> String {
        let verb = resume ? "Resume" : "Play"
        if (item.kind == .series || item.kind == .season), let target, let label = target.episodeLabel {
            return "\(verb) \(label)"
        }
        if item.kind == .boxSet, let target { return "\(verb) \(target.name)" }
        return verb
    }

    private func actionButton(_ icon: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? c.accent : c.ink)
                    .frame(width: 48, height: 48)
                    .kinemaGlass(Circle(), tint: on ? c.accent.opacity(0.3) : nil, interactive: true, shadow: false)
                Text(label)
                    .font(KFont.labelSmall)
                    .foregroundStyle(c.ink2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func downloadButton(_ item: Item) -> some View {
        let graph = AppGraph.shared
        if item.isPlayable, let record = graph.downloads.record(item.id) {
            let icon = record.isDone ? "arrow.down.circle.fill" : record.state == .failed ? "exclamationmark.circle" : "arrow.down.circle.dotted"
            Menu {
                if record.isDone {
                    Button { graph.player.openOffline(record) } label: { Label("Play the download", systemImage: "play.fill") }
                }
                Button(role: .destructive) { graph.downloads.remove(item.id) } label: {
                    Label(record.isDone ? "Remove download" : "Cancel download", systemImage: "trash")
                }
            } label: {
                actionLabel(icon, record.isDone ? "Downloaded" : record.state == .failed ? "Failed" : "\(Int(record.progress * 100))%", on: record.isDone)
            }
        } else if item.isPlayable {
            actionButton("arrow.down.circle", "Download", on: false) { graph.actions.download([item]) }
        } else {
            // A show or season: which episodes to download, and how much of it is here already.
            let coverage = graph.downloads.coverage(of: item)
            let unwatched = item.unplayedCount ?? 0
            Menu {
                Section(coverage == .none ? "Download" : coverage == .full ? "Every unwatched episode is downloaded" : "Some episodes are downloaded") {
                    if coverage != .full {
                        Button { graph.actions.downloadAll(in: item, onlyUnwatched: true) } label: {
                            Label(unwatched > 0 ? "Unwatched episodes (\(unwatched))" : "Unwatched episodes", systemImage: "eye.slash")
                        }
                    }
                    Button { graph.actions.downloadAll(in: item) } label: {
                        Label(item.kind == .season ? "The whole season" : "All episodes", systemImage: "square.stack")
                    }
                }
                if coverage != .none {
                    Button { graph.actions.selectTab(.downloads) } label: { Label("Go to Downloads", systemImage: "arrow.down.to.line") }
                }
            } label: {
                switch coverage {
                case .none: actionLabel("arrow.down.circle", "Download", on: false)
                case .partial: actionLabel("arrow.down.circle.dotted", "Partly", on: false)
                case .full: actionLabel("arrow.down.circle.fill", "Downloaded", on: true)
                }
            }
        }
    }

    private func actionLabel(_ icon: String, _ label: String, on: Bool) -> some View {
        let c = theme.colors
        return VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? c.accent : c.ink)
                .frame(width: 48, height: 48)
                .kinemaGlass(Circle(), tint: on ? c.accent.opacity(0.3) : nil, interactive: true, shadow: false)
            Text(label)
                .font(KFont.labelSmall)
                .foregroundStyle(c.ink2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func moreMenu(_ item: Item, resumeTicks: Int64, target: Item?) -> some View {
        let graph = AppGraph.shared
        let sources = item.mediaSources ?? []
        return Menu {
            if resumeTicks > 0, let target {
                Button { graph.actions.play(target, fromStart: true, mediaSourceId: sourceId) } label: {
                    Label("Play from the beginning", systemImage: "backward.end.fill")
                }
            }
            if sources.count > 1 {
                Picker("Version", selection: Binding(get: { sourceId ?? sources.first?.id }, set: { sourceId = $0 })) {
                    ForEach(sources) { source in
                        Text(source.name ?? source.summary).tag(Optional(source.id))
                    }
                }
            }
            if item.kind == .episode {
                Button { graph.actions.openSeries(of: item) } label: { Label("Go to \(item.seriesName ?? "series")", systemImage: "tv") }
            }
            if let url = webURL(item) {
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                Link(destination: url) { Label("Open in Jellyfin Web", systemImage: "safari") }
            }
            if let imdb = item.imdbId, let url = URL(string: "https://www.imdb.com/title/\(imdb)") {
                Link(destination: url) { Label("IMDb", systemImage: "link") }
            }
            if let tmdb = item.tmdbId, let url = URL(string: "https://www.themoviedb.org/\(item.kind == .series ? "tv" : "movie")/\(tmdb)") {
                Link(destination: url) { Label("TMDB", systemImage: "link") }
            }
            if graph.auth.isAdmin {
                Button {
                    Task {
                        do {
                            try await graph.auth.client?.refreshMetadata(item.id)
                            graph.messages.show("The server is refreshing \(item.name)'s details.", .success)
                        } catch {
                            graph.messages.error(JellyfinError.from(error).localizedDescription)
                        }
                    }
                } label: {
                    Label("Refresh details and artwork", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            actionLabel("ellipsis", "More", on: false)
        }
    }

    private func webURL(_ item: Item) -> URL? {
        guard let base = AppGraph.shared.auth.client?.baseURL.absoluteString else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/web/#/details?id=\(item.id)&serverId=\(item.serverId ?? "")")
    }

    // ------------------------------------------------------------- about --

    @ViewBuilder
    private func about(_ item: Item) -> some View {
        let c = theme.colors
        let tagline = item.taglines?.first
        if tagline != nil || !(item.overview ?? "").isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.system(size: 16, weight: .semibold).italic())
                        .foregroundStyle(c.ink)
                }
                if let overview = item.overview, !overview.isEmpty, item.kind == .episode, theme.settings.hideSpoilers, !AppGraph.shared.library.isPlayed(item), !overviewOpen {
                    Button { withAnimation(theme.ease) { overviewOpen = true } } label: {
                        Label("Description hidden to avoid spoilers · Show", systemImage: "eye.slash")
                            .font(KFont.labelLarge)
                            .foregroundStyle(c.accent)
                    }
                    .buttonStyle(PressableStyle())
                } else if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(KFont.bodyMedium)
                        .foregroundStyle(c.ink2)
                        .lineLimit(overviewOpen ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(theme.ease) { overviewOpen.toggle() } }
                    if overview.count > 220 {
                        Text(overviewOpen ? "Less" : "More")
                            .font(KFont.labelLarge)
                            .foregroundStyle(c.accent)
                            .onTapGesture { withAnimation(theme.ease) { overviewOpen.toggle() } }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
        }
    }

    // ----------------------------------------------------------- episodes --

    @ViewBuilder
    private var episodesSection: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        if !seasons.isEmpty || !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(seasons.count > 1 ? "Seasons" : "Episodes")
                        .font(KFont.titleLarge)
                        .foregroundStyle(c.ink)
                    Spacer()
                    if let season = seasons.first(where: { $0.id == seasonId }) {
                        Menu {
                            Button { graph.actions.setPlayed(season, true) } label: { Label("Mark season as watched", systemImage: "checkmark.circle") }
                            Button { graph.actions.setPlayed(season, false) } label: { Label("Mark season as unwatched", systemImage: "eye.slash") }
                            Button { graph.actions.downloadAll(in: season, onlyUnwatched: true) } label: { Label("Download unwatched episodes", systemImage: "arrow.down.circle") }
                            Button { graph.actions.downloadAll(in: season) } label: { Label("Download season", systemImage: "arrow.down.circle") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(c.ink2)
                                .frame(width: 44, height: 44)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                if seasons.count > 1 {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons) { season in
                                    let on = season.id == seasonId
                                    Button {
                                        Haptics.select()
                                        seasonId = season.id
                                        Task { await loadEpisodes() }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(season.name).lineLimit(1)
                                            if graph.library.isPlayed(season) {
                                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                            }
                                            DownloadBadge(item: season, size: 13, color: on ? c.onAccent : nil)
                                        }
                                        .font(KFont.labelLarge)
                                        .foregroundStyle(on ? c.onAccent : c.ink)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 9)
                                        .background(Capsule().fill(on ? c.accent : c.glass))
                                        .overlay(Capsule().strokeBorder(on ? .clear : c.edge, lineWidth: 1))
                                    }
                                    .buttonStyle(PressScaleStyle())
                                    .id(season.id)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                        }
                        .onAppear { if let seasonId { reader.scrollTo(seasonId, anchor: .center) } }
                        .onChange(of: seasonId) { _, id in
                            if let id { withAnimation(theme.ease) { reader.scrollTo(id, anchor: .center) } }
                        }
                    }
                    .padding(.top, 4)
                }
                if episodesLoading && episodes.isEmpty {
                    LoadingView()
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(episodes) { episode in
                            EpisodeRow(episode: episode)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    /** For an episode: the rest of its season, to hop along. */
    @ViewBuilder
    private func seasonShelf(_ item: Item) -> some View {
        if !episodes.isEmpty {
            MediaShelf(title: item.seasonName ?? "This Season", icon: "list.number", items: episodes, cardWidth: 230) { episode in
                LandscapeCard(item: episode, plays: true)
                    .overlay(alignment: .topLeading) {
                        if episode.id == item.id {
                            Text("Now")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(theme.colors.onAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.colors.accent))
                                .padding(8)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var collectionGrid: some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("In This Collection", icon: "square.stack.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.posterGridMinimum, maximum: theme.posterGridMinimum * 1.6), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(children) { PosterCard(item: $0) }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 18)
        }
    }

    // --------------------------------------------------------------- cast --

    @ViewBuilder
    private func castShelf(_ item: Item) -> some View {
        let people = Array(((item.people ?? []).filter { $0.isCast } + item.directors + item.writers).prefix(30))
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader("Cast & Crew", icon: "person.2.fill")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                            PersonCard(person: person)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 18)
        }
    }

    // -------------------------------------------------------------- info --

    @ViewBuilder
    private func infoSection(_ item: Item) -> some View {
        let rows = infoRows(item)
        if !rows.isEmpty || !(item.genres ?? []).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Details", icon: "info.circle.fill").padding(.horizontal, -16)
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.0)
                            .font(KFont.labelLarge)
                            .foregroundStyle(theme.colors.ink3)
                            .frame(width: 96, alignment: .leading)
                        Text(row.1)
                            .font(KFont.bodyMedium)
                            .foregroundStyle(theme.colors.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let genres = item.genres, !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(genres, id: \.self) { genre in
                                Tag(genre) {
                                    AppGraph.shared.actions.navigate(.genre(name: genre, parentId: nil, types: item.kind == .series || item.kind == .episode ? ["Series"] : ["Movie"]))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
        }
    }

    private func infoRows(_ item: Item) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let original = item.originalTitle, !original.isEmpty, original != item.name { rows.append(("Original title", original)) }
        let directors = item.directors.map(\.name)
        if !directors.isEmpty { rows.append((directors.count > 1 ? "Directors" : "Director", directors.joined(separator: ", "))) }
        let writers = item.writers.map(\.name)
        if !writers.isEmpty { rows.append((writers.count > 1 ? "Writers" : "Writer", writers.prefix(4).joined(separator: ", "))) }
        let studios = (item.studios ?? []).compactMap(\.name)
        if !studios.isEmpty { rows.append((item.kind == .series ? "Network" : "Studio", studios.prefix(3).joined(separator: ", "))) }
        if let date = Format.date(item.premiereDate) { rows.append((item.kind == .series ? "First aired" : "Released", date)) }
        if item.kind == .series, let status = item.status { rows.append(("Status", status == "Continuing" ? "Still running" : status)) }
        if let rating = item.officialRating, !rating.isEmpty { rows.append(("Rated", rating)) }
        if let added = Format.date(item.dateCreated) { rows.append(("Added", added)) }
        return rows
    }

    @ViewBuilder
    private func mediaSection(_ item: Item) -> some View {
        if let source = source(item), item.isPlayable {
            let c = theme.colors
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Media", icon: "film.fill").padding(.horizontal, -16)
                if let video = source.videoStream {
                    mediaRow("Video", [video.displayTitle ?? video.detail, video.bitRate.map { Format.bitrate(Double($0)) }].compactMap { $0 }.joined(separator: " · "))
                }
                ForEach(source.audioStreams) { audio in
                    mediaRow(audio.index == source.audioStreams.first?.index ? "Audio" : "", [audio.label, audio.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                let subtitles = source.subtitleStreams
                if !subtitles.isEmpty {
                    mediaRow("Subtitles", subtitles.map(\.label).joined(separator: ", "))
                }
                mediaRow("File", [source.container?.split(separator: ",").first.map { $0.uppercased() }, source.size.map { Format.fileSize($0) }, source.bitrate.map { Format.bitrate(Double($0)) }].compactMap { $0 }.joined(separator: " · "))
                if !StreamResolver.offlinePlayable(source) || !StreamResolver.directPlayIsSafe(source) {
                    Text("Kinema plays this through your server, which repackages it for the iPhone as you watch.")
                        .font(KFont.bodySmall)
                        .foregroundStyle(c.ink3)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
        }
    }

    private func mediaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(KFont.labelLarge)
                .foregroundStyle(theme.colors.ink3)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(KFont.bodyMedium)
                .foregroundStyle(theme.colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ------------------------------------------------------------ loading --

    private func load() async {
        guard let client = AppGraph.shared.auth.client else { return }
        do {
            let full = try await client.item(seed.id)
            item = full
            failed = nil
        } catch {
            if !loaded { failed = JellyfinError.from(error).localizedDescription }
        }
        loaded = true
        let current = item
        async let similarLoad = (try? await client.similar(current.id, limit: 16)) ?? []
        async let extrasLoad: [Item] = (current.specialFeatureCount ?? 0) > 0 ? ((try? await client.specialFeatures(current.id)) ?? []) : []
        switch current.kind {
        case .series:
            async let seasonsLoad = (try? await client.seasons(seriesId: current.id)) ?? []
            async let nextLoad = try? await client.nextUp(seriesId: current.id, limit: 1).first
            let (loadedSeasons, next) = await (seasonsLoad, nextLoad)
            seasons = loadedSeasons
            nextUp = next
            if seasonId == nil || !loadedSeasons.contains(where: { $0.id == seasonId }) {
                seasonId = next?.seasonId ?? loadedSeasons.first { !AppGraph.shared.library.isPlayed($0) && ($0.indexNumber ?? 1) > 0 }?.id ?? loadedSeasons.first?.id
            }
            await loadEpisodes()
        case .season:
            seasonId = current.id
            await loadEpisodes()
        case .episode:
            if let seriesId = current.seriesId {
                episodes = (try? await client.episodes(seriesId: seriesId, seasonId: current.seasonId)) ?? []
            }
        case .boxSet:
            var query = ItemQuery(parentId: current.id)
            query.recursive = false
            query.sortBy = ["ProductionYear", "PremiereDate", "SortName"]
            query.limit = 300
            children = (try? await client.items(query).items) ?? []
        default:
            break
        }
        similar = await similarLoad
        extras = await extrasLoad
        #if DEBUG
        ScreenshotDriver.noteLoaded(current.kind == .series ? "series" : current.kind == .episode ? "episode" : "movie")
        #endif
    }

    private func loadEpisodes() async {
        guard let client = AppGraph.shared.auth.client else { return }
        let seriesId = item.kind == .season ? (item.seriesId ?? item.parentId ?? "") : item.id
        let wanted = seasonId
        episodesLoading = true
        let loaded = (try? await client.episodes(seriesId: seriesId, seasonId: wanted)) ?? []
        if wanted == seasonId {
            episodes = loaded
            episodesLoading = false
        }
    }
}

/** The big picture at the top of a detail page, stretching when the page is pulled down. */
private struct DetailHeader: View {
    @Environment(\.kinema) private var theme
    let item: Item

    var body: some View {
        let c = theme.colors
        let height = Self.height
        GeometryReader { proxy in
            let pull = max(0, proxy.frame(in: .named("detail")).minY)
            ZStack(alignment: .bottom) {
                ArtworkImage(image: image, width: 1280, label: item.name)
                    .frame(width: proxy.size.width, height: height + pull)
                    .clipped()
                LinearGradient(
                    stops: [
                        .init(color: c.background.opacity(0.5), location: 0),
                        .init(color: .clear, location: 0.25),
                        .init(color: .clear, location: 0.45),
                        .init(color: c.background.opacity(0.75), location: 0.8),
                        .init(color: c.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: height + pull)
            .offset(y: -pull)
        }
        .frame(height: height)
    }

    private var image: ImageRef? {
        if item.kind == .episode { return item.image(.primary) ?? item.backdropImage }
        return item.backdropImage ?? item.image(.primary)
    }

    static var height: CGFloat {
        let screen = UIScreen.main.bounds
        let width = min(screen.width, screen.height)
        return min(560, max(380, width * 1.05))
    }
}

/** One episode in a season's list: its still, number and name, length, and what happens in it. Tapping plays it. */
struct EpisodeRow: View {
    @Environment(\.kinema) private var theme
    let episode: Item

    var body: some View {
        let graph = AppGraph.shared
        let library = graph.library
        let c = theme.colors
        let progress = library.progress(episode)
        let played = library.isPlayed(episode)
        let shape = RoundedRectangle(cornerRadius: theme.radii.sm, style: .continuous)
        let downloaded = graph.downloads.record(episode.id)?.isDone == true
        Button { graph.actions.play(episode) } label: {
            HStack(alignment: .top, spacing: 12) {
                ArtworkImage(image: episode.image(.primary) ?? episode.landscapeImage, width: 360, label: episode.name, icon: "tv")
                    .frame(width: 148, height: 84)
                    // Hide spoilers: no pictures from episodes not seen yet.
                    .blur(radius: spoiler ? 14 : 0)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.black.opacity(0.35)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                    }
                    .overlay(alignment: .topTrailing) { WatchedBadge(played: played).scaleEffect(0.85).padding(4) }
                    .overlay(alignment: .bottom) {
                        if let progress { WatchProgress(value: progress, height: 3).padding(.horizontal, 6).padding(.bottom, 6) }
                    }
                    .clipShape(shape)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(KFont.titleSmall)
                        .foregroundStyle(c.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(detail)
                        if downloaded {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(c.accent)
                        }
                    }
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    if let overview = episode.overview, !overview.isEmpty, !spoiler {
                        Text(overview)
                            .font(KFont.bodySmall)
                            .foregroundStyle(c.ink2)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu { ItemMenu(item: episode) }
        .accessibilityLabel(title)
    }

    private var title: String {
        if let number = episode.indexNumber { return "\(number). \(episode.name)" }
        return episode.name
    }

    /** Settings → General → Hide spoilers, for an episode not watched yet. */
    private var spoiler: Bool {
        theme.settings.hideSpoilers && !AppGraph.shared.library.isPlayed(episode)
    }

    private var detail: String {
        var parts: [String] = []
        if episode.runtime > 0 { parts.append(Format.runtime(episode.runtime)) }
        if let date = Format.date(episode.premiereDate) { parts.append(date) }
        if let score = Format.rating(episode.communityRating) { parts.append("★ \(score)") }
        return parts.joined(separator: " · ")
    }
}
