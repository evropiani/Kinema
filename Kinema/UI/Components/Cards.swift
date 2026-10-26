import SwiftUI

/** The long-press menu every card shares: play, watched, favourite, download, go to the series. */
struct ItemMenu: View {
    let item: Item

    var body: some View {
        let graph = AppGraph.shared
        let library = graph.library
        let played = library.isPlayed(item)
        let favorite = library.isFavorite(item)
        if item.isPlayable || item.kind == .series || item.kind == .season {
            Button { graph.actions.play(item) } label: {
                Label(library.resumeTicks(item) > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            if library.resumeTicks(item) > 0 {
                Button { graph.actions.play(item, fromStart: true) } label: {
                    Label("Play from the beginning", systemImage: "backward.end.fill")
                }
            }
        }
        if item.kind != .person {
            Button { graph.actions.setPlayed(item, !played) } label: {
                Label(played ? "Mark as unwatched" : "Mark as watched", systemImage: played ? "eye.slash" : "checkmark.circle")
            }
            Button { graph.actions.setFavorite(item, !favorite) } label: {
                Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart")
            }
        }
        if item.isPlayable && graph.downloads.record(item.id) == nil {
            Button { graph.actions.download([item]) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        } else if item.kind == .series || item.kind == .season {
            if graph.downloads.coverage(of: item) != .full {
                Button { graph.actions.downloadAll(in: item, onlyUnwatched: true) } label: {
                    Label("Download unwatched episodes", systemImage: "arrow.down.circle")
                }
            }
            Button { graph.actions.downloadAll(in: item) } label: {
                Label("Download all episodes", systemImage: "arrow.down.circle")
            }
        }
        if item.kind == .episode, item.seriesId != nil {
            Button { graph.actions.openSeries(of: item) } label: {
                Label("Go to \(item.seriesName ?? "series")", systemImage: "tv")
            }
        }
        if item.kind == .episode || item.isPlayable {
            Button { graph.actions.open(item) } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
    }
}

/** A portrait poster with its title underneath: films, shows, seasons, collections. */
struct PosterCard: View {
    @Environment(\.kinema) private var theme
    let item: Item
    var subtitle: String?
    var showTitle = true

    var body: some View {
        let library = AppGraph.shared.library
        let progress = library.progress(item)
        let played = library.isPlayed(item)
        let shape = RoundedRectangle(cornerRadius: theme.radii.sm, style: .continuous)
        Button { AppGraph.shared.actions.open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { ArtworkImage(image: item.posterImage, width: 360, label: item.name, icon: icon) }
                    .overlay(alignment: .topTrailing) {
                        WatchedBadge(played: played, unplayed: item.kind == .series || item.kind == .season ? item.unplayedCount : nil)
                            .padding(6)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            WatchProgress(value: progress).padding(.horizontal, 8).padding(.bottom, 8)
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(theme.colors.line, lineWidth: 0.5))
                    .shadow(color: .black.opacity(theme.colors.dark ? 0.35 : 0.12), radius: 8, y: 4)
                if showTitle {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.name)
                                .font(KFont.titleSmall)
                                .foregroundStyle(theme.colors.ink)
                                .lineLimit(1)
                            DownloadBadge(item: item)
                        }
                        if let line = subtitle ?? defaultSubtitle {
                            Text(line)
                                .font(KFont.bodySmall)
                                .foregroundStyle(theme.colors.ink3)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu { ItemMenu(item: item) }
        .accessibilityLabel(item.name)
    }

    private var icon: String {
        switch item.kind {
        case .series, .season, .episode: return "tv"
        case .boxSet: return "square.stack"
        case .person: return "person.fill"
        default: return "film"
        }
    }

    private var defaultSubtitle: String? {
        switch item.kind {
        case .series: return item.yearText
        case .season: return item.childCount.map { Format.count($0, "episode") }
        case .episode: return [item.episodeLabel, item.seriesName].compactMap { $0 }.joined(separator: " · ")
        case .boxSet: return item.childCount.map { Format.count($0, "title") }
        default: return item.yearText
        }
    }
}

/**
 * A wide card for something being watched: the episode's still (or the
 * film's backdrop), how far it got, and what it is. Tapping it carries on
 * playing.
 */
struct LandscapeCard: View {
    @Environment(\.kinema) private var theme
    let item: Item
    /** Play when tapped (Continue Watching, Next Up), rather than open the page. */
    var plays = true

    var body: some View {
        let library = AppGraph.shared.library
        let progress = library.progress(item)
        let shape = RoundedRectangle(cornerRadius: theme.radii.md, style: .continuous)
        Button {
            if plays { AppGraph.shared.actions.play(item) } else { AppGraph.shared.actions.open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ArtworkImage(image: item.landscapeImage ?? item.posterImage, width: 540, label: item.seriesName ?? item.name) }
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 8) {
                            if plays {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(.black.opacity(0.35)))
                                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                            }
                            if let remaining = remainingText(progress) {
                                Text(remaining)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, progress == nil ? 9 : 16)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            WatchProgress(value: progress, height: 3).padding(.horizontal, 10).padding(.bottom, 8)
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(theme.colors.line, lineWidth: 0.5))
                    .shadow(color: .black.opacity(theme.colors.dark ? 0.35 : 0.12), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(item.kind == .episode ? (item.seriesName ?? item.name) : item.name)
                            .font(KFont.titleSmall)
                            .foregroundStyle(theme.colors.ink)
                            .lineLimit(1)
                        // For an episode, whether this episode is downloaded: it's what the card plays.
                        DownloadBadge(item: item)
                    }
                    Text(detail)
                        .font(KFont.bodySmall)
                        .foregroundStyle(theme.colors.ink3)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu { ItemMenu(item: item) }
        .accessibilityLabel(item.kind == .episode ? "\(item.seriesName ?? ""), \(item.name)" : item.name)
    }

    private var detail: String {
        if item.kind == .episode {
            return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return [item.yearText, item.genres?.first].compactMap { $0 }.joined(separator: " · ")
    }

    private func remainingText(_ progress: Double?) -> String? {
        guard let progress, item.runtime > 0 else { return nil }
        return Format.remaining(item.runtime * (1 - progress))
    }
}

/**
 * Next to a title: filled when it's downloaded (for a show or season, every
 * episode not watched yet), dotted when only some of its episodes are.
 */
struct DownloadBadge: View {
    @Environment(\.kinema) private var theme
    let item: Item
    var size: CGFloat = 14
    /** The accent, unless it sits on the accent (a selected season). */
    var color: Color?

    var body: some View {
        switch AppGraph.shared.downloads.coverage(of: item) {
        case .none:
            EmptyView()
        case .full:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color ?? theme.colors.accent)
                .accessibilityLabel("Downloaded")
        case .partial:
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color ?? theme.colors.accent)
                .accessibilityLabel("Partly downloaded")
        }
    }
}

/** A round portrait with a name: cast and crew. */
struct PersonCard: View {
    @Environment(\.kinema) private var theme
    let person: Person

    var body: some View {
        Button { AppGraph.shared.actions.navigate(.person(id: person.id, name: person.name)) } label: {
            VStack(spacing: 6) {
                ArtworkImage(image: person.image, width: 240, label: person.name, icon: "person.fill")
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(theme.colors.line, lineWidth: 0.5))
                VStack(spacing: 1) {
                    Text(person.name)
                        .font(KFont.labelMedium)
                        .foregroundStyle(theme.colors.ink)
                        .lineLimit(1)
                    if let role = person.role, !role.isEmpty {
                        Text(role)
                            .font(KFont.labelSmall)
                            .foregroundStyle(theme.colors.ink3)
                            .lineLimit(1)
                    } else if let type = person.type, !person.isCast {
                        Text(type)
                            .font(KFont.labelSmall)
                            .foregroundStyle(theme.colors.ink3)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel([person.name, person.role].compactMap { $0 }.joined(separator: ", "))
    }
}

/** A titled horizontal row of cards, with "See all" when there is more. */
struct MediaShelf<Card: View>: View {
    @Environment(\.kinema) private var theme
    let title: String
    var icon: String?
    let items: [Item]
    var cardWidth: CGFloat = 128
    var seeAll: (() -> Void)?
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title, icon: icon) {
                    if let seeAll {
                        Button(action: seeAll) {
                            HStack(spacing: 3) {
                                Text("See all")
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            }
                            .font(KFont.labelLarge)
                            .foregroundStyle(theme.colors.accent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            card(item).frame(width: cardWidth)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
            .padding(.top, 10)
        }
    }
}

/** The small marks for what a file is: 4K, Dolby Vision, Atmos, 5.1, subtitles. */
struct MediaBadges: View {
    @Environment(\.kinema) private var theme
    let source: MediaSource?

    var body: some View {
        let badges = Self.badges(source)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.colors.ink2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.colors.ink3, lineWidth: 1))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func badges(_ source: MediaSource?) -> [String] {
        guard let source else { return [] }
        var result: [String] = []
        if let video = source.videoStream {
            if let resolution = Format.resolution(width: video.width, height: video.height), resolution != "SD" {
                result.append(resolution == "4K" ? "4K" : resolution == "1080p" || resolution == "1440p" ? "HD" : resolution)
            }
            if let range = Format.dynamicRange(video.videoRangeType) { result.append(range == "Dolby Vision" ? "DOLBY VISION" : range) }
        }
        let audio = source.audioStreams
        if audio.contains(where: { $0.audioSpatialFormat == "DolbyAtmos" || ($0.profile ?? "").lowercased().contains("atmos") }) {
            result.append("ATMOS")
        } else if audio.contains(where: { $0.audioSpatialFormat == "DTSX" }) {
            result.append("DTS:X")
        }
        if let channels = audio.compactMap(\.channels).max(), channels >= 6, let label = Format.channels(channels) {
            result.append(label)
        }
        if !source.subtitleStreams.isEmpty { result.append("CC") }
        return result
    }
}
