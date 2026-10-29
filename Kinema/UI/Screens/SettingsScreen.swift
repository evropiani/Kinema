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
                link(.general, "General", "gearshape.fill", 0x8E8E93)
                link(.appearance, "Appearance", "paintbrush.fill", 0x8A7CF0)
                link(.home, "Home Page", "house.fill", 0x4AA8D8)
            }
            Section {
                link(.playback, "Playback", "play.rectangle.fill", 0xE5734A)
                link(.gestures, "Player", "hand.draw.fill", 0x4BB38A)
                link(.subtitles, "Subtitles", "captions.bubble.fill", 0xE2B13C)
                link(.capture, "Screenshots & GIFs", "camera.fill", 0xD9536F)
            }
            Section {
                link(.downloads, "Downloads", "arrow.down.circle.fill", 0x6F8FEF)
                link(.storage, "Storage", "internaldrive.fill", 0x636366)
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
            case .general: GeneralPage()
            case .appearance: AppearancePage()
            case .home: HomePage()
            case .playback: PlaybackPage()
            case .gestures: PlayerPage()
            case .subtitles: SubtitlesPage()
            case .capture: CapturePage()
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
    @State private var quickConnect = false

    var body: some View {
        let graph = AppGraph.shared
        let auth = graph.auth
        List {
            Section {
                ForEach(auth.profiles) { profile in
                    Group {
                        if profile.id == auth.activeId {
                            // The account in use: Quick Connect signs another device in as it.
                            HStack(spacing: 12) {
                                accountText(profile, active: true)
                                Spacer(minLength: 8)
                                Button {
                                    Haptics.tap()
                                    quickConnect = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "key.fill").font(.system(size: 13, weight: .semibold))
                                        Text("Quick Connect").font(KFont.labelLarge).lineLimit(1)
                                    }
                                    .fixedSize()
                                    .foregroundStyle(theme.colors.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(theme.colors.accentSoft))
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.borderless)
                                .layoutPriority(1)
                                .accessibilityHint("Sign in another device with the code it shows")
                            }
                        } else {
                            Button { auth.switchTo(profile.id) } label: {
                                HStack {
                                    accountText(profile, active: false)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { confirmSignOut = profile } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                }
            } footer: {
                Text(auth.profiles.count > 1
                     ? "Tap an account to switch to it. Each account keeps its own downloads. Swipe one to sign out of it. Quick Connect signs in another device, such as a TV, with the code it shows."
                     : "Quick Connect signs in another device, such as a TV, with the code it shows. Swipe the account to sign out of it.")
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
        .sheet(isPresented: $quickConnect) {
            QuickConnectSheet()
                .environment(\.kinema, theme)
                .presentationDetents([.medium, .large])
        }
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

extension AccountsPage {
    private func accountText(_ profile: ServerProfile, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(profile.username).font(KFont.titleSmall).foregroundStyle(theme.colors.ink)
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.accent)
                        .accessibilityLabel("In use")
                }
            }
            Text("\(profile.serverName) · \(profile.host)")
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink3)
                .lineLimit(2)
        }
    }
}

/**
 * Quick Connect, from this side: the TV or computer that wants to sign in
 * shows a code, and entering it here signs it in as the account in use.
 */
private struct QuickConnectSheet: View {
    @Environment(\.kinema) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var enabled: Bool?
    @State private var working = false
    @State private var failure: String?
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        VStack(spacing: 18) {
            Image(systemName: done ? "checkmark.circle.fill" : "key.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(done ? c.success : c.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(c.accentSoft))
                .contentTransition(.symbolEffect(.replace))
            Text(done ? "Signed In" : "Quick Connect")
                .font(KFont.headlineSmall.weight(.semibold))
                .foregroundStyle(c.ink)
            Group {
                if done {
                    Text("The other device is now signed in as \(graph.auth.active?.username ?? "you").")
                } else if enabled == false {
                    Text("Quick Connect is turned off on this server. An administrator can turn it on in the Dashboard, under General.")
                } else {
                    Text("On the TV, computer or phone you want to sign in, choose Quick Connect. Then type the code it shows here.")
                }
            }
            .font(KFont.bodyMedium)
            .foregroundStyle(c.ink2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if !done && enabled != false {
                TextField("Code", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(10)); failure = nil }))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .kerning(6)
                    .foregroundStyle(c.ink)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.glass))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(failure == nil ? c.edge : c.danger, lineWidth: 1))
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(authorize)
                if let failure {
                    Text(failure).font(KFont.bodySmall).foregroundStyle(c.danger).multilineTextAlignment(.center)
                }
                WideGlassButton(title: working ? "Signing In…" : "Sign In Device", icon: "checkmark", prominent: true, enabled: code.count >= 6 && !working, action: authorize)
            } else {
                WideGlassButton(title: "Done", icon: "checkmark", prominent: done) { dismiss() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(c.elevated.ignoresSafeArea())
        .tint(c.accent)
        .task {
            enabled = await graph.auth.client?.quickConnectEnabled() ?? false
            if enabled == true { focused = true }
        }
    }

    private func authorize() {
        guard code.count >= 6, !working, let client = AppGraph.shared.auth.client else { return }
        working = true
        failure = nil
        Task {
            do {
                try await client.quickConnectAuthorize(code: code)
                Haptics.success()
                withAnimation(theme.spring) { done = true }
                focused = false
            } catch {
                switch JellyfinError.from(error) {
                case .notFound, .server(400, _):
                    failure = "That code isn't right, or it ran out. Check it, or start Quick Connect again on the other device."
                case .unauthorized, .forbidden:
                    failure = "The server didn't allow it. Quick Connect may be turned off there."
                case let other:
                    failure = other.localizedDescription
                }
            }
            working = false
        }
    }
}

