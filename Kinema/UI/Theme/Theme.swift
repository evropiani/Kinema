import SwiftUI
import UIKit

extension Color {
    /** An opaque colour from packed 0xRRGGBB (or 0xAARRGGBB, alpha ignored). */
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xff) / 255,
            green: Double((argb >> 8) & 0xff) / 255,
            blue: Double(argb & 0xff) / 255,
            opacity: 1
        )
    }

    /** "#RRGGBB", or nil. */
    init?(hex: String) {
        guard let argb = ArtworkColor.parseHex(hex) else { return nil }
        self.init(argb: argb)
    }
}

/**
 * Kinema's palette is, like Kultr's, almost colourless. Colour arrives at
 * runtime: a title's page takes its accent from the title's own artwork, and
 * every glass surface and button on it picks that up, so each film's page
 * has the mood of the film.
 */
struct KinemaColors: Equatable {
    var dark: Bool
    /** Night mode: dark, on pure black, with less light behind the content. */
    var night = false
    var accent: Color
    var accentArgb: UInt32
    var onAccent: Color
    var background: Color
    var elevated: Color
    var ink: Color
    var ink2: Color
    var ink3: Color
    var ink4: Color
    var glass: Color
    var glassStrong: Color
    var edge: Color
    var line: Color
    var danger = Color(argb: 0xFF5F57)
    var warning = Color(argb: 0xFFBD2E)
    var success = Color(argb: 0x45D67A)

    var accentSoft: Color { accent.opacity(0.18) }
    var accentGlow: Color { accent.opacity(0.35) }

    static func make(dark: Bool, accent picked: UInt32, night: Bool) -> KinemaColors {
        // A pale colour from the artwork washes out on the light background, so
        // in light mode it is darkened just enough to stay readable.
        let argb = dark ? picked : readableOnLight(picked)
        let accent = Color(argb: argb)
        let onAccent: Color = ArtworkColor.luminance(argb) > 0.45 ? Color(argb: 0x0A0A10) : .white
        let inkBase = Color(argb: 0x0A0A10)
        if dark {
            return KinemaColors(
                dark: true,
                night: night,
                accent: accent,
                accentArgb: argb,
                onAccent: onAccent,
                background: Color(argb: night ? 0x000000 : 0x08080C),
                elevated: Color(argb: night ? 0x0C0C10 : 0x121219),
                ink: .white.opacity(0.96),
                ink2: .white.opacity(0.66),
                ink3: .white.opacity(0.42),
                ink4: .white.opacity(0.22),
                glass: .white.opacity(0.07),
                glassStrong: .white.opacity(0.12),
                edge: .white.opacity(0.14),
                line: .white.opacity(0.09)
            )
        }
        return KinemaColors(
            dark: false,
            accent: accent,
            accentArgb: argb,
            onAccent: onAccent,
            background: Color(argb: 0xECEEF4),
            elevated: Color(argb: 0xF7F8FC),
            ink: inkBase.opacity(0.94),
            ink2: inkBase.opacity(0.62),
            ink3: inkBase.opacity(0.42),
            ink4: inkBase.opacity(0.2),
            glass: .white.opacity(0.55),
            glassStrong: .white.opacity(0.72),
            edge: inkBase.opacity(0.1),
            line: inkBase.opacity(0.08)
        )
    }

    /**
     * The colour darkened until its luminance is at most 0.22, so it reads as
     * text on the light background. Hue stays, and pale colours gain a little
     * saturation so they turn deeper rather than grey.
     */
    static func readableOnLight(_ argb: UInt32) -> UInt32 {
        let target = 0.22
        guard ArtworkColor.luminance(argb) > target else { return argb }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(
            red: CGFloat((argb >> 16) & 0xff) / 255,
            green: CGFloat((argb >> 8) & 0xff) / 255,
            blue: CGFloat(argb & 0xff) / 255,
            alpha: 1
        ).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s > 0.05 { s = min(1, max(s, 0.45) * 1.1) }
        var color = argb
        while v > 0.3 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            UIColor(hue: h, saturation: s, brightness: v, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
            color = (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
            if ArtworkColor.luminance(color) <= target { break }
            v -= 0.02
        }
        return color
    }
}

struct KinemaRadii: Equatable {
    var xs: CGFloat
    var sm: CGFloat
    var md: CGFloat
    var lg: CGFloat
    var xl: CGFloat

