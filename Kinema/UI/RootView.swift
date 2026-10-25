import SwiftUI
import UIKit

/**
 * The root of the interface: the theme, then the welcome without an
 * account, or the tabs (with the player over them).
 */
struct RootView: View {
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let settings = AppGraph.shared.settings.settings
        let dark: Bool = {
            switch settings.theme {
            case .dark: return true
            case .light: return false
            case .system: return systemScheme == .dark
            }
        }()
        let accent = ArtworkColor.parseHex(settings.accent) ?? 0xFF6F_8FEF
        let theme = KinemaTheme(
            colors: .make(dark: dark, accent: accent, night: settings.nightMode),
            radii: .of(settings.corners),
            settings: settings
        )
        AppContent()
            .environment(\.kinema, theme)
            .preferredColorScheme(settings.theme == .system ? nil : (dark ? .dark : .light))
            .tint(theme.colors.accent)
    }
}

private struct AppContent: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let auth = graph.auth
        let ui = graph.ui
        Group {
            if !ui.welcomed || auth.profiles.isEmpty {
                WelcomeFlow { ui.finishWelcome() }
            } else if auth.client == nil, let profile = auth.active {
                // The token stopped working: sign in to the same server again.
                SignInAgainScreen(profile: profile)
            } else {
                ZStack {
                    MainUI()
                    if let request = ui.login {
                        AddServerFlow(prefillUrl: request.url, prefillUser: request.user) { ui.login = nil }
                            .background { PlainBackdrop() }
                            .transition(.move(edge: .bottom))
                            .zIndex(10)
                    }
                }
                .animation(theme.ease, value: ui.login != nil)
            }
        }
    }
}
