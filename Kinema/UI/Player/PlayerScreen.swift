import AVKit
import SwiftUI

/**
 * The player's screen: the picture, Kinema's own subtitles, the gestures
 * (tap, double-tap to skip, hold for speed, swipes for brightness, volume
 * and seeking, pinch to fill) and the controls on top.
 */
struct PlayerScreen: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(surface: player.surface, gravity: player.gravity)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.25), value: player.aspect)
                SubtitleOverlay(lift: player.controlsVisible && !player.locked ? 92 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                PlayerGestureLayer(size: proxy.size)
                    .ignoresSafeArea()
                PlayerHUD()
                    .allowsHitTesting(false)
                if player.statsVisible {
                    StatsPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 70)
                        .padding(.leading, 24)
                        .allowsHitTesting(false)
                }
                if player.locked {
                    LockedOverlay()
                } else {
                    PlayerControls()
                        .opacity(player.controlsVisible ? 1 : 0)
                        .allowsHitTesting(player.controlsVisible)
                        .animation(.easeInOut(duration: 0.22), value: player.controlsVisible)
                }
                PlayerCorner()
                if case .failed(let message) = player.phase {
                    PlayerError(message: message)
                }
                if let panel = player.panel {
                    PanelHost(panel: panel)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(10)
                }
                SystemVolumeHost().frame(width: 1, height: 1).opacity(0.01)
            }
            .animation(theme.ease, value: player.panel)
            .onAppear { player.portraitLayout = proxy.size.height > proxy.size.width }
            .onChange(of: proxy.size) { _, size in player.portraitLayout = size.height > size.width }
        }
        .preferredColorScheme(.dark)
        .environment(\.kinema, playerTheme)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .artworkTint(player.item?.backdropImage ?? player.item?.posterImage)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            AppGraph.shared.player.dismissedByUser()
        }
    }

    /** The player is always dark, whatever the rest of the app is. */
    private var playerTheme: KinemaTheme {
        var copy = theme
        copy.colors = .make(dark: true, accent: theme.colors.accentArgb, night: true)
        return copy
    }
}

// ---------------------------------------------------------------- gestures --

/**
 * Every touch on the picture, read by one gesture so they never fight:
 * a tap shows or hides the controls, a double tap on either side skips (and
 * each tap after it skips again), holding plays faster (swipe up to keep
 * it), a vertical swipe on the left changes brightness and on the right
 * volume, a horizontal swipe seeks, and a pinch fills the screen.
 */
private struct PlayerGestureLayer: View {
    let size: CGSize

    private enum Mode {
        case undecided, hold, brightness, volume, seek
    }

    @State private var mode: Mode = .undecided
    @State private var holdTask: Task<Void, Never>?
    @State private var tapTask: Task<Void, Never>?
    @State private var lastTap: Date?
    @State private var lastTapSide = 0
    @State private var streakUntil: Date?
    @State private var startValue: Double = 0
    @State private var startPosition: Double = 0