    static func of(_ style: CornerStyle) -> KinemaRadii {
        switch style {
        case .sharp: return KinemaRadii(xs: 3, sm: 4, md: 6, lg: 8, xl: 10)
        case .soft: return KinemaRadii(xs: 8, sm: 12, md: 16, lg: 24, xl: 32)
        case .round: return KinemaRadii(xs: 12, sm: 18, md: 24, lg: 32, xl: 42)
        }
    }
}

struct KinemaTheme: Equatable {
    var colors: KinemaColors
    var radii: KinemaRadii
    var settings: Settings

    static let fallback = KinemaTheme(
        colors: .make(dark: true, accent: 0x6F8FEF, night: false),
        radii: .of(.soft),
        settings: Settings()
    )

    /** The same theme with another accent, for a page tinted by its artwork. */
    func tinted(_ argb: UInt32) -> KinemaTheme {
        var copy = self
        copy.colors = .make(dark: colors.dark, accent: argb, night: colors.night)
        return copy
    }
}

private struct KinemaThemeKey: EnvironmentKey {
    static let defaultValue = KinemaTheme.fallback
}

extension EnvironmentValues {
    var kinema: KinemaTheme {
        get { self[KinemaThemeKey.self] }
        set { self[KinemaThemeKey.self] = newValue }
    }
}

/** The type scale, in SF Pro. */
enum KFont {
    static let display = Font.system(size: 34, weight: .bold)
    static let headlineLarge = Font.system(size: 32, weight: .bold)
    static let headlineMedium = Font.system(size: 28, weight: .bold)
    static let headlineSmall = Font.system(size: 24, weight: .bold)
    static let titleLarge = Font.system(size: 22, weight: .bold)
    static let titleMedium = Font.system(size: 17, weight: .semibold)
    static let titleSmall = Font.system(size: 15, weight: .semibold)
    static let bodyLarge = Font.system(size: 16)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.system(size: 12)
    static let labelLarge = Font.system(size: 14, weight: .semibold)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
    /** Small caps-ish label used above headings ("MOVIE", "SERIES"). */
    static let eyebrow = Font.system(size: 11, weight: .bold)
}

extension KinemaTheme {
    /** Reduce motion, from Kinema's setting or the system's. */
    var reduceMotion: Bool { settings.reduceMotion || UIAccessibility.isReduceMotionEnabled }

    /** The spring used for moving highlights and rows, or none with Reduce motion. */
    var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82) }

    /** A quick ease for things appearing and going. */
    var ease: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }
}

/**
 * Tints a page with the dominant colour of an image (a poster or backdrop),
 * when the accent follows the artwork.
 */
private struct ArtworkTint: ViewModifier {
    @Environment(\.kinema) private var theme
    let image: ImageRef?
    @State private var sampled: UInt32?

    func body(content: Content) -> some View {
        let follow = theme.settings.accentMode == .artwork
        content
            .environment(\.kinema, follow && sampled != nil ? theme.tinted(sampled!) : theme)
            .tint(follow && sampled != nil ? Color(argb: sampled!) : theme.colors.accent)
            .task(id: image) {
                guard follow, let image else { return }
                if let hash = image.blurHash, sampled == nil, let quick = BlurHash.averageColor(hash) {
                    sampled = ArtworkColor.lift(Int((quick >> 16) & 0xff), Int((quick >> 8) & 0xff), Int(quick & 0xff))
                }
                guard let url = AppGraph.shared.imageURL(image, width: 160) else { return }
                if let color = await ImageLoader.shared.dominantColor(url) {
                    withAnimation(theme.reduceMotion ? nil : .easeInOut(duration: 0.6)) { sampled = color }
                }
            }
    }
}

extension View {
    /** Take the accent from [image] for everything inside. */
    func artworkTint(_ image: ImageRef?) -> some View {
        modifier(ArtworkTint(image: image))
    }
}