// ---------------------------------------------------------------- general --

private struct GeneralPage: View {
    @Environment(\.kinema) private var theme
    @State private var counts: ItemCounts?
    @State private var scanning = false

    var body: some View {
        let graph = AppGraph.shared
        let store = graph.settings
        List {
            Section {
                Toggle("Hide spoilers", isOn: setting(\.hideSpoilers))
            } footer: {
                Text("Hides the descriptions and pictures of episodes you haven't watched yet.")
            }
            Section {
                Picker("Sort libraries by", selection: Binding(
                    get: { store.settings.defaultSort },
                    set: { raw in store.update {
                        $0.defaultSort = raw
                        $0.defaultSortDescending = LibrarySort(rawValue: raw)?.naturallyDescending ?? false
                    } }
                )) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Order", selection: setting(\.defaultSortDescending)) {
                    Text("Ascending").tag(false)
                    Text("Descending").tag(true)
                }
            } header: {
                Text("Browsing")
            } footer: {
                Text("How the Library is sorted when it opens; ascending is A to Z, oldest or lowest first. Each library can still be sorted its own way.")
            }
            Section {
                Toggle("Ask before streaming on mobile data", isOn: setting(\.askOnCellular))
            } footer: {
                Text("Downloads always play without asking.")
            }
            if !graph.library.views.isEmpty {
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
                    Text("Libraries")
                } footer: {
                    Text("Libraries turned off don't show in the Library tab or on Home.")
                }
            }
            Section {
                if let counts {
                    LabeledContent("Films", value: counts.movies.formatted())
                    LabeledContent("Shows", value: counts.series.formatted())
                    LabeledContent("Episodes", value: counts.episodes.formatted())
                    if counts.collections > 0 { LabeledContent("Collections", value: counts.collections.formatted()) }
                } else {
                    ProgressView()
                }
                if graph.auth.isAdmin {
                    Button {
                        Task {
                            scanning = true
                            do {
                                try await graph.auth.client?.scanLibraries()
                                graph.messages.show("The server is scanning your libraries.", .success)
                            } catch {
                                graph.messages.error(JellyfinError.from(error).localizedDescription)
                            }
                            scanning = false
                        }
                    } label: {
                        HStack {
                            Text("Scan All Libraries")
                            Spacer()
                            if scanning { ProgressView() }
                        }
                    }
                    .disabled(scanning)
                }
            } header: {
                Text("Your Library")
            } footer: {
                Text("Watched, progress and favourites are kept on your server, so they're the same on every device. Film and show details come from the server, in the language set there.")
            }
        }
        .navigationTitle("General")
        .task {
            await graph.library.loadViews()
            counts = try? await graph.auth.client?.itemCounts()
        }
    }
}

