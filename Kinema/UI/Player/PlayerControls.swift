import AVKit
import SwiftUI

/**
 * The player's controls: what's playing and the way out at the top, play and
 * skip in the middle, the scrubber and the tools at the bottom.
 */
struct PlayerControls: View {
    @Environment(\.kinema) private var theme

    var body: some View {
        let player = AppGraph.shared.player
        ZStack {
            // The shade behind the controls (Settings → Player → Shadow behind the controls).
            if AppGraph.shared.settings.settings.controlsShadow {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 190)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                TopBar()
                Spacer()
                CenterControls()
                Spacer()
                VStack(spacing: 10) {
                    Scrubber()
                    BottomBar()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
        .onChange(of: player.controlsVisible) { _, visible in
            if visible { player.scheduleHide() }
        }
    }
}

private struct TopBar: View {
    var body: some View {
        let player = AppGraph.shared.player
        let item = player.item
        HStack(alignment: .center, spacing: 14) {
            ControlButton(icon: "xmark", label: "Close") { player.close() }
            VStack(alignment: .leading, spacing: 2) {
                if let item {
                    if item.kind == .episode {
                        Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                    Text(item.name)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if player.offline != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .opacity(0.7)
                    .accessibilityLabel("Playing the download")
            }
            AirPlayButton()
                .frame(width: 40, height: 40)
            if player.pipPossible {
                ControlButton(icon: player.pipActive ? "pip.exit" : "pip.enter", label: "Picture in Picture") { player.togglePictureInPicture() }
            }
            MoreMenu()
        }
        .frame(height: 48)
    }
}

/** Everything that doesn't need a button of its own. */
private struct MoreMenu: View {
    var body: some View {
        let player = AppGraph.shared.player
        let settings = AppGraph.shared.settings.settings
        Menu {
            if player.offline == nil {
                Button { open(.quality) } label: { Label("Quality", systemImage: "dial.medium") }
            }
            Button { open(.subtitleStyle) } label: { Label("Subtitle style", systemImage: "textformat.size") }
            if player.offline == nil {
                Button { open(.onlineSubtitles) } label: { Label("Find subtitles online", systemImage: "magnifyingglass") }
            }
            Divider()
            Button { player.statsVisible.toggle() } label: {
                Label(player.statsVisible ? "Hide playback info" : "Playback info", systemImage: "info.circle")
            }
            Button { player.screenshot() } label: { Label("Screenshot", systemImage: "camera") }
            Button { player.toggleGIF() } label: {
                Label(player.recordingGIF ? "Stop and save the GIF" : "Record a GIF", systemImage: "record.circle")
            }
            Button { player.toggleOrientation() } label: {
                Label(player.portrait ? "Landscape" : "Portrait", systemImage: "rectangle.portrait.rotate")
            }
            Section(player.segmentSources.map { "Skipping · from \($0)" } ?? "Skipping") {
                Toggle(isOn: Binding(get: { settings.skipIntro == .automatic }, set: { player.setAutoSkip(intro: $0) })) {
                    Label("Skip intros automatically", systemImage: "forward.end")
                }
                Toggle(isOn: Binding(get: { settings.skipCredits == .automatic }, set: { player.setAutoSkip(credits: $0) })) {
                    Label("Skip credits automatically", systemImage: "forward.end.alt")
                }
                Toggle(isOn: Binding(get: { settings.onlineSegments }, set: { player.setOnlineSegments($0) })) {
                    Label("Find intros and credits online", systemImage: "globe")
                }
            }
            if player.item?.kind == .episode {
                Section("Intro and credits for this show") {
                    Button { player.markIntroEnd() } label: { Label("The intro ends here", systemImage: "flag") }
                    Button { player.markCreditsStart() } label: { Label("The credits start here", systemImage: "flag.checkered") }
                    if player.hasMarkers {
                        Button(role: .destructive) { player.clearMarkers() } label: { Label("Clear the marks", systemImage: "flag.slash") }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    private func open(_ panel: PlayerPanel) {
        AppGraph.shared.player.panel = panel
    }
}

private struct CenterControls: View {
    var body: some View {
        let player = AppGraph.shared.player
        let settings = AppGraph.shared.settings.settings
        HStack(spacing: 46) {
            if settings.showEpisodeButtons && player.previousEpisode != nil {
                ControlButton(icon: "backward.end.fill", label: "Previous episode", size: 22) { player.playPrevious() }
            }
            ControlButton(icon: "gobackward.\(settings.skipBack)", fallback: "gobackward", label: "Back \(settings.skipBack) seconds", size: 30) {
                player.skip(-Double(settings.skipBack))
                player.showControls()
            }
            ZStack {
                if player.isBuffering && player.phase != .ended {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Button { player.togglePlay(); player.showControls() } label: {
                        Image(systemName: player.phase == .ended ? "arrow.counterclockwise" : player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 78, height: 78)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
            }
            .frame(width: 80, height: 80)
            ControlButton(icon: "goforward.\(settings.skipForward)", fallback: "goforward", label: "Forward \(settings.skipForward) seconds", size: 30) {
                player.skip(Double(settings.skipForward))
                player.showControls()
            }
            if settings.showEpisodeButtons && player.nextEpisode != nil {
                ControlButton(icon: "forward.end.fill", label: "Next episode", size: 22) { player.playNext() }
            }
        }
    }
}

private struct BottomBar: View {
    var body: some View {
        let player = AppGraph.shared.player
        HStack(spacing: 6) {
            ToolButton(icon: "speedometer", text: String(format: "%g×", player.speed)) { player.panel = .speed }
            ToolButton(icon: "waveform", text: "Audio") { player.panel = .audio }
            ToolButton(icon: player.subtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill", text: "Subtitles") { player.panel = .subtitles }
            if !player.chapters.isEmpty {
                ToolButton(icon: "list.bullet.rectangle", text: "Chapters") { player.panel = .chapters }
            }
            if player.seasonEpisodes.count > 1 {
                ToolButton(icon: "rectangle.stack", text: "Episodes") { player.panel = .episodes }
            }
            Spacer(minLength: 4)
            if AppGraph.shared.settings.settings.showCaptureButtons {
                ControlButton(icon: "camera", label: "Screenshot", size: 16) { player.screenshot() }
                ControlButton(icon: player.recordingGIF ? "stop.circle.fill" : "record.circle", label: player.recordingGIF ? "Stop recording" : "Record a GIF", size: 16) { player.toggleGIF() }
            }
            ToolButton(icon: aspectIcon(player.aspect), text: player.aspect.label) { player.cycleAspect() }
            ToolButton(icon: "lock.open", text: "Lock") {
                player.locked = true
                player.panel = nil
                Haptics.tap()
            }
        }
    }

    private func aspectIcon(_ aspect: AspectMode) -> String {
        switch aspect {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }
}

/** A round icon button over the video. */
struct ControlButton: View {
    let icon: String
    var fallback: String?
    let label: String
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: UIImage(systemName: icon) != nil ? icon : (fallback ?? icon))
                .font(.system(size: size, weight: .semibold))
                .frame(width: max(44, size * 1.8), height: max(44, size * 1.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

/** An icon with a word under it, for the tools along the bottom. */
private struct ToolButton: View {
    let icon: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(text)
    }
}

/**
 * The scrubber: what's watched, what's loaded, the chapters, and while
 * dragging, the thumbnail of where it would land.
 */
private struct Scrubber: View {
    @Environment(\.kinema) private var theme
    @State private var dragging = false

    var body: some View {
        let player = AppGraph.shared.player
        let clock = player.clock
        let settings = AppGraph.shared.settings.settings
        let duration = max(clock.duration, 0.001)
        HStack(spacing: 12) {
            Text(Format.clock(clock.scrubbing ?? clock.position))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(minWidth: 52, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                let progress = clock.progress
                let buffered = min(1, clock.buffered / duration)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: dragging ? 8 : 5)
                    Capsule().fill(.white.opacity(0.35)).frame(width: width * buffered, height: dragging ? 8 : 5)
                    // Intros and credits, as lighter stretches of the bar.
                    ForEach(player.segments) { segment in
                        let from = min(1, max(0, segment.start / duration))
                        let to = min(1, max(0, segment.end / duration))
                        Capsule().fill(.white.opacity(0.45))
                            .frame(width: max(2, width * (to - from)), height: dragging ? 8 : 5)
                            .offset(x: width * from)
                    }
                    Capsule().fill(theme.colors.accent).frame(width: max(0, width * progress), height: dragging ? 8 : 5)
                    // Chapter marks: small gaps in the bar.
                    ForEach(Array(player.chapters.enumerated()), id: \.offset) { _, chapter in
                        if chapter.start > 1 {
                            Rectangle().fill(.black.opacity(0.6))
                                .frame(width: 2, height: dragging ? 8 : 5)
                                .offset(x: width * min(1, chapter.start / duration) - 1)
                        }
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .offset(x: width * progress - (dragging ? 11 : 7))
                    if dragging, let target = clock.scrubbing {
                        SeekPreview(target: target)
                            .fixedSize()
                            .position(x: min(max(90, width * progress), width - 90), y: -86)
                    }
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !dragging { dragging = true; Haptics.select() }
                            clock.scrubbing = min(1, max(0, value.location.x / max(1, width))) * duration
                            player.showControls()
                        }
                        .onEnded { _ in
                            if let target = clock.scrubbing {
                                clock.scrubbing = nil
                                player.seek(to: target, precise: true)
                            }
                            dragging = false
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 32)
            Button {
                AppGraph.shared.settings.update { $0.showRemaining.toggle() }
            } label: {
                Text(settings.showRemaining ? "−\(Format.clock(max(0, duration - (clock.scrubbing ?? clock.position))))" : Format.clock(clock.duration))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 58, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(Format.clock(clock.position)) of \(Format.clock(clock.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(Double(settings.skipForward))
            case .decrement: player.skip(-Double(settings.skipBack))
            @unknown default: break
            }
        }
    }
}

/** Playback info: how it's being played, codecs and bitrates, live. */
struct StatsPanel: View {
    @State private var tick = 0

    var body: some View {
        let player = AppGraph.shared.player
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(player.stats.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 104, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, weight: .medium).monospaced())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.6)))
        .id(tick)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick += 1
            }
        }
    }
}
