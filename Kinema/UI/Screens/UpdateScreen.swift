import SwiftUI

/**
 * A new version: what is in it (the release notes, without their Install
 * section) and how to get it. Kinema cannot replace itself, so Update hands
 * the new IPA to SideStore or AltStore when one is on the phone, or opens
 * the release page to download it.
 */
struct UpdateScreen: View {
    @Environment(\.kinema) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let release: AppRelease

    var body: some View {
        let c = theme.colors
        let installers = UpdateChecker.Installer.allCases.filter { $0.installed }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image("KinemaLogo")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Kinema \(release.version)").font(.system(size: 24, weight: .bold)).foregroundStyle(c.ink)
                            Text("You have \(appVersion)\(published.map { " · released \($0)" } ?? "")")
                                .font(.system(size: 14))
                                .foregroundStyle(c.ink2)
                        }
                    }
                    .padding(.bottom, 6)
                    ReleaseNotesView(markdown: release.notes)
                    VStack(spacing: 10) {
                        if let ipa = release.ipaUrl {
                            ForEach(installers, id: \.name) { installer in
                                WideGlassButton(title: "Update with \(installer.name)", icon: "arrow.down.app.fill", prominent: true) {
                                    if let link = installer.link(for: ipa) { openURL(link) }
                                }
                            }
                        }
                        WideGlassButton(title: "Open the release page", icon: "safari", prominent: installers.isEmpty || release.ipaUrl == nil) {
                            if let url = URL(string: release.pageUrl) { openURL(url) }
                        }
                    }
                    .padding(.top, 10)
                    Text(installers.isEmpty
                        ? "Download Kinema.ipa there and install it the way you installed Kinema, with the same Apple ID. Your servers, downloads and settings stay."
                        : "Installed Kinema with Sideloadly, AltServer or Impactor rather than \(installers.map(\.name).joined(separator: " or "))? Install the new version the same way, with the same Apple ID. Your servers, downloads and settings stay.")
                        .font(.system(size: 13))
                        .foregroundStyle(c.ink3)
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background { PlainBackdrop() }
            .navigationTitle("Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var published: String? {
        guard let date = release.publishedAt.flatMap(JellyfinDate.parse) else { return nil }
        return Format.relative(date)
    }
}

/** Release notes as headings, points and paragraphs, with bold, code and links. */
struct ReleaseNotesView: View {
    @Environment(\.kinema) private var theme
    let markdown: String

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ReleaseNotes.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(attributed(text))
                        .font(.system(size: level <= 2 ? 19 : 16, weight: .bold))
                        .foregroundStyle(c.ink)
                        .padding(.top, 6)
                case .bullet(let level, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(level == 0 ? "•" : "◦").foregroundStyle(c.accent)
                        Text(attributed(text)).foregroundStyle(c.ink2)
                    }
                    .font(.system(size: 15))
                    .padding(.leading, CGFloat(level) * 18)
                case .paragraph(let text):
                    Text(attributed(text))
                        .font(.system(size: 15))
                        .foregroundStyle(c.ink2)
                }
            }
        }
        .tint(c.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(_ spans: [ReleaseNotes.Span]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if span.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            if span.code { piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.code) }
            if let link = span.link, let url = URL(string: link) { piece.link = url }
            result += piece
        }
        return result
    }
}

/** A new version, as a strip of glass at the top until it is opened or dismissed. */
struct UpdateBanner: View {
    @Environment(\.kinema) private var theme
    let release: AppRelease
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let c = theme.colors
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(c.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kinema \(release.version) is out").font(.system(size: 15, weight: .semibold)).foregroundStyle(c.ink)
                Text("See what's new").font(.system(size: 13)).foregroundStyle(c.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(c.ink2)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture(perform: onOpen)
        .kinemaGlass(Capsule(), interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}
