import SwiftUI

/**
 * Downloads: what is coming down, and what is on the phone (films, and shows
 * grouped by series). Everything here plays with no connection.
 */
struct DownloadsScreen: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let downloads = graph.downloads
        let active = downloads.active
        let done = downloads.records.filter(\.isDone)
        let movies = done.filter { $0.item.kind != .episode }
        let series = Dictionary(grouping: done.filter { $0.item.kind == .episode }) { $0.item.seriesId ?? $0.item.seriesName ?? "" }
            .map { (id: $0.key, records: $0.value) }
            .sorted { ($0.records.first?.item.seriesName ?? "") < ($1.records.first?.item.seriesName ?? "") }
        List {
            if !graph.network.online {
                Section {
                    Label("You're offline. Everything here still plays.", systemImage: "wifi.slash")
                        .font(KFont.bodyMedium)
                        .foregroundStyle(theme.colors.ink2)
                }
                .listRowBackground(theme.colors.glass)
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { record in
                        DownloadRow(record: record)
                    }
                } header: {
                    HStack {
                        Text(downloads.allPaused ? "Paused" : downloads.waitingForWiFi ? "Waiting for Wi-Fi" : "Downloading")
                        Spacer()
                        if active.contains(where: { $0.state != .failed }) {
                            Button {
                                Haptics.tap()
                                if downloads.allPaused { downloads.resumeAll() } else { downloads.pauseAll() }
                            } label: {
                                Label(downloads.allPaused ? "Resume All" : "Pause All", systemImage: downloads.allPaused ? "play.fill" : "pause.fill")
                                    .font(KFont.labelLarge)
                                    .textCase(nil)
                                    .foregroundStyle(theme.colors.accent)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    if downloads.waitingForWiFi {
                        Text("Downloading on mobile data is turned off in Settings → Downloads.")
                    }
                }
            }
            if !movies.isEmpty {
                Section("Films & Videos") {
                    ForEach(movies) { record in
                        DownloadRow(record: record)
                    }
                    .onDelete { offsets in
                        for index in offsets { downloads.remove(movies[index].id) }
                    }
                }
            }
            if !series.isEmpty {
                Section("Shows") {
                    ForEach(series, id: \.id) { group in
                        let first = group.records[0]
                        Button {
                            graph.actions.navigate(.downloadedSeries(seriesId: group.id, name: first.item.seriesName ?? "Show"))
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkImage(image: first.item.posterImage, width: 200, label: first.item.seriesName, icon: "tv", localURL: downloads.imageURL(first.posterFile))
                                    .frame(width: 52, height: 78)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(first.item.seriesName ?? "Show").font(KFont.titleSmall).foregroundStyle(theme.colors.ink)
                                    Text("\(Format.count(group.records.count, "episode")) · \(Format.fileSize(group.records.reduce(0) { $0 + $1.bytes }))")
                                        .font(KFont.bodySmall)
                                        .foregroundStyle(theme.colors.ink3)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.colors.ink3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            if downloads.records.isEmpty {
                Section {
                    EmptyState(
                        icon: "arrow.down.circle",
                        title: "No downloads yet",
                        message: "Tap Download on a film or an episode to watch it without a connection. Choose the quality in Settings → Downloads."
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack {
                        Text("On this iPhone")
                        Spacer()
                        Text(Format.fileSize(downloads.usedBytes)).foregroundStyle(theme.colors.ink3)
                    }
                    .font(KFont.bodyMedium)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Downloads")
        .kinemaScreen()
        .onAppear { downloads.syncWatched() }
    }
}

/** One download: its picture, name, size and state; tap to play, swipe to delete. */
struct DownloadRow: View {
    @Environment(\.kinema) private var theme
    let record: DownloadRecord

    var body: some View {
        let graph = AppGraph.shared
        let downloads = graph.downloads
        let item = record.item
        let c = theme.colors
        Button {
            if record.isDone { graph.player.openOffline(record) }
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(image: item.kind == .episode ? item.landscapeImage : item.posterImage, width: 300, label: item.name, localURL: downloads.imageURL(item.kind == .episode ? record.backdropFile : record.posterFile))
                    .frame(width: item.kind == .episode ? 112 : 52, height: item.kind == .episode ? 63 : 78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if record.isDone, let ticks = Optional(record.resumeTicks), ticks > 0, item.runtime > 0 {
                            WatchProgress(value: Ticks.seconds(ticks) / item.runtime, height: 3).padding(4)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    if item.kind == .episode {
                        Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(KFont.labelSmall)
                            .foregroundStyle(c.ink3)
                            .lineLimit(1)
                    }
                    Text(item.name).font(KFont.titleSmall).foregroundStyle(c.ink).lineLimit(2)
                    switch record.state {
                    case .done:
                        Text([Format.fileSize(record.bytes), record.quality == .original && record.kind == .original ? "Original" : record.quality.label, record.pendingSync ? "Not synced yet" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(KFont.bodySmall)
                            .foregroundStyle(c.ink3)
                    case .failed:
                        Text(record.error ?? "Failed").font(KFont.bodySmall).foregroundStyle(c.danger).lineLimit(2)
                    case .queued:
                        Text(downloads.waitingForWiFi ? "Waiting for Wi-Fi" : "Waiting…").font(KFont.bodySmall).foregroundStyle(c.ink3)
                    case .downloading, .paused:
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressBar(value: record.progress, height: 4)
                                .opacity(record.state == .paused ? 0.45 : 1)
                            Text(([
                                record.progress > 0 ? "\(Int(record.progress * 100))%" : nil,
                                record.bytes > 0 ? Format.fileSize(record.bytes) : nil,
                                record.state == .paused ? "Paused" : downloads.waitingForWiFi ? "Waiting for Wi-Fi" : nil,
                            ] as [String?]).compactMap { $0 }.joined(separator: " · "))
                                .font(KFont.bodySmall.monospacedDigit())
                                .foregroundStyle(c.ink3)
                        }
                    }
                }
                Spacer(minLength: 0)
                if record.isDone {
                    Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(c.accent)
                } else if record.state == .failed {
                    Button { downloads.retry(record.id) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 26)).foregroundStyle(c.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Try again")
                } else {
                    // Pause or carry on with this one.
                    let paused = record.state == .paused
                    Button {
                        Haptics.tap()
                        if paused { downloads.resume(record.id) } else { downloads.pause(record.id) }
                    } label: {
                        Image(systemName: paused ? "play.circle.fill" : "pause.circle.fill").font(.system(size: 26)).foregroundStyle(c.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(paused ? "Resume" : "Pause")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .swipeActions {
            Button(role: .destructive) { downloads.remove(record.id) } label: {
                Label(record.isDone ? "Delete" : "Cancel", systemImage: "trash")
            }
        }
        .contextMenu {
            if record.isDone {
                Button { graph.player.openOffline(record) } label: { Label("Play", systemImage: "play.fill") }
                Button { graph.player.openOffline(record, startTicks: 0) } label: { Label("Play from the beginning", systemImage: "backward.end.fill") }
            }
            if !record.isDone && record.state != .failed {
                if record.state == .paused {
                    Button { downloads.resume(record.id) } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { downloads.pause(record.id) } label: { Label("Pause", systemImage: "pause.fill") }
                }
            }
            if graph.auth.client != nil && graph.network.online {
                Button { graph.actions.open(item) } label: { Label("Details", systemImage: "info.circle") }
                if record.isDone {
                    Button {
                        Task {
                            let result = await downloads.refreshSubtitles(record.id, force: true)
                            let added = result?.added ?? 0
                            graph.messages.show(added == 0 ? "No new subtitles on the server" : added == 1 ? "1 new subtitle saved" : "\(added) new subtitles saved", added > 0 ? .success : .info)
                        }
                    } label: {
                        Label("Get New Subtitles", systemImage: "captions.bubble")
                    }
                }
            }
            Button(role: .destructive) { downloads.remove(record.id) } label: {
                Label(record.isDone ? "Delete download" : "Cancel download", systemImage: "trash")
            }
        }
    }
}

/** One show's downloaded episodes. */
struct DownloadedSeriesScreen: View {
    let seriesId: String
    let name: String

    var body: some View {
        let downloads = AppGraph.shared.downloads
        let episodes = downloads.records
            .filter { $0.isDone && ($0.item.seriesId ?? $0.item.seriesName ?? "") == seriesId }
            .sorted { ($0.item.parentIndexNumber ?? 0, $0.item.indexNumber ?? 0) < ($1.item.parentIndexNumber ?? 0, $1.item.indexNumber ?? 0) }
        List {
            ForEach(episodes) { DownloadRow(record: $0) }
                .onDelete { offsets in
                    for index in offsets { downloads.remove(episodes[index].id) }
                }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(name)
        .kinemaScreen()
    }
}

/** Before downloading: the quality, with what each means. */
struct DownloadOptionsSheet: View {
    @Environment(\.kinema) private var theme
    let items: [Item]
    let onDone: () -> Void
    @State private var quality: DownloadQuality = AppGraph.shared.settings.settings.downloadQuality

    var body: some View {
        let c = theme.colors
        let runtime = items.reduce(0) { $0 + $1.runtime }
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? "Download “\(items[0].name)”" : "Download \(Format.count(items.count, "episode"))")
                .font(KFont.titleLarge)
                .foregroundStyle(c.ink)
                .lineLimit(2)
            VStack(spacing: 4) {
                ForEach(DownloadQuality.allCases, id: \.self) { option in
                    Button {
                        Haptics.select()
                        quality = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(KFont.titleSmall).foregroundStyle(c.ink)
                                Text(hint(option, runtime: runtime)).font(KFont.bodySmall).foregroundStyle(c.ink3)
                            }
                            Spacer()
                            Image(systemName: quality == option ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(quality == option ? c.accent : c.ink4)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: theme.radii.sm, style: .continuous).fill(quality == option ? c.glassStrong : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            WideGlassButton(title: "Download", icon: "arrow.down.circle.fill", prominent: true) {
                AppGraph.shared.downloads.download(items, quality: quality)
                onDone()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ option: DownloadQuality, runtime: Double) -> String {
        guard let bitrate = option.maxBitrate else {
            return "The file as it is (MKV and other formats are repackaged by the server, without losing quality)."
        }
        let bytes = Int64(Double(bitrate) / 8 * runtime)
        return runtime > 0 ? "Converted by the server · about \(Format.fileSize(bytes))" : "Converted by the server"
    }
}