    var body: some View {
        let player = AppGraph.shared.player
        let settings = AppGraph.shared.settings.settings
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in changed(value, player, settings) }
                    .onEnded { value in ended(value, player, settings) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        guard settings.pinchToZoom, !player.locked else { return }
                        if value.magnification > 1.12, player.aspect == .fit {
                            player.aspect = .fill
                            Haptics.select()
                        } else if value.magnification < 0.9, player.aspect != .fit {
                            player.aspect = .fit
                            Haptics.select()
                        }
                    }
            )
    }

    private func changed(_ value: DragGesture.Value, _ player: PlayerModel, _ settings: Settings) {
        let dx = value.translation.width
        let dy = value.translation.height
        if mode == .undecided && holdTask == nil && hypot(dx, dy) < 1 {
            // Touch down: holding still for a moment means "faster".
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, mode == .undecided, !player.locked, player.isPlaying else { return }
                mode = .hold
                player.beginHold()
            }
            return
        }
        if player.locked { return }
        switch mode {
        case .undecided:
            guard hypot(dx, dy) > 14 else { return }
            holdTask?.cancel()
            if abs(dx) > abs(dy) {
                guard settings.seekGesture, player.clock.duration > 0 else { mode = .undecided; return }
                mode = .seek
                startPosition = player.clock.position
                player.showControls()
            } else if value.startLocation.x < size.width / 2 {
                guard settings.brightnessGesture else { return }
                mode = .brightness
                startValue = Double(ScreenBrightness.value)
            } else {
                guard settings.volumeGesture else { return }
                mode = .volume
                startValue = Double(SystemVolume.value)
            }
            HUDState.shared.kind = hudKind
        case .hold:
            if dy < -60 { player.lockHold() }
        case .brightness:
            let next = startValue - Double(dy) / Double(max(200, size.height * 0.7))
            ScreenBrightness.value = CGFloat(next)
            HUDState.shared.level = min(1, max(0, next))
        case .volume:
            let next = startValue - Double(dy) / Double(max(200, size.height * 0.7))
            SystemVolume.value = Float(next)
            HUDState.shared.level = min(1, max(0, next))
        case .seek:
            // A full swipe across covers up to three minutes (less for short
            // videos), scaled by Settings → Player → Swipe-to-seek sensitivity.
            let span = min(180, max(30, player.clock.duration / 3)) * settings.seekSensitivity.factor
            let target = min(player.clock.duration, max(0, startPosition + Double(dx / max(1, size.width)) * span))
            player.clock.scrubbing = target
        }
    }

    private var hudKind: HUDState.Kind {
        switch mode {
        case .brightness: return .brightness
        case .volume: return .volume
        default: return .none
        }
    }

    private func ended(_ value: DragGesture.Value, _ player: PlayerModel, _ settings: Settings) {
        holdTask?.cancel()
        holdTask = nil
        defer { mode = .undecided }
        switch mode {
        case .hold:
            player.endHold()
            return
        case .seek:
            if let target = player.clock.scrubbing {
                player.clock.scrubbing = nil
                player.seek(to: target, precise: true)
            }
            return
        case .brightness, .volume:
            HUDState.shared.hideSoon()
            return
        case .undecided:
            break
        }
        guard hypot(value.translation.width, value.translation.height) < 14 else { return }
        tap(at: value.location, player, settings)
    }

    /** One tap, or part of a double tap. */
    private func tap(at point: CGPoint, _ player: PlayerModel, _ settings: Settings) {
        let now = Date()
        let side = point.x < size.width * 0.38 ? -1 : point.x > size.width * 0.62 ? 1 : 0
        if player.locked {
            player.showControls()
            return
        }
        // Already skipping: every tap on the same side skips again, at once.
        if let streak = streakUntil, now < streak, side != 0, side == lastTapSide, settings.doubleTapSeek {
            skip(side, player, settings)
            streakUntil = now.addingTimeInterval(0.8)
            return
        }
        if let last = lastTap, now.timeIntervalSince(last) < 0.3, side == lastTapSide {
            tapTask?.cancel()
            lastTap = nil
            if side == 0 || !settings.doubleTapSeek {
                player.togglePlay()
            } else {
                skip(side, player, settings)
                streakUntil = now.addingTimeInterval(0.8)
            }
            return
        }
        lastTap = now
        lastTapSide = side
        tapTask?.cancel()
        tapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { player.toggleControls() }
        }
    }

    private func skip(_ side: Int, _ player: PlayerModel, _ settings: Settings) {
        let seconds = Double(side < 0 ? -settings.skipBack : settings.skipForward)
        player.skip(seconds)
        HUDState.shared.ripple(side: side, seconds: Int(seconds))
        Haptics.tap()
    }
}

/** What the gesture HUD shows: the brightness or volume level, and the double-tap skips. */
@MainActor
@Observable
final class HUDState {
    static let shared = HUDState()

    enum Kind {
        case none, brightness, volume
    }

    var kind: Kind = .none
    var level: Double = 0
    var rippleSide = 0
    var rippleSeconds = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var rippleTask: Task<Void, Never>?

    func hideSoon() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.kind = .none }
        }
    }

    func ripple(side: Int, seconds: Int) {
        if rippleSide == side && rippleSeconds != 0 { rippleSeconds += seconds } else { rippleSeconds = seconds }
        rippleSide = side
        rippleTask?.cancel()
        rippleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.rippleSide = 0
                self?.rippleSeconds = 0
            }
        }
    }
}

