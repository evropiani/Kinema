import SwiftUI

/** Settings: a list of native pages, as in Kultr. */
struct SettingsScreen: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let auth = graph.auth
        List {
            if let profile = auth.active {
                Section {
                    NavigationLink(value: Route.settings(.accounts)) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(theme.colors.accentSoft)
                                Text(Format.initials(profile.username)).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.colors.accent)
                                if let user = auth.user, let url = auth.client?.userImageURL(user) {
                                    RemoteImage(url: url, pixelSize: 160).clipShape(Circle())
                                }
                            }
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.username).font(KFont.titleMedium)
                                Text(profile.serverName).font(KFont.bodySmall).foregroundStyle(theme.colors.ink3)
                                Text(profile.host).font(KFont.bodySmall).foregroundStyle(theme.colors.ink3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                link(.appearance, "Appearance", "paintbrush.fill", 0x8A7CF0)
                link(.home, "Home Page", "house.fill", 0x4AA8D8)
            }
            Section {
                link(.playback, "Playback", "play.rectangle.fill", 0xE5734A)
                link(.gestures, "Gestures & Controls", "hand.draw.fill", 0x4BB38A)
                link(.subtitles, "Subtitles", "captions.bubble.fill", 0xE2B13C)
            }
            Section {
                link(.downloads, "Downloads", "arrow.down.circle.fill", 0x6F8FEF)
                link(.storage, "Storage", "internaldrive.fill", 0x8E8E93)
            }
            Section {
                link(.about, "About Kinema", "info.circle.fill", 0x3B4E7B)
            }
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .kinemaScreen()
    }

    private func link(_ page: SettingsPage, _ title: String, _ icon: String, _ color: UInt32) -> some View {
        NavigationLink(value: Route.settings(page)) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(argb: color)))
            }
        }
    }
}

/** One page of Settings. */
struct SettingsPageView: View {
    @Environment(\.kinema) private var theme
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .accounts: AccountsPage()
            case .appearance: AppearancePage()
            case .home: HomePage()
            case .playback: PlaybackPage()
            case .gestures: GesturesPage()
            case .subtitles: SubtitlesPage()
            case .downloads: DownloadsPage()
            case .storage: StoragePage()
            case .about: AboutPage()
            }
        }
        .scrollContentBackground(.hidden)
        .kinemaScreen()
        .navigationBarTitleDisplayMode(.inline)
    }
}

/** A binding into one setting. */
@MainActor
private func setting<T>(_ key: WritableKeyPath<Settings, T>) -> Binding<T> {
    let store = AppGraph.shared.settings
    return Binding(get: { store.settings[keyPath: key] }, set: { value in store.update { $0[keyPath: key] = value } })
}

// --------------------------------------------------------------- accounts --

private struct AccountsPage: View {
    @Environment(\.kinema) private var theme
    @State private var confirmSignOut: ServerProfile?