// ------------------------------------------------------------- appearance --

private struct AppearancePage: View {
    @Environment(\.kinema) private var theme

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
                Picker("Corners", selection: setting(\.corners)) {
                    ForEach(CornerStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Poster size", selection: setting(\.posterSize)) {
                    ForEach(PosterSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                PosterSizePreview(size: s.posterSize)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            } header: {
                Text("Shape")
            } footer: {
                Text("Poster size sets how big posters are everywhere: in the Library (\(s.posterSize.columns) to a row on iPhone), on Home, in search and on actors' pages.")
            }
            Section {
                Toggle("Blurred artwork behind title pages", isOn: setting(\.backdrops))
                Toggle("Reduce motion", isOn: setting(\.reduceMotion))
            } footer: {
                Text("With blurred artwork on, the page of a film, show or actor sits on a soft, darkened copy of its picture instead of the plain background. Reduce motion stops the carousel on Home from moving by itself and calms the animations.")
            }
        }
        .navigationTitle("Appearance")
    }
}

/** A row of posters at the chosen size, so the setting shows what it does. */
private struct PosterSizePreview: View {
    @Environment(\.kinema) private var theme
    let size: PosterSize

    var body: some View {
        let width = theme.posterWidth * 0.62
        let spacing: CGFloat = 8
        GeometryReader { proxy in
            // As many as fit across the row, like a shelf on Home.
            let count = max(1, Int((proxy.size.width + spacing) / (width + spacing)))
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: theme.radii.xs, style: .continuous)
                        .fill(LinearGradient(colors: [theme.colors.accent.opacity(0.7 - Double(i % 6) * 0.08), theme.colors.accent.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                        .frame(width: width, height: width * 1.5)
                }
            }
        }
        .frame(height: width * 1.5)
        .animation(theme.spring, value: size)
        .accessibilityHidden(true)
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
                Text("Drag to reorder. Which libraries appear is set in General → Libraries.")
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
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Home Page")
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
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Maximum cache")
                        Spacer()
                        Text(cacheLabel(s.maxCacheMB)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(s.maxCacheMB) },
                        set: { value in AppGraph.shared.settings.update { $0.maxCacheMB = Int((value / 100).rounded()) * 100 } }
                    ), in: 0...4000, step: 100)
                }
                Toggle("Preload the next episode", isOn: setting(\.preloadNextEpisode))
            } header: {
                Text("Loading")
            } footer: {
                Text("The maximum cache is how much video Kinema loads ahead while you watch: more rides out a shaky connection and uses more memory; Automatic lets iOS decide. Preloading gets the next episode ready near the end of the one playing, so it starts at once.")
            }
            Section("Starting") {
                Picker("Resume", selection: setting(\.resume)) {
                    ForEach(ResumeBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Default speed", selection: setting(\.defaultSpeed)) {
                    ForEach(Settings.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                Toggle("Always remember the playback speed", isOn: setting(\.rememberSpeed))
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
                Text("Continuous playback")
            } footer: {
                Text("Up Next appears when the credits start (when the server knows where they are, or you've marked them), or near the end.")
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
                Toggle("Find intros and credits online", isOn: setting(\.onlineSegments))
            } header: {
                Text("Skipping")
            } footer: {
                Text("Kinema uses the intros and credits your server knows (Jellyfin 10.10 and later, with a plugin such as Intro Skipper). Where it knows none, Kinema looks the episode or film up in TheIntroDB and IntroDB, free databases of intro and credit times kept by their users, by its TMDB, TVDB or IMDb id. You can also mark them yourself in the player (•••), for every episode of a show. Switch all of this, and automatic skipping, on and off in the player's ••• menu too.")
            }
            Section("Language") {
                Picker("Audio", selection: setting(\.audioLanguage)) {
                    Text("As set on the server").tag("")
                    ForEach(Languages.common, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section {
                let device = DeviceSupport.capabilities
                if device.hevc { Toggle("HEVC (H.265) and HDR", isOn: setting(\.allowHEVC)) }
                if device.dolbyVision && s.allowHEVC { Toggle("Dolby Vision", isOn: setting(\.allowDolbyVision)) }
                if device.av1 { Toggle("AV1", isOn: setting(\.allowAV1)) }
            } header: {
                Text("Hardware decoding")
            } footer: {
                Text("This device: \(DeviceSupport.summary). Turn a format off if videos in it stutter or show no picture; the server then converts them to H.264, which plays everywhere.")
            }
            Section {
                Toggle("Picture in Picture when leaving", isOn: setting(\.autoPiP))
                Toggle("Background playback", isOn: setting(\.backgroundAudio))
            } header: {
                Text("Leaving the app")
            } footer: {
                Text("With background playback on, the sound carries on while Kinema is in the background (when Picture in Picture doesn't start).")
            }
        }
        .navigationTitle("Playback")
    }

    private func cacheLabel(_ megabytes: Int) -> String {
        if megabytes == 0 { return "Automatic" }
        if megabytes >= 1000 { return String(format: "%.1f GB", Double(megabytes) / 1000) }
        return "\(megabytes) MB"
    }
}

private struct PlayerPage: View {
    var body: some View {
        let s = AppGraph.shared.settings.settings
        List {
            Section {
                Picker("Hide the controls after", selection: setting(\.controlsHideDelay)) {
                    ForEach(Settings.hideDelays, id: \.self) { Text($0 == 0 ? "Never" : "\($0) seconds").tag($0) }
                }
                Toggle("Shadow behind the controls", isOn: setting(\.controlsShadow))
                Picker("Next to the progress bar", selection: setting(\.showRemaining)) {
                    Text("Length").tag(false)
                    Text("Time left").tag(true)
                }
                Toggle("Landscape by default", isOn: setting(\.landscapeByDefault))
                Toggle("Screenshot and GIF buttons", isOn: setting(\.showCaptureButtons))
                Toggle("Skip Intro and Skip Credits buttons", isOn: setting(\.showSkipButtons))
                Toggle("Previous and next episode buttons", isOn: setting(\.showEpisodeButtons))
            } header: {
                Text("Controls")
            } footer: {
                Text("With landscape off, the player turns with the phone.")
            }
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
                if s.seekGesture {
                    Picker("Seek sensitivity", selection: setting(\.seekSensitivity)) {
                        ForEach(SeekSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Pinch to fill the screen", isOn: setting(\.pinchToZoom))
            }
        }
        .navigationTitle("Player")
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
                Picker("Prefer subtitles", selection: setting(\.subtitleSource)) {
                    ForEach(SubtitleSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Load subtitles inside the video", isOn: setting(\.loadEmbeddedSubtitles))
            } header: {
                Text("When")
            } footer: {
                Text("Which subtitles come on by themselves. Separate files are the .srt, .ass and similar files next to the video on your server. With subtitles inside the video off, only separate files come on by themselves; you can still pick any track in the player.")
            }
            Section {
                Picker("Search in", selection: setting(\.onlineSubtitleLanguage)) {
                    Text("The subtitle language").tag("")
                    ForEach(Languages.common, id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: {
                Text("Online search")
            } footer: {
                Text("The language the player's Find Subtitles starts with. It remembers the last one you chose.")
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

private struct CapturePage: View {
    var body: some View {
        List {
            Section {
                Picker("Screenshot format", selection: setting(\.screenshotFormat)) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("JPEG is the most compatible, PNG keeps every pixel, HEIC is smallest.")
            }
            Section {
                Picker("Frame rate", selection: setting(\.gifFrameRate)) {
                    ForEach(Settings.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Width", selection: setting(\.gifWidth)) {
                    ForEach(Settings.gifWidths, id: \.self) { Text("\($0) pixels").tag($0) }
                }
            } header: {
                Text("GIFs")
            } footer: {
                Text("Record a GIF in the player with the record button (or ••• → Record a GIF); it stops by itself after ten seconds. More frames and pixels make bigger files.")
            }
        }
        .navigationTitle("Screenshots & GIFs")
    }
}

private struct DownloadsPage: View {
    @State private var confirm = false

    var body: some View {
        let downloads = AppGraph.shared.downloads
        let s = AppGraph.shared.settings.settings
        List {
            Section {
                Picker("Quality", selection: setting(\.downloadQuality)) {
                    ForEach(DownloadQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Audio language", selection: setting(\.downloadAudioLanguage)) {
                    Text("As for watching").tag("")
                    ForEach(Languages.common, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Save subtitles with downloads", isOn: setting(\.downloadSubtitles))
                Toggle("Add subtitles found later", isOn: setting(\.saveNewSubtitles))
            } footer: {
                Text("Original keeps the file as it is, with all its languages. Files iOS can't play as they are (MKV and the like) are repackaged by the server, and its copy keeps one language: the one chosen here or when downloading. The other qualities are converted by the server and take less space. Subtitles found later, online in the player or added on the server, are saved with a download the next time it's played with a connection.")
            }
            Section {
                Picker("Keep the next episodes", selection: Binding(
                    get: { s.keepNextEpisodes },
                    set: { count in
                        AppGraph.shared.settings.update { $0.keepNextEpisodes = count }
                        Task { await downloads.keepNextEpisodes() }
                    }
                )) {
                    ForEach(Settings.keepNextOptions, id: \.self) { count in
                        Text(count == 0 ? "Off" : Format.count(count, "episode")).tag(count)
                    }
                }
                if s.keepNextEpisodes > 0 {
                    Toggle("Delete them once watched", isOn: setting(\.removeWatchedDownloads))
                }
            } header: {
                Text("Shows you're watching")
            } footer: {
                Text(s.keepNextEpisodes > 0
                     ? "For every show you've downloaded an episode of, Kinema keeps the next \(Format.count(s.keepNextEpisodes, "episode")) after the last one you watched downloaded, and fetches more as you watch. Episodes you downloaded yourself are never deleted by this."
                     : "Kinema can keep the next episodes of the shows you've downloaded ready, and fetch more as you watch.")
            }
            Section {
                Toggle("Download on mobile data", isOn: Binding(
                    get: { s.downloadOnCellular },
                    set: { on in
                        AppGraph.shared.settings.update { $0.downloadOnCellular = on }
                        downloads.cellularSettingChanged()
                    }
                ))
                Stepper("At the same time: \(s.concurrentDownloads)", value: setting(\.concurrentDownloads), in: 1...5)
                Toggle("Pause while a video plays", isOn: setting(\.pauseDownloadsWhilePlaying))
                Toggle("Show progress over the tab bar", isOn: setting(\.showDownloadIndicator))
            } footer: {
                Text("With mobile data off, downloads wait for Wi-Fi, also while Kinema is closed. Pausing keeps the connection free for what you're watching. The progress strip takes you to Downloads when tapped.")
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
        let graph = AppGraph.shared
        List {
            Section {
                LabeledContent("Artwork cache", value: Format.fileSize(Int64(artwork)))
                Button("Clear Artwork Cache") {
                    ImageLoader.shared.clearDisk()
                    artwork = ImageLoader.shared.diskUsage
                    graph.messages.show("Cleared", .success)
                }
            } footer: {
                Text("Posters and backdrops are kept so pages open quickly and show offline. They come back as you browse.")
            }
            Section {
                LabeledContent("Downloads", value: Format.fileSize(graph.downloads.usedBytes))
                NavigationLink("Manage Downloads", value: Route.settings(.downloads))
            }
            if graph.onlineSegments.count > 0 {
                Section {
                    LabeledContent("Intros and credits found online", value: Format.count(graph.onlineSegments.count, "title"))
                    Button("Forget Them") {
                        graph.onlineSegments.clearAll()
                        graph.messages.show("Cleared", .success)
                    }
                } footer: {
                    Text("Kept so they're there offline and each title is looked up once. They're looked up again when played.")
                }
            }
            if !graph.markers.all.isEmpty {
                Section {
                    LabeledContent("Intro and credit marks", value: Format.count(graph.markers.all.count, "show"))
                    Button("Clear All Marks", role: .destructive) {
                        graph.markers.clearAll()
                        graph.messages.show("Cleared", .success)
                    }
                } footer: {
                    Text("The marks you set in the player for shows whose intros and credits the server doesn't know.")
                }
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