/** The gesture feedback: faster playback, a brightness or volume level, the seek target, the skips. */
private struct PlayerHUD: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        let hud = HUDState.shared
        ZStack {
            if player.recordingGIF {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("Recording GIF").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .kinemaGlass(Capsule(), shadow: false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, player.holding ? 84 : 24)
                .transition(.opacity)
            }
            if player.holding {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(String(format: "%g×", AppGraph.shared.settings.settings.holdSpeed))
                        Image(systemName: "forward.fill")
                    }
                    .font(.system(size: 16, weight: .bold))
                    Text(player.holdLocked ? "Speed kept · let go" : "Swipe up to keep")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .kinemaGlass(Capsule(), shadow: false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
                .transition(.opacity)
            }
            if hud.kind != .none {
                HStack(spacing: 12) {
                    Image(systemName: hud.kind == .brightness ? "sun.max.fill" : hud.level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22)
                    ProgressBar(value: hud.level, height: 5).frame(width: 150)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .kinemaGlass(Capsule(), shadow: false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
                .transition(.opacity)
            }
            if let target = player.clock.scrubbing {
                SeekPreview(target: target, large: true)
            }
            if hud.rippleSide != 0 {
                HStack {
                    if hud.rippleSide > 0 { Spacer() }
                    VStack(spacing: 6) {
                        Image(systemName: hud.rippleSide < 0 ? "gobackward" : "goforward")
                            .font(.system(size: 30, weight: .semibold))
                        Text("\(hud.rippleSeconds > 0 ? "+" : "")\(hud.rippleSeconds)s")
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 140)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .padding(.horizontal, 60)
                    if hud.rippleSide < 0 { Spacer() }
                }
                .transition(.opacity)
            }
            if player.isBuffering && player.phase != .ended && !isFailed(player.phase) && !player.controlsVisible {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.holding)
        .animation(.easeInOut(duration: 0.2), value: hud.kind)
    }

    private func isFailed(_ phase: PlaybackPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}

/** Where a seek would land: the trickplay thumbnail of that moment, the time, and how far that is. */
struct SeekPreview: View {
    let target: Double
    var large = false
    @State private var refresh = 0

    var body: some View {
        let player = AppGraph.shared.player
        let delta = target - player.clock.position
        VStack(spacing: 8) {
            if let thumbs = player.trickplay {
                let width: CGFloat = large ? 240 : 168
                Group {
                    if let image = thumbs.thumbnail(at: target, onLoad: { refresh += 1 }) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.black.opacity(0.5)
                    }
                }
                .frame(width: width, height: width / thumbs.aspect)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 10)
                .id(refresh)
            }
            VStack(spacing: 2) {
                Text(Format.clock(target))
                    .font(.system(size: large ? 26 : 15, weight: .bold).monospacedDigit())
                if large {
                    Text("\(delta >= 0 ? "+" : "−")\(Format.clock(abs(delta)))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
        }
    }
}

/** Locked: nothing responds but a lock button, which shows when the screen is tapped. */
private struct LockedOverlay: View {
    var body: some View {
        let player = AppGraph.shared.player
        VStack {
            Spacer()
            HStack {
                GlassIconButton(icon: "lock.fill", size: 54, label: "Unlock") {
                    player.locked = false
                    player.showControls()
                }
                .padding(.leading, 30)
                Spacer()
            }
            .padding(.bottom, 30)
        }
        .opacity(player.controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: player.controlsVisible)
    }
}

/** Bottom right: Skip Intro / Skip Credits, and Up Next. Shown even with the controls hidden. */
private struct PlayerCorner: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        VStack {
            Spacer()
            HStack {
                Spacer()
                if player.upNextShown, let next = player.nextEpisode {
                    UpNextCard(next: next)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if player.skipButtonShown, let segment = player.activeSegment, !player.locked {
                    Button { player.skipSegment() } label: {
                        HStack(spacing: 8) {
                            Text(segment.skipLabel)
                            Image(systemName: "forward.end.fill")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 50)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .kinemaGlass(Capsule(), interactive: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.trailing, 36)
            .padding(.bottom, player.controlsVisible && !player.locked ? 128 : 34)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.skipButtonShown)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.controlsVisible)
    }
}

private struct UpNextCard: View {
    @Environment(\.kinema) private var theme
    let next: Item

    var body: some View {
        let player = AppGraph.shared.player
        let total = Double(AppGraph.shared.settings.settings.upNextCountdown)
        HStack(spacing: 14) {
            ArtworkImage(image: next.image(.primary) ?? next.landscapeImage, width: 360, label: next.name, icon: "tv")
                .frame(width: 132, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if let left = player.upNextCountdown {
                        ZStack {
                            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: total > 0 ? CGFloat(Double(left) / total) : 0)
                                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 1), value: left)
                            Text("\(left)").font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        }
                        .frame(width: 40, height: 40)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("UP NEXT · \(next.episodeLabel ?? "")")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.7))
                Text(next.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button { player.playNext() } label: {
                        Label("Play Now", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.colors.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(theme.colors.accent))
                    }
                    .buttonStyle(PressScaleStyle())
                    Button { player.hideUpNext() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Dismiss")
                }
                .padding(.top, 2)
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(12)
        .kinemaGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/** Playback failed: why, and what can be done. */
private struct PlayerError: View {
    let message: String

    var body: some View {
        let player = AppGraph.shared.player
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
            Text("Can't play this")
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .opacity(0.8)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Pill("Try again", icon: "arrow.clockwise", accent: true) { player.retry() }
                Pill("Close", icon: "xmark") { player.close() }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(28)
        .kinemaGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(40)
    }
}