    var body: some View {
        let graph = AppGraph.shared
        let auth = graph.auth
        List {
            Section {
                ForEach(auth.profiles) { profile in
                    Button { auth.switchTo(profile.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.username).font(KFont.titleSmall).foregroundStyle(theme.colors.ink)
                                Text("\(profile.serverName) · \(profile.host)").font(KFont.bodySmall).foregroundStyle(theme.colors.ink3)
                            }
                            Spacer()
                            if profile.id == auth.activeId {
                                Image(systemName: "checkmark").foregroundStyle(theme.colors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .swipeActions {
                        Button(role: .destructive) { confirmSignOut = profile } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                }
            } footer: {
                Text("Each account keeps its own downloads. Swipe one to sign out of it.")
            }
            Section {
                Button { graph.ui.login = LoginRequest() } label: {
                    Label("Add a server or user", systemImage: "plus.circle.fill")
                }
                if let active = auth.active {
                    Button(role: .destructive) { confirmSignOut = active } label: {
                        Label("Sign out of \(active.username)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            if let version = auth.serverVersion {
                Section("Server") {
                    LabeledContent("Jellyfin", value: version)
                    if auth.isAdmin { LabeledContent("Role", value: "Administrator") }
                }
            }
        }
        .navigationTitle("Accounts")
        .confirmationDialog(
            "Sign out of \(confirmSignOut?.username ?? "")?",
            isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
            titleVisibility: .visible,
            presenting: confirmSignOut
        ) { profile in
            Button("Sign Out and Delete Downloads", role: .destructive) {
                graph.downloads.deleteDataFor(profile.id)
                auth.signOut(profile.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// ------------------------------------------------------------- appearance --

private struct AppearancePage: View {
    @Environment(\.kinema) private var theme

    private static let accents = ["#6F8FEF", "#3B4E7B", "#7C8CFF", "#E5734A", "#FF5F7A", "#E2B13C", "#4BB38A", "#4AA8D8", "#C35BD1", "#FFFFFF"]

    var body: some View {
        let s = AppGraph.shared.settings.settings
        List {
            Section {
                Picker("Theme", selection: setting(\.theme)) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Night mode", isOn: setting(\.nightMode))
            } footer: {
                Text("Night mode turns dark into pure black, for OLED screens.")
            }
            Section {
                Picker("Colour", selection: setting(\.accentMode)) {
                    ForEach(AccentMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.accents, id: \.self) { hex in
                            Button { AppGraph.shared.settings.update { $0.accent = hex } } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .blue)
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().strokeBorder(s.accent.uppercased() == hex ? theme.colors.ink : .clear, lineWidth: 3))
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityLabel(hex)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Accent")
            } footer: {
                Text("From the artwork, each title's page takes its colour from its poster. The chosen colour is used everywhere else.")
            }
            Section("Shape") {
                Picker("Corners", selection: setting(\.corners)) {
                    ForEach(CornerStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Poster size", selection: setting(\.posterSize)) {
                    ForEach(PosterSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Artwork behind pages", isOn: setting(\.backdrops))
                Toggle("Reduce motion", isOn: setting(\.reduceMotion))
            } footer: {
                Text("Reduce motion stops the carousel on Home from moving by itself and calms the animations.")
            }
        }
        .navigationTitle("Appearance")
    }
}

// --------------------------------------------------------------- home page --

private struct HomePage: View {
    @Environment(\.kinema) private var theme
    @State private var editMode: EditMode = .active

    var body: some View {
        let graph = AppGraph.shared
        let store = graph.settings
        let shown = store.settings.homeSections
        let hidden = HomeSection.allCases.filter { !shown.contains($0) }
        List {
            Section {
                ForEach(shown, id: \.self) { section in
                    HStack {
                        Text(section.label)
                        Spacer()
                        Button {
                            store.update { $0.homeSections.removeAll { $0 == section } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(theme.colors.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide \(section.label)")
                    }
                }
                .onMove { from, to in store.update { $0.homeSections.move(fromOffsets: from, toOffset: to) } }
            } header: {
                Text("Shown, in this order")
            } footer: {
                Text("Drag to reorder.")
            }
            if !hidden.isEmpty {
                Section("Hidden") {
                    ForEach(hidden, id: \.self) { section in
                        Button {
                            store.update { $0.homeSections.append(section) }
                        } label: {
                            HStack {
                                Text(section.label).foregroundStyle(theme.colors.ink)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(theme.colors.success)
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("One row for Continue Watching and Next Up", isOn: setting(\.mergeNextUp))
            }
            if !graph.library.videoViews.isEmpty {
                Section {
                    ForEach(graph.library.videoViews) { view in
                        Toggle(view.name, isOn: Binding(
                            get: { !store.settings.hiddenLibraries.contains(view.id) },
                            set: { on in store.update { s in
                                if on { s.hiddenLibraries.removeAll { $0 == view.id } } else { s.hiddenLibraries.append(view.id) }
                            } }
                        ))
                    }
                } header: {
                    Text("Libraries on Home")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Home Page")
        .task { await graph.library.loadViews() }
    }
}

// ---------------------------------------------------------------- playback --

private struct PlaybackPage: View {
    var body: some View {
        let s = AppGraph.shared.settings.settings
        List {
            Section {
                Picker("On Wi-Fi", selection: setting(\.maxBitrateWifi)) {
                    ForEach(StreamingQuality.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("On mobile data", selection: setting(\.maxBitrateCellular)) {
                    ForEach(StreamingQuality.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Play files directly when possible", isOn: setting(\.directPlay))
            } header: {
                Text("Quality")
            } footer: {
                Text("Files over the limit are converted by the server. With direct play off, everything goes through the server, which can help with files that won't play.")
            }
            Section("Starting") {
                Picker("Resume", selection: setting(\.resume)) {
                    ForEach(ResumeBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Default speed", selection: setting(\.defaultSpeed)) {
                    ForEach(Settings.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                Picker("Picture", selection: setting(\.aspect)) {
                    ForEach(AspectMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Play the next episode", isOn: setting(\.autoplayNext))
                if s.autoplayNext {
                    Stepper("Countdown: \(s.upNextCountdown)s", value: setting(\.upNextCountdown), in: 3...30)
                }
            } header: {
                Text("Up Next")
            } footer: {
                Text("Up Next appears when the credits start (when the server knows where they are), or near the end.")
            }
            Section {
                Picker("Intros", selection: setting(\.skipIntro)) {
                    ForEach(SkipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Credits", selection: setting(\.skipCredits)) {
                    ForEach(SkipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Recaps and previews", selection: setting(\.skipRecap)) {
                    ForEach(SkipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Skipping")
            } footer: {
                Text("Uses the media segments Jellyfin 10.10 and later find (with a plugin such as Intro Skipper).")
            }
            Section("Language") {
                Picker("Audio", selection: setting(\.audioLanguage)) {
                    Text("As set on the server").tag("")
                    ForEach(Languages.common, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section {
                Toggle("Picture in Picture when leaving", isOn: setting(\.autoPiP))
                Toggle("Keep playing the sound in the background", isOn: setting(\.backgroundAudio))
            } header: {
                Text("Leaving the app")
            } footer: {
                Text("With Picture in Picture off, the sound can carry on while the app is in the background.")
            }
        }
        .navigationTitle("Playback")
    }
}

private struct GesturesPage: View {
    var body: some View {
        let s = AppGraph.shared.settings.settings
        List {
            Section {
                Toggle("Double-tap the sides to skip", isOn: setting(\.doubleTapSeek))
                Picker("Skip back", selection: setting(\.skipBack)) {
                    ForEach(Settings.skipIntervals, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Skip forward", selection: setting(\.skipForward)) {
                    ForEach(Settings.skipIntervals, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Skipping")
            } footer: {
                Text("Keep tapping after a double tap to skip further.")
            }
            Section {
                Picker("Hold for", selection: setting(\.holdSpeed)) {
                    ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            } header: {
                Text("Hold to speed up")
            } footer: {
                Text("Hold anywhere on the picture to play faster while you hold. Swipe up while holding to keep the speed (now \(String(format: "%g", s.holdSpeed))×).")
            }
            Section("Swipes") {
                Toggle("Brightness (left side, up and down)", isOn: setting(\.brightnessGesture))
                Toggle("Volume (right side, up and down)", isOn: setting(\.volumeGesture))
                Toggle("Seek (left and right)", isOn: setting(\.seekGesture))
                Toggle("Pinch to fill the screen", isOn: setting(\.pinchToZoom))
            }
            Section("Buttons") {
                Toggle("Skip Intro and Skip Credits buttons", isOn: setting(\.showSkipButtons))
                Toggle("Previous and next episode buttons", isOn: setting(\.showEpisodeButtons))
                Toggle("Show the time left instead of the length", isOn: setting(\.showRemaining))
            }
        }
        .navigationTitle("Gestures & Controls")
    }
}

private struct SubtitlesPage: View {
    var body: some View {
        List {
            Section {
                Picker("Show subtitles", selection: setting(\.subtitleMode)) {
                    ForEach(SubtitleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: setting(\.subtitleLanguage)) {
                    Text("As set on the server").tag("")
                    ForEach(Languages.common, id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: {
                Text("When")
            }
            Section {
                SubtitleStylePanel()
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            } header: {
                Text("Style")
            } footer: {
                Text("Text subtitles (SRT, ASS, VTT…) are drawn by Kinema in this style. Picture subtitles (PGS, VobSub) are drawn into the video by the server, as they are.")
            }
        }
        .navigationTitle("Subtitles")
    }
}

private struct DownloadsPage: View {
    @State private var confirm = false

    var body: some View {
        let downloads = AppGraph.shared.downloads
        List {
            Section {
                Picker("Quality", selection: setting(\.downloadQuality)) {
                    ForEach(DownloadQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Download on mobile data", isOn: setting(\.downloadOnCellular))
                Toggle("Save subtitles with downloads", isOn: setting(\.downloadSubtitles))
            } footer: {
                Text("Original keeps the file as it is (repackaged by the server when iOS can't play its format). The other qualities are converted by the server and take less space.")
            }
            Section {
                LabeledContent("Downloaded", value: Format.fileSize(downloads.usedBytes))
                if !downloads.records.isEmpty {
                    Button("Delete All Downloads", role: .destructive) { confirm = true }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Delete all downloads of this account?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { downloads.removeAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct StoragePage: View {
    @State private var artwork = ImageLoader.shared.diskUsage

    var body: some View {
        List {
            Section {
                LabeledContent("Artwork cache", value: Format.fileSize(Int64(artwork)))
                Button("Clear Artwork Cache") {
                    ImageLoader.shared.clearDisk()
                    artwork = ImageLoader.shared.diskUsage
                    AppGraph.shared.messages.show("Cleared", .success)
                }
            } footer: {
                Text("Posters and backdrops are kept so pages open quickly and show offline. They come back as you browse.")
            }
            Section {
                LabeledContent("Downloads", value: Format.fileSize(AppGraph.shared.downloads.usedBytes))
                NavigationLink("Manage Downloads", value: Route.settings(.downloads))
            }
        }
        .navigationTitle("Storage")
    }
}

private struct AboutPage: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let updates = graph.updates
        List {
            Section {
                VStack(spacing: 10) {
                    Image("KinemaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                    Text("Kinema").font(KFont.headlineSmall)
                    Text("Version \(appVersion) (\(appBuild))").font(KFont.bodySmall).foregroundStyle(theme.colors.ink3)
                    Text("A Jellyfin client for iPhone and iPad, in the style of Kultr.")
                        .font(KFont.bodySmall)
                        .foregroundStyle(theme.colors.ink2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Updates") {
                Button {
                    Task {
                        let result = await updates.checkNow()
                        if case .available(let release) = result { graph.ui.update = release }
                    }
                } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        switch updates.check {
                        case .checking: ProgressView()
                        case .upToDate: Text("Up to date").foregroundStyle(theme.colors.ink3)
                        case .available(let release): Text("\(release.version) is out").foregroundStyle(theme.colors.accent)
                        case .failed: Text("Couldn't check").foregroundStyle(theme.colors.danger)
                        case .idle: EmptyView()
                        }
                    }
                }
            }
            Section("This iPhone") {
                LabeledContent("Plays", value: DeviceSupport.summary)
                if let version = graph.auth.serverVersion { LabeledContent("Server", value: "Jellyfin \(version)") }
            }
            Section {
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)/blob/main/docs/INSTALL.md")!) {
                    Label("Installing and refreshing", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!) {
                    Label("Report a problem", systemImage: "exclamationmark.bubble")
                }
                Link(destination: URL(string: "https://kultr.cc")!) {
                    Label("Kultr, for your music", systemImage: "music.note")
                }
            } footer: {
                Text("Free and open source under the Apache License 2.0. Kinema talks only to your own Jellyfin server (and to GitHub, to look for updates).")
            }
        }
        .navigationTitle("About")
    }
}
