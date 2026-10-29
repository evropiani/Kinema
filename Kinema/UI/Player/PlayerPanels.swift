import SwiftUI

/**
 * A panel sliding in from the right of the player: tracks, speed, chapters,
 * episodes, quality, subtitle style and online subtitles. Tapping beside it
 * closes it.
 */
struct PanelHost: View {
    let panel: PlayerPanel

    var body: some View {
        let player = AppGraph.shared.player
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            ZStack(alignment: wide ? .trailing : .bottom) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        if panel == .subtitleStyle || panel == .onlineSubtitles {
                            Button { player.panel = .subtitles } label: {
                                Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityLabel("Back")
                        }
                        Button { close() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                                .background(Circle().fill(.white.opacity(0.12)))
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    ScrollView {
                        content
                            .padding(.horizontal, 12)
                            .padding(.bottom, 24)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: wide ? min(400, proxy.size.width * 0.46) : proxy.size.width, height: wide ? proxy.size.height : min(560, proxy.size.height * 0.62))
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: wide ? 0 : 26, style: .continuous))
                .environment(\.colorScheme, .dark)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func close() {
        let player = AppGraph.shared.player
        player.panel = nil
        player.scheduleHide()
    }

    private var title: String {
        switch panel {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .speed: return "Speed"
        case .chapters: return "Chapters"
        case .episodes: return "Episodes"
        case .quality: return "Quality"
        case .subtitleStyle: return "Subtitle Style"
        case .onlineSubtitles: return "Find Subtitles"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .audio: AudioPanel()
        case .subtitles: SubtitlePanel()
        case .speed: SpeedPanel()
        case .chapters: ChapterPanel()
        case .episodes: EpisodePanel()
        case .quality: QualityPanel()
        case .subtitleStyle: SubtitleStylePanel()
        case .onlineSubtitles: OnlineSubtitlePanel()
        }
    }
}

/** A row in a panel: a title, a detail line, and a tick when chosen. */
private struct PanelRow: View {
    @Environment(\.kinema) private var theme
    let title: String
    var detail: String?
    var chosen = false
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 22).opacity(0.8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: chosen ? .bold : .medium)).lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).opacity(0.6).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.colors.accent)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(chosen ? .white.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct PanelHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .opacity(0.5)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

private struct AudioPanel: View {
    var body: some View {
        let player = AppGraph.shared.player
        // A download the server made holds one language; the others play from the server.
        let copy = player.offline?.kind == .hls
        let inDownload = player.downloadedAudioIndex
        let online = AppGraph.shared.network.online
        VStack(alignment: .leading, spacing: 2) {
            if player.audioStreams.isEmpty {
                Text("This video has no audio track the server describes.").font(.system(size: 14)).opacity(0.7).padding(12)
            }
            ForEach(player.audioStreams) { stream in
                let missing = copy && inDownload != nil && stream.index != inDownload
                PanelRow(
                    title: stream.label,
                    detail: missing ? (online ? "Not in the download · plays from your server" : "Not in the download") : stream.detail,
                    chosen: stream.index == (copy ? inDownload ?? player.audioIndex : player.audioIndex)
                ) {
                    player.selectAudio(stream.index)
                }
                .opacity(missing && !online ? 0.5 : 1)
            }
            if copy && player.audioStreams.count > 1 {
                Text("The server repackaged this download from a format iOS can't play, and it can put only one language into it. Choose the language when downloading.")
                    .font(.system(size: 12))
                    .opacity(0.5)
                    .padding(12)
            } else if player.stream?.method != .directPlay && player.offline == nil && player.audioStreams.count > 1 {
                Text("Changing the language restarts the stream from where you are.")
                    .font(.system(size: 12))
                    .opacity(0.5)
                    .padding(12)
            }
        }
    }
}

private struct SubtitlePanel: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        let streams = player.subtitleStreams
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(title: "Off", chosen: player.subtitleIndex == nil) { player.selectSubtitle(nil) }
            ForEach(streams) { stream in
                PanelRow(title: stream.label, detail: stream.isImageSubtitle ? "\(stream.detail) · drawn in by the server" : stream.detail, chosen: stream.index == player.subtitleIndex) {
                    player.selectSubtitle(stream.index)
                }
            }
            if player.subtitleIndex != nil && !player.burnedIn {
                PanelHeading(text: "Timing")
                HStack(spacing: 10) {
                    stepButton("minus") { player.subtitleDelay -= 0.25 }
                    VStack(spacing: 1) {
                        Text(player.subtitleDelay == 0 ? "In sync" : String(format: "%+.2fs", player.subtitleDelay))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                        Text(player.subtitleDelay > 0 ? "shown later" : player.subtitleDelay < 0 ? "shown earlier" : "as in the file")
                            .font(.system(size: 11)).opacity(0.6)
                    }
                    .frame(maxWidth: .infinity)
                    stepButton("plus") { player.subtitleDelay += 0.25 }
                    if player.subtitleDelay != 0 {
                        Button("Reset") { player.subtitleDelay = 0 }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.colors.accent)
                    }
                }
                .padding(.horizontal, 12)
            }
            let text = streams.filter { !$0.isImageSubtitle }
            if text.count > 1 || (text.count == 1 && player.subtitleIndex != text.first?.index) {
                PanelHeading(text: "Second subtitle")
                PanelRow(title: "None", chosen: player.secondaryIndex == nil) { player.selectSecondary(nil) }
                ForEach(text) { stream in
                    if stream.index != player.subtitleIndex {
                        PanelRow(title: stream.label, detail: stream.detail, chosen: stream.index == player.secondaryIndex) {
                            player.selectSecondary(stream.index)
                        }
                    }
                }
            }
            PanelHeading(text: "More")
            PanelRow(title: "Subtitle style", detail: "Size, colour, outline, position", icon: "textformat.size") { player.panel = .subtitleStyle }
            if player.offline == nil || (AppGraph.shared.network.online && AppGraph.shared.auth.client != nil) {
                PanelRow(title: "Find subtitles online", detail: player.offline == nil ? "Through your server's subtitle providers" : "Saved with the download too", icon: "magnifyingglass") { player.panel = .onlineSubtitles }
            }
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct SpeedPanel: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: "%.2g×", player.speed))
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            Slider(value: Binding(get: { player.speed }, set: { player.setSpeed((($0 * 20).rounded()) / 20) }), in: 0.25...4)
                .tint(theme.colors.accent)
                .padding(.horizontal, 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(Settings.speeds, id: \.self) { value in
                    let on = abs(player.speed - value) < 0.01
                    Button {
                        Haptics.select()
                        player.setSpeed(value)
                    } label: {
                        Text(String(format: "%g×", value))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(on ? theme.colors.onAccent : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? theme.colors.accent : .white.opacity(0.1)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.horizontal, 12)
            Text("Tip: hold anywhere on the picture to play at \(String(format: "%g", AppGraph.shared.settings.settings.holdSpeed))× while you hold; swipe up while holding to keep it.")
                .font(.system(size: 12))
                .opacity(0.55)
                .padding(12)
        }
    }
}

