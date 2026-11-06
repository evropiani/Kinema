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
 * Kinema's palette is Kultr's: cream pages and warm black text in light
 * mode, warm charcoal in dark (pure black with Night mode), and one orange
 * for whatever you can tap. Colour is flat everywhere; the posters and
 * backdrops are the only colourful things on screen.
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

    /** Kultr's orange. */
    static let orange: UInt32 = 0xFF7A3D

    var accentSoft: Color { accent.opacity(0.18) }
    /** The fill of a tinted button, like Apple Music's Play and Shuffle. */
    var sand: Color { dark ? ink.opacity(0.1) : Color(argb: 0xEADFCC) }

    static func make(dark: Bool, accent picked: UInt32 = orange, night: Bool) -> KinemaColors {
        // The orange is darkened in light mode until it reads as text on cream.
        let argb = dark ? picked : readableOnLight(picked)
        let accent = Color(argb: argb)
        let inkBase = Color(argb: dark ? 0xF3EDE2 : 0x1F1A14)
        // Whichever of white and ink reads better on the accent.
        let onAccent: Color = ArtworkColor.luminance(argb) > 0.2 ? Color(argb: 0x1F1A14) : .white
        if dark {
            // Night mode is for OLED screens: black pixels are switched off, so
            // the background is true black and raised surfaces only just lift.
            return KinemaColors(
                dark: true,
                night: night,
                accent: accent,
                accentArgb: argb,
                onAccent: onAccent,
                background: Color(argb: night ? 0x000000 : 0x1C1A17),
                elevated: Color(argb: night ? 0x0E0D0B : 0x26231F),
                ink: inkBase,
                ink2: inkBase.opacity(0.7),
                ink3: inkBase.opacity(0.5),
                ink4: inkBase.opacity(0.26),
                glass: inkBase.opacity(0.07),
                glassStrong: inkBase.opacity(0.12),
                edge: inkBase.opacity(0.22),
                line: inkBase.opacity(0.1)
            )
        }
        let paper = Color(argb: 0xFFFCF6)
        return KinemaColors(
            dark: false,
            accent: accent,
            accentArgb: argb,
            onAccent: onAccent,
            background: Color(argb: 0xF6F0E5),
            elevated: paper,
            ink: inkBase,
            ink2: Color(argb: 0x5A5046),
            ink3: Color(argb: 0x6E6255),
            ink4: Color(argb: 0xA89C8D),
            glass: paper.opacity(0.8),
            glassStrong: paper,
            edge: inkBase.opacity(0.16),
            line: inkBase.opacity(0.12)
        )
    }

    /**
     * The colour darkened until its luminance is at most 0.15, so it reads as
     * text on cream (4.5:1). Hue stays, and pale colours gain a little
     * saturation so they turn deeper rather than grey.
     */
    static func readableOnLight(_ argb: UInt32) -> UInt32 {
        let target = 0.15
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
        colors: .make(dark: true, night: false),
        radii: .of(.soft),
        settings: Settings()
    )
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

/**
 * The type scale, as in Kultr: on iOS's own text styles, so every size
 * follows Larger Text in the iPhone's settings.
 */
enum KFont {
    static let display = Font.largeTitle.bold()
    static let headlineLarge = Font.largeTitle.bold()
    static let headlineMedium = Font.title.bold()
    static let headlineSmall = Font.title2.bold()
    static let titleLarge = Font.title2.bold()
    static let titleMedium = Font.headline
    static let titleSmall = Font.subheadline.weight(.semibold)
    static let bodyLarge = Font.body
    static let bodyMedium = Font.subheadline
    static let bodySmall = Font.footnote
    static let labelLarge = Font.subheadline.weight(.semibold)
    static let labelMedium = Font.footnote.weight(.medium)
    static let labelSmall = Font.caption.weight(.medium)
    /** A small label above a heading ("MOVIE", "SERIES"). */
    static let eyebrow = Font.caption.weight(.semibold)
}

extension KinemaTheme {
    /** A poster's width in a row, from Settings → Appearance → Poster size. */
    var posterWidth: CGFloat {
        switch settings.posterSize {
        case .small: return 100
        case .medium: return 124
        case .large: return 164
        }
    }

    /** The narrowest a poster gets in a grid (they grow to fill the row). */
    var posterGridMinimum: CGFloat {
        switch settings.posterSize {
        case .small: return 78
        case .medium: return 104
        case .large: return 150
        }
    }

    /** Reduce motion, from Kinema's setting or the system's. */
    var reduceMotion: Bool { settings.reduceMotion || UIAccessibility.isReduceMotionEnabled }

    /** The spring used for moving highlights and rows, or none with Reduce motion. */
    var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82) }

    /** A quick ease for things appearing and going. */
    var ease: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }
}
