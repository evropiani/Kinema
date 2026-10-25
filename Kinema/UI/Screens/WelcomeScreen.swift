import SwiftUI

/** The first start: what Kinema is, then connecting to a server. */
struct WelcomeFlow: View {
    @Environment(\.kinema) private var theme
    let onDone: () -> Void
    @State private var connecting = WelcomeFlow.startConnecting

    #if DEBUG
    private static var startConnecting: Bool { ScreenshotDriver.welcomeStep > 0 }
    private static var prefill: String { ScreenshotDriver.serverPrefill ?? "" }
    #else
    private static let startConnecting = false
    private static let prefill = ""
    #endif

    var body: some View {
        ZStack {
            PlainBackdrop()
            if connecting {
                AddServerFlow(prefillUrl: Self.prefill, prefillUser: "", onCancel: AppGraph.shared.auth.profiles.isEmpty ? { withAnimation(theme.ease) { connecting = false } } : onDone, onDone: onDone)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                intro.transition(.opacity)
            }
        }
        .animation(theme.ease, value: connecting)
    }

    private var intro: some View {
        let c = theme.colors
        return VStack(spacing: 0) {
            Spacer()
            Image("KinemaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            Text("Kinema")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(c.ink)
                .padding(.top, 22)
            Text("Your Jellyfin films and shows,\nbeautifully played.")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(c.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 14) {
                feature("play.rectangle.on.rectangle", "Plays everything your server has", "MP4 straight from the file; MKV, HEVC, DTS and picture subtitles repackaged or converted by the server as you watch.")
                feature("hand.draw", "A player made for watching", "Swipe for brightness and volume, double-tap to skip, hold for 2×, Skip Intro, chapters and Up Next.")
                feature("captions.bubble", "Subtitles your way", "Size, colour, outline and position, two languages at once, and a search for missing ones.")
                feature("arrow.down.circle", "Take it with you", "Download films and episodes and watch offline; your progress goes back to the server later.")
            }
            .padding(.top, 34)
            .padding(.horizontal, 28)
            Spacer()
            WideGlassButton(title: "Connect to a server", icon: "server.rack", prominent: true) {
                withAnimation(theme.ease) { connecting = true }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Text("Free and open source. Your password goes only to your server.")
                .font(KFont.bodySmall)
                .foregroundStyle(c.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: 560)
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.colors.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(KFont.titleSmall).foregroundStyle(theme.colors.ink)
                Text(text).font(KFont.bodySmall).foregroundStyle(theme.colors.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/**
 * Connecting to a server: its address, then who you are (a user from the
 * server's list, a password, or a Quick Connect code approved on another
 * device).
 */
struct AddServerFlow: View {
    @Environment(\.kinema) private var theme
    var prefillUrl = ""
    var prefillUser = ""
    var onCancel: (() -> Void)?
    let onDone: () -> Void

    private enum Step: Equatable {
        case server, user
    }

    @State private var step: Step = .server
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var serverURL: URL?
    @State private var system: PublicSystemInfo?
    @State private var users: [UserDto] = []
    @State private var quickConnectAvailable = false
    @State private var quickConnect: QuickConnectResult?
    @State private var quickConnectTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address, username, password
    }

    init(prefillUrl: String = "", prefillUser: String = "", onCancel: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        self.prefillUrl = prefillUrl
        self.prefillUser = prefillUser
        self.onCancel = onCancel
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if step == .user {
                        GlassIconButton(icon: "chevron.left", size: 44, label: "Back") {
                            cancelQuickConnect()
                            withAnimation(theme.ease) {
                                step = .server
                                error = nil
                            }
                        }
                    } else if let onCancel {
                        GlassIconButton(icon: "xmark", size: 44, label: "Cancel", action: onCancel)
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .frame(height: 52)

                if step == .server { serverStep } else { userStep }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if address.isEmpty { address = prefillUrl }
            if username.isEmpty { username = prefillUser }
            if !prefillUrl.isEmpty { connect() }
        }
        .onDisappear { cancelQuickConnect() }
    }

    // ------------------------------------------------------------- server --

    private var serverStep: some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 0) {
            Text("Connect to Jellyfin")
                .font(KFont.headlineLarge)
                .foregroundStyle(c.ink)
                .padding(.top, 24)
            Text("Type your server's address, the one you open in a browser. A port or a path is fine: jellyfin.example.com, 192.168.1.20:8096, https://example.com/jellyfin.")
                .font(KFont.bodyMedium)
                .foregroundStyle(c.ink2)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            field("Server address", text: $address, icon: "server.rack", field: .address, keyboard: .URL, secure: false)
                .padding(.top, 24)
                .submitLabel(.go)
                .onSubmit(connect)
            errorView
            WideGlassButton(title: busy ? "Connecting…" : "Connect", icon: "arrow.right", prominent: true, enabled: !busy && !address.trimmingCharacters(in: .whitespaces).isEmpty, action: connect)
                .padding(.top, 20)
            Button {
                address = "https://demo.jellyfin.org/stable"
                username = "demo"
                connect()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("No server yet? Try Jellyfin's demo")
                }
                .font(KFont.labelLarge)
                .foregroundStyle(c.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 10)
        }
        .onAppear { if prefillUrl.isEmpty { focus = .address } }
    }

    private func connect() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        focus = nil
        Task {
            defer { busy = false }
            do {
                let auth = AppGraph.shared.auth
                let (url, info) = try await JellyfinClient.probe(text, info: auth.info)
                let client = auth.anonymousClient(url)
                let publicUsers = (try? await client.publicUsers()) ?? []
                let quick = await client.quickConnectEnabled()
                serverURL = url
                system = info
                users = publicUsers
                quickConnectAvailable = quick
                withAnimation(theme.ease) { step = .user }
                if username.isEmpty { focus = .username } else if publicUsers.isEmpty { focus = .password }
                #if DEBUG
                ScreenshotDriver.noteServerShown()
                #endif
            } catch {
                self.error = JellyfinError.from(error).localizedDescription
            }
        }
    }

    // --------------------------------------------------------------- user --

    private var userStep: some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 0) {
            Eyebrow(system?.version.map { "Jellyfin \($0)" } ?? "Jellyfin")
                .padding(.top, 24)
            Text(system?.serverName ?? serverURL?.host ?? "Your server")
                .font(KFont.headlineLarge)
                .foregroundStyle(c.ink)
                .lineLimit(2)
                .padding(.top, 4)
            Text(serverURL?.absoluteString ?? "")
                .font(KFont.bodySmall)
                .foregroundStyle(c.ink3)
                .lineLimit(1)
                .padding(.top, 2)

            if let quickConnect {
                quickConnectView(quickConnect)
            } else {
                if !users.isEmpty {
                    Text("Who's watching?")
                        .font(KFont.titleMedium)
                        .foregroundStyle(c.ink)
                        .padding(.top, 26)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(users) { user in userButton(user) }
                        }
                        .padding(.vertical, 6)
                    }
                    .padding(.top, 8)
                }
                field("Username", text: $username, icon: "person", field: .username, keyboard: .default, secure: false)
                    .padding(.top, 20)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                field("Password", text: $password, icon: "lock", field: .password, keyboard: .default, secure: true)
                    .padding(.top, 12)
                    .submitLabel(.go)
                    .onSubmit(signIn)
                errorView
                WideGlassButton(title: busy ? "Signing in…" : "Sign In", icon: "arrow.right", prominent: true, enabled: !busy && !username.isEmpty, action: signIn)
                    .padding(.top, 20)
                if quickConnectAvailable {
                    WideGlassButton(title: "Use Quick Connect", icon: "qrcode", prominent: false, enabled: !busy, action: startQuickConnect)
                        .padding(.top, 12)
                    Text("Approve a code on a device that's already signed in, without typing your password here.")
                        .font(KFont.bodySmall)
                        .foregroundStyle(c.ink3)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func userButton(_ user: UserDto) -> some View {
        let chosen = user.name == username
        let client = serverURL.map { AppGraph.shared.auth.anonymousClient($0) }
        return Button {
            username = user.name
            password = ""
            if user.hasPassword == false {
                signIn()
            } else {
                focus = .password
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(theme.colors.accentSoft)
                    Text(Format.initials(user.name))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.colors.accent)
                    if let url = client?.userImageURL(user) {
                        RemoteImage(url: url, pixelSize: 200).clipShape(Circle())
                    }
                }
                .frame(width: 72, height: 72)
                .overlay(Circle().strokeBorder(chosen ? theme.colors.accent : theme.colors.edge, lineWidth: chosen ? 3 : 1))
                Text(user.name)
                    .font(KFont.labelMedium)
                    .foregroundStyle(theme.colors.ink)
                    .lineLimit(1)
            }
            .frame(width: 84)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func signIn() {
        guard let serverURL, !username.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let client = AppGraph.shared.auth.anonymousClient(serverURL)
                let result = try await client.authenticate(username: username, password: password)
                finish(result)
            } catch {
                self.error = JellyfinError.from(error).localizedDescription
            }
        }
    }

