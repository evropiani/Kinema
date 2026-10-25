import SwiftUI

/**
 * Subtitles, drawn by Kinema in the style chosen in Settings: size, colour,
 * outline, background, position and brightness. The second track sits at
 * the top of the picture or above the first.
 */
struct SubtitleOverlay: View {
    /** Points to lift the bottom subtitles by while the controls are showing. */
    var lift: CGFloat = 0

    var body: some View {
        let state = AppGraph.shared.player.subtitles
        let settings = AppGraph.shared.settings.settings
        GeometryReader { proxy in
            let height = proxy.size.height
            let bottom = height * CGFloat(settings.subtitleMargin / 100) + lift
            let primaryTop = state.primary.filter(\.top)
            let primaryBottom = state.primary.filter { !$0.top }
            let secondaryAtTop = settings.secondaryPosition == .top
            ZStack {
                VStack(spacing: 6) {
                    if !secondaryAtTop {
                        cues(state.secondary, height: height, scale: settings.secondaryScale, settings: settings, secondary: true)
                    }
                    cues(primaryBottom, height: height, scale: 1, settings: settings, secondary: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, bottom)
                .animation(.easeOut(duration: 0.2), value: lift)

                VStack(spacing: 6) {
                    cues(primaryTop, height: height, scale: 1, settings: settings, secondary: false)
                    if secondaryAtTop {
                        cues(state.secondary, height: height, scale: settings.secondaryScale, settings: settings, secondary: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, max(24, height * 0.05))
            }
            .padding(.horizontal, proxy.size.width * 0.08)
        }
    }

    @ViewBuilder
    private func cues(_ list: [SubtitleCue], height: CGFloat, scale: Double, settings: Settings, secondary: Bool) -> some View {
        if !list.isEmpty {
            let size = max(12, height * 0.052 * CGFloat(settings.subtitleSize / 100) * CGFloat(scale))
            VStack(spacing: 2) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, cue in
                    SubtitleText(runs: cue.runs, size: size, settings: settings, dimmed: secondary)
                }
            }
        }
    }
}

/** One cue's text with Kinema's outline and background. */
struct SubtitleText: View {
    let runs: [SubtitleRun]
    let size: CGFloat
    let settings: Settings
    var dimmed = false

    var body: some View {
        let outline = CGFloat(settings.subtitleOutline) * size / 28
        let text = styled(color: color)
        ZStack {
            if outline > 0.2 {
                // An outline from eight offset copies, which reads on any picture.
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) * .pi / 4
                    styled(color: .black)
                        .offset(x: cos(angle) * outline, y: sin(angle) * outline)
                }
            }
            text
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.5), radius: max(1, outline), y: 1)
        .padding(.horizontal, settings.subtitleBackground > 0 ? size * 0.35 : 0)
        .padding(.vertical, settings.subtitleBackground > 0 ? size * 0.1 : 0)
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(.black.opacity(settings.subtitleBackground))
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        let base = ArtworkColor.parseHex(settings.subtitleColor) ?? 0xFFFF_FFFF
        let brightness = min(1, max(0.2, settings.subtitleBrightness)) * (dimmed ? 0.88 : 1)
        let r = Double((base >> 16) & 0xff) / 255 * brightness
        let g = Double((base >> 8) & 0xff) / 255 * brightness
        let b = Double(base & 0xff) / 255 * brightness
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private var font: Font {
        let weight: Font.Weight = settings.subtitleBold ? .bold : .semibold
        switch settings.subtitleFont {
        case .system: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    private func styled(color: Color) -> Text {
        var result = Text("")
        for run in runs {
            result = result + Text(run.text).italic(run.italic).bold(run.bold || settings.subtitleBold)
        }
        return result.font(font).foregroundColor(color)
    }
}
