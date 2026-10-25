import SwiftUI

/** An actor's or director's page: their portrait, biography and everything of theirs on the server. */
struct PersonScreen: View {
    @Environment(\.kinema) private var theme
    let id: String
    let name: String
    @State private var person: Item?
    @State private var works: [Item] = []
    @State private var loaded = false
    @State private var bioOpen = false

    var body: some View {
        let c = theme.colors
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 12) {
                    ArtworkImage(image: person?.image(.primary), width: 480, label: name, icon: "person.fill")
                        .frame(width: 156, height: 156)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(c.edge, lineWidth: 1))
                        .shadow(color: .black.opacity(c.dark ? 0.45 : 0.2), radius: 22, y: 12)
                    Text(name)
                        .font(KFont.headlineMedium)
                        .foregroundStyle(c.ink)
                        .multilineTextAlignment(.center)
                    if let line = lifeLine {
                        Text(line)
                            .font(KFont.bodySmall)
                            .foregroundStyle(c.ink3)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

                if let bio = person?.overview, !bio.isEmpty {
                    Text(bio)
                        .font(KFont.bodyMedium)
                        .foregroundStyle(c.ink2)
                        .lineLimit(bioOpen ? nil : 5)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .onTapGesture { withAnimation(theme.ease) { bioOpen.toggle() } }
                }

                if !loaded {
                    LoadingView()
                } else if works.isEmpty {
                    EmptyState(icon: "film", title: "Nothing on this server", message: "There's nothing with \(name) in your libraries.")
                } else {
                    let movies = works.filter { $0.kind == .movie }
                    let shows = works.filter { $0.kind == .series }
                    let other = works.filter { $0.kind != .movie && $0.kind != .series }
                    grid("Movies", movies)
                    grid("Shows", shows)
                    grid("Other", other)
                }
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .kinemaScreen(backdrop: person?.image(.primary))
        .artworkTint(person?.image(.primary))
        .task(id: id) { await load() }
    }

    private var lifeLine: String? {
        guard let person else { return nil }
        var parts: [String] = []
        if let born = Format.date(person.premiereDate) { parts.append("Born \(born)") }
        if let died = Format.date(person.endDate) { parts.append("Died \(died)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func grid(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            SectionHeader(title).padding(.top, 18)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(items) { PosterCard(item: $0) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func load() async {
        guard let client = AppGraph.shared.auth.client else { return }
        async let personLoad = try? await client.item(id)
        var query = ItemQuery(includeTypes: ["Movie", "Series", "Video", "MusicVideo"])
        query.personIds = [id]
        query.sortBy = ["PremiereDate", "ProductionYear", "SortName"]
        query.descending = true
        query.limit = 300
        async let worksLoad = (try? await client.items(query).items) ?? []
        let (loadedPerson, loadedWorks) = await (personLoad, worksLoad)
        person = loadedPerson
        works = loadedWorks
        loaded = true
    }
}