    private func finish(_ result: AuthenticationResult) {
        guard let serverURL else { return }
        AppGraph.shared.auth.signedIn(result, server: serverURL, system: system)
        Haptics.success()
        onDone()
    }

    // ------------------------------------------------------- quick connect --

    private func quickConnectView(_ result: QuickConnectResult) -> some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 0) {
            Text("Quick Connect")
                .font(KFont.titleMedium)
                .foregroundStyle(c.ink)
                .padding(.top, 26)
            Text("On a device that's signed in, open Jellyfin's settings, choose Quick Connect and enter this code.")
                .font(KFont.bodyMedium)
                .foregroundStyle(c.ink2)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            Text(result.code)
                .font(.system(size: 46, weight: .bold, design: .monospaced))
                .tracking(8)
                .foregroundStyle(c.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(RoundedRectangle(cornerRadius: theme.radii.lg, style: .continuous).fill(c.glass))
                .overlay(RoundedRectangle(cornerRadius: theme.radii.lg, style: .continuous).strokeBorder(c.edge, lineWidth: 1))
                .padding(.top, 18)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                ProgressView().tint(c.accent)
                Text("Waiting for approval…").font(KFont.bodyMedium).foregroundStyle(c.ink2)
            }
            .padding(.top, 16)
            errorView
            WideGlassButton(title: "Use a password instead", icon: "key", prominent: false) {
                cancelQuickConnect()
                withAnimation(theme.ease) { quickConnect = nil }
            }
            .padding(.top, 20)
        }
    }

    private func startQuickConnect() {
        guard let serverURL else { return }
        error = nil
        cancelQuickConnect()
        quickConnectTask = Task {
            let client = AppGraph.shared.auth.anonymousClient(serverURL)
            do {
                let started = try await client.quickConnectInitiate()
                withAnimation(theme.ease) { quickConnect = started }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let state = try await client.quickConnectState(secret: started.secret)
                    if state.authenticated {
                        let result = try await client.authenticate(quickConnectSecret: started.secret)
                        finish(result)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = JellyfinError.from(error).localizedDescription }
            }
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
    }

    // ------------------------------------------------------------ helpers --

    @ViewBuilder
    private var errorView: some View {
        if let error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            .font(KFont.bodyMedium)
            .foregroundStyle(theme.colors.danger)
            .padding(.top, 14)
            .transition(.opacity)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String, field: Field, keyboard: UIKeyboardType, secure: Bool) -> some View {
        let c = theme.colors
        let shape = RoundedRectangle(cornerRadius: theme.radii.md, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(c.ink3)
                .frame(width: 20)
            Group {
                if secure {
                    SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(c.ink3))
                } else {
                    TextField("", text: text, prompt: Text(placeholder).foregroundStyle(c.ink3))
                        .keyboardType(keyboard)
                }
            }
            .focused($focus, equals: field)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(secure ? .password : (field == .username ? .username : .URL))
            .foregroundStyle(c.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(shape.fill(c.glass))
        .overlay(shape.strokeBorder(focus == field ? c.accent.opacity(0.8) : c.edge, lineWidth: focus == field ? 1.5 : 1))
    }
}

/** The account's token stopped working (revoked on the server): sign in again, or use another account. */
struct SignInAgainScreen: View {
    @Environment(\.kinema) private var theme
    let profile: ServerProfile

    var body: some View {
        let auth = AppGraph.shared.auth
        ZStack {
            PlainBackdrop()
            AddServerFlow(
                prefillUrl: profile.serverUrl,
                prefillUser: profile.username,
                onCancel: auth.profiles.count > 1 ? {
                    if let other = auth.profiles.first(where: { $0.id != profile.id }) { auth.switchTo(other.id) }
                } : nil,
                onDone: {}
            )
        }
    }
}
