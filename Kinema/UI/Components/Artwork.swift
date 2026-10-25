import SwiftUI
import UIKit

/**
 * An image from the server: its BlurHash first (or a gradient in the accent
 * with the title's initials when there is none), then the picture itself.
 * Fills whatever frame it is given.
 */
struct ArtworkImage: View {
    @Environment(\.kinema) private var theme
    let image: ImageRef?
    /** Pixels wide to ask the server for. */
    var width: Int = 360
    var label: String?
    var icon = "film"
    /** A file on the phone to show instead (a download's poster). */
    var localURL: URL?

    var body: some View {
        let url = localURL ?? image.flatMap { AppGraph.shared.imageURL($0, width: width) }
        ZStack {
            placeholder
            if let url {
                RemoteImage(url: url, pixelSize: width * 2)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let hash = image?.blurHash, let blur = ImageLoader.blurHashImage(hash) {
            Image(uiImage: blur)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [theme.colors.accent.opacity(0.45), theme.colors.accent.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(theme.colors.elevated)
                if let label, !label.isEmpty {
                    Text(Format.initials(label))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

/** A title logo from the server, shown at its own proportions; nothing until it has loaded. */
struct LogoImage: View {
    let image: ImageRef
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 110
    @State private var loaded: UIImage?

    var body: some View {
        let url = AppGraph.shared.imageURL(image, width: 800)
        Group {
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .transition(.opacity)
            } else {
                Color.clear.frame(width: 1, height: maxHeight * 0.6)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let image = await ImageLoader.shared.image(url, pixelSize: 1000)
            withAnimation(.easeOut(duration: 0.25)) { loaded = image }
        }
    }
}

/** A thin bar showing how far through something is. */
struct WatchProgress: View {
    @Environment(\.kinema) private var theme
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.45))
                Capsule().fill(theme.colors.accent).frame(width: max(height, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

/** The tick in the corner of a watched poster, or how many episodes are left. */
struct WatchedBadge: View {
    @Environment(\.kinema) private var theme
    let played: Bool
    var unplayed: Int?

    var body: some View {
        if played {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(theme.colors.onAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.colors.accent))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .accessibilityLabel("Watched")
        } else if let unplayed, unplayed > 0 {
            Text(unplayed > 99 ? "99+" : String(unplayed))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(theme.colors.onAccent)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 22)
                .background(Capsule().fill(theme.colors.accent))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .accessibilityLabel("\(unplayed) unwatched")
        }
    }
}