private struct ChapterPanel: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        let current = player.currentChapterIndex
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { index, chapter in
                Button {
                    Haptics.select()
                    player.seek(to: chapter.start)
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let item = player.item, let tag = chapter.imageTag, let url = AppGraph.shared.auth.client?.chapterImageURL(itemId: item.id, index: index, tag: tag) {
                                RemoteImage(url: url, pixelSize: 320)
                            } else {
                                Color.white.opacity(0.08).overlay(Text("\(index + 1)").font(.system(size: 16, weight: .bold)).opacity(0.6))
                            }
                        }
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.name ?? "Chapter \(index + 1)")
                                .font(.system(size: 14, weight: index == current ? .bold : .medium))
                                .lineLimit(2)
                            Text(Format.clock(chapter.start)).font(.system(size: 12).monospacedDigit()).opacity(0.6)
                        }
                        Spacer()
                        if index == current {
                            Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(theme.colors.accent)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(index == current ? .white.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

private struct EpisodePanel: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        VStack(alignment: .leading, spacing: 4) {
            ForEach(player.seasonEpisodes) { episode in
                let current = episode.id == player.item?.id
                let progress = AppGraph.shared.library.progress(episode)
                Button {
                    guard !current else { return }
                    player.panel = nil
                    player.playEpisode(episode)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkImage(image: episode.image(.primary) ?? episode.landscapeImage, width: 320, label: episode.name, icon: "tv")
                            .frame(width: 112, height: 63)
                            .overlay(alignment: .bottom) {
                                if let progress { WatchProgress(value: progress, height: 3).padding(5) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text([episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 14, weight: current ? .bold : .medium))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if episode.runtime > 0 { Text(Format.runtime(episode.runtime)) }
                                if AppGraph.shared.library.isPlayed(episode) { Image(systemName: "checkmark.circle.fill") }
                                if AppGraph.shared.downloads.record(episode.id)?.isDone == true { Image(systemName: "arrow.down.circle.fill") }
                            }
                            .font(.system(size: 12))
                            .opacity(0.6)
                        }
                        Spacer()
                        if current {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(theme.colors.accent)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current ? .white.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

private struct QualityPanel: View {
    var body: some View {
        let player = AppGraph.shared.player
        let current = player.maxBitrateOverride
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(title: "Automatic", detail: "As set in Settings → Playback (\(StreamingQuality.label(AppGraph.shared.maxBitrate == StreamingQuality.maximum ? 0 : AppGraph.shared.maxBitrate)))", chosen: current == nil) {
                player.setQuality(nil)
            }
            ForEach(StreamingQuality.options.filter { $0.0 > 0 }, id: \.0) { option in
                PanelRow(title: option.1, chosen: current == option.0) { player.setQuality(option.0) }
            }
            if let stream = player.stream {
                Text("Now: \(stream.methodLabel)\(stream.source.bitrate.map { " · file \(Format.bitrate(Double($0)))" } ?? ""). A quality lower than the file makes the server convert it.")
                    .font(.system(size: 12))
                    .opacity(0.55)
                    .padding(12)
            }
        }
    }
}

/** Subtitle style, with a live sample. Changes apply everywhere at once. */
struct SubtitleStylePanel: View {
    @Environment(\.kinema) private var theme
    var showsSample = true

    private static let colors = ["#FFFFFF", "#FFF4B0", "#FFD54A", "#9BE7FF", "#B7FFB0", "#FFB3C8"]

    var body: some View {
        let store = AppGraph.shared.settings
        let s = store.settings
        VStack(alignment: .leading, spacing: 4) {
            if showsSample {
                ZStack {
                    LinearGradient(colors: [Color(argb: 0x30405A), Color(argb: 0x8A6A4A)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    SubtitleText(runs: [SubtitleRun(text: "The quick brown fox\njumps over the lazy dog.")], size: 20 * CGFloat(s.subtitleSize / 100), settings: s)
                        .padding(.horizontal, 12)
                }
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
            slider("Size", value: s.subtitleSize, range: 50...200, step: 5, format: "%.0f%%") { v in store.update { $0.subtitleSize = v } }
            PanelHeading(text: "Colour")
            HStack(spacing: 10) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { store.update { $0.subtitleColor = hex } } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .white)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(s.subtitleColor.uppercased() == hex ? theme.colors.accent : .white.opacity(0.3), lineWidth: s.subtitleColor.uppercased() == hex ? 3 : 1))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(hex)
                }
            }
            .padding(.horizontal, 12)
            slider("Outline", value: s.subtitleOutline, range: 0...6, step: 0.5, format: "%.1f") { v in store.update { $0.subtitleOutline = v } }
            slider("Background", value: s.subtitleBackground * 100, range: 0...90, step: 5, format: "%.0f%%") { v in store.update { $0.subtitleBackground = v / 100 } }
            slider("Brightness", value: s.subtitleBrightness * 100, range: 30...100, step: 5, format: "%.0f%%") { v in store.update { $0.subtitleBrightness = v / 100 } }
            slider("Distance from the bottom", value: s.subtitleMargin, range: 0...30, step: 1, format: "%.0f%%") { v in store.update { $0.subtitleMargin = v } }
            PanelHeading(text: "Font")
            Picker("Font", selection: Binding(get: { s.subtitleFont }, set: { v in store.update { $0.subtitleFont = v } })) {
                ForEach(SubtitleFont.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            Toggle("Bold", isOn: Binding(get: { s.subtitleBold }, set: { v in store.update { $0.subtitleBold = v } }))
                .tint(theme.colors.accent)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            PanelHeading(text: "Second subtitle")
            Picker("Second subtitle", selection: Binding(get: { s.secondaryPosition }, set: { v in store.update { $0.secondaryPosition = v } })) {
                ForEach(SecondaryPosition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            slider("Second subtitle size", value: s.secondaryScale * 100, range: 50...120, step: 5, format: "%.0f%%") { v in store.update { $0.secondaryScale = v / 100 } }
            Button("Reset to default") {
                store.update { settings in
                    let d = Settings()
                    settings.subtitleSize = d.subtitleSize
                    settings.subtitleColor = d.subtitleColor
                    settings.subtitleOutline = d.subtitleOutline
                    settings.subtitleBackground = d.subtitleBackground
                    settings.subtitleBold = d.subtitleBold
                    settings.subtitleFont = d.subtitleFont
                    settings.subtitleMargin = d.subtitleMargin
                    settings.subtitleBrightness = d.subtitleBrightness
                    settings.secondaryPosition = d.secondaryPosition
                    settings.secondaryScale = d.secondaryScale
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.colors.accent)
            .padding(12)
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, format: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(String(format: format, value)).font(.system(size: 13, weight: .semibold).monospacedDigit()).opacity(0.7)
            }
            Slider(value: Binding(get: { value }, set: { set(($0 / step).rounded() * step) }), in: range)
                .tint(theme.colors.accent)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

/** Search the server's subtitle providers (OpenSubtitles and friends) and add one. */
private struct OnlineSubtitlePanel: View {
    @Environment(\.kinema) private var theme
    @State private var language = ""
    @State private var results: [RemoteSubtitle] = []
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var downloading: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Languages.common, id: \.0) { pair in
                        Button(pair.1) {
                            language = pair.0
                            // Remembered for next time, as VidHub does.
                            AppGraph.shared.settings.update { $0.onlineSubtitleLanguage = pair.0 }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(Format.languageName(language) ?? "Language")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
                Spacer()
                Button {
                    Task { await search() }
                } label: {
                    Label(searching ? "Searching…" : "Search", systemImage: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.colors.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Capsule().fill(theme.colors.accent))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(searching)
            }
            .padding(.horizontal, 12)
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(theme.colors.danger).padding(12)
            } else if searched && results.isEmpty {
                Text("Nothing found. The server needs a subtitle provider plugin (like OpenSubtitles) for this.")
                    .font(.system(size: 13)).opacity(0.6).padding(12)
            }
            ForEach(results) { result in
                Button {
                    Task { await download(result) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.name ?? "Subtitle").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text(details(result)).font(.system(size: 12)).opacity(0.6).lineLimit(2)
                        }
                        Spacer()
                        if downloading == result.id {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.system(size: 18)).foregroundStyle(theme.colors.accent)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(downloading != nil)
            }
        }
        .onAppear {
            if language.isEmpty {
                let settings = AppGraph.shared.settings.settings
                let fallback = settings.subtitleLanguage.isEmpty ? (AppGraph.shared.auth.user?.configuration?.subtitleLanguagePreference ?? "") : settings.subtitleLanguage
                let preferred = settings.onlineSubtitleLanguage.isEmpty ? fallback : settings.onlineSubtitleLanguage
                language = Languages.normalize(preferred) ?? Languages.normalize(Locale.current.language.languageCode?.identifier) ?? "eng"
            }
        }
    }

    private func details(_ result: RemoteSubtitle) -> String {
        var parts: [String] = []
        if let provider = result.providerName { parts.append(provider) }
        if let format = result.format { parts.append(format.uppercased()) }
        if let count = result.downloadCount { parts.append("\(count) downloads") }
        if result.isHashMatch == true { parts.append("Exact match") }
        if result.hearingImpaired == true { parts.append("SDH") }
        if result.machineTranslated == true { parts.append("Machine-translated") }
        return parts.joined(separator: " · ")
    }

    private func search() async {
        guard let client = AppGraph.shared.auth.client, let item = AppGraph.shared.player.item else { return }
        searching = true
        error = nil
        defer {
            searching = false
            searched = true
        }
        do {
            results = try await client.searchRemoteSubtitles(item.id, language: language)
        } catch JellyfinError.forbidden {
            error = "Your account isn't allowed to manage subtitles on this server."
        } catch {
            self.error = JellyfinError.from(error).localizedDescription
        }
    }

    private func download(_ result: RemoteSubtitle) async {
        guard let client = AppGraph.shared.auth.client, let item = AppGraph.shared.player.item else { return }
        downloading = result.id
        defer { downloading = nil }
        do {
            try await client.downloadRemoteSubtitle(item.id, subtitleId: result.id)
            await AppGraph.shared.player.remoteSubtitleDownloaded()
            AppGraph.shared.player.panel = .subtitles
        } catch {
            self.error = JellyfinError.from(error).localizedDescription
        }
    }
}
