import AVFoundation
import AVKit
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/**
 * Where playback is, updated several times a second. Kept apart from the
 * player's other state so only what shows the time redraws that often.
 */
@MainActor
@Observable
final class PlayerClock {
    var position: Double = 0
    var duration: Double = 0
    /** How far ahead of [position] is already loaded. */
    var buffered: Double = 0
    /** While the scrubber or a swipe is being dragged: where it would seek to. */
    var scrubbing: Double?

    var progress: Double { duration > 0 ? min(1, max(0, (scrubbing ?? position) / duration)) : 0 }
    var remaining: Double { max(0, duration - position) }
}

/** The subtitle lines on screen now, for both tracks. */
@MainActor
@Observable
final class SubtitleState {
    var primary: [SubtitleCue] = []
    var secondary: [SubtitleCue] = []
}

/** The view the video is drawn in: a plain AVPlayerLayer, kept alive for Picture in Picture. */
final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // The layer class above makes this always an AVPlayerLayer.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/** The surface inside SwiftUI. The same view every time, so Picture in Picture can come back to it. */
struct VideoSurface: UIViewRepresentable {
    let surface: PlayerSurfaceView
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if surface.superview !== container { attach(to: container) }
        if surface.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            surface.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }

    private func attach(to container: UIView) {
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(surface)
    }
}

/** AirPlay: the system's route picker, in Kinema's colours. */
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
    }
}

/**
 * The phone's volume, which only a system volume view may change. One sits
 * off-screen in the player; its slider is moved by Kinema's swipe, and its
 * presence also hides the system's own volume pop-up.
 */
@MainActor
enum SystemVolume {
    static let view: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        view.alpha = 0.01
        return view
    }()

    private static var slider: UISlider? {
        view.subviews.compactMap { $0 as? UISlider }.first
    }

    static var value: Float {
        get { slider?.value ?? AVAudioSession.sharedInstance().outputVolume }
        set { slider?.setValue(min(1, max(0, newValue)), animated: false) }
    }
}

/** Keeps the hidden volume view in the player's hierarchy. */
struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.addSubview(SystemVolume.view)
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {
        if SystemVolume.view.superview !== view { view.addSubview(SystemVolume.view) }
    }
}

/** The screen's brightness, for the swipe on the left side of the player. */
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    static var value: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = min(1, max(0, newValue)) }
    }
}

/**
 * Scrubbing thumbnails from the server's trickplay sheets: each sheet image
 * is fetched once, and the thumbnail for a moment is cut out of it.
 */
@MainActor
final class TrickplayThumbnails {
    private let itemId: String
    private let mediaSourceId: String?
    private let info: TrickplayInfo
    private let cache = NSCache<NSNumber, UIImage>()
    private var loading: Set<Int> = []

    init?(item: Item, mediaSourceId: String?) {
        guard let info = item.trickplayInfo(mediaSourceId: mediaSourceId, minWidth: 240), info.width > 0, info.height > 0 else { return nil }
        itemId = item.id
        self.mediaSourceId = mediaSourceId
        self.info = info
    }

    var aspect: CGFloat { CGFloat(info.width) / CGFloat(max(1, info.height)) }

    /** The thumbnail for [seconds], if its sheet has arrived; asks for the sheet otherwise. */
    func thumbnail(at seconds: Double, onLoad: @escaping () -> Void) -> UIImage? {
        guard let spot = info.locate(seconds) else { return nil }
        guard let sheet = cache.object(forKey: NSNumber(value: spot.tile)) else {
            load(spot.tile, onLoad: onLoad)
            return nil
        }
        let rect = CGRect(x: spot.column * info.width, y: spot.row * info.height, width: info.width, height: info.height)
        guard let cg = sheet.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func load(_ tile: Int, onLoad: @escaping () -> Void) {
        guard !loading.contains(tile), let client = AppGraph.shared.auth.client,
              let url = client.trickplayTileURL(itemId: itemId, width: info.width, index: tile, mediaSourceId: mediaSourceId)
        else { return }
        loading.insert(tile)
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
                cache.setObject(image, forKey: NSNumber(value: tile))
                onLoad()
            }
            loading.remove(tile)
        }
    }
}

/** Lock screen, Control Center and headphone controls for what is playing. */
@MainActor
enum NowPlaying {
    private static var registered = false

    static func register(_ player: PlayerModel) {
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()
        // Remote commands arrive on the main thread.
        func on(_ command: MPRemoteCommand, _ handle: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { event in MainActor.assumeIsolated { handle(event) } }
        }
        on(center.playCommand) { _ in
            player.play()
            return .success
        }
        on(center.pauseCommand) { _ in
            player.pause()
            return .success
        }
        on(center.togglePlayPauseCommand) { _ in
            player.togglePlay()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: player.skipForwardSeconds)]
        on(center.skipForwardCommand) { _ in
            player.skip(Double(player.skipForwardSeconds))
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: player.skipBackSeconds)]
        on(center.skipBackwardCommand) { _ in
            player.skip(-Double(player.skipBackSeconds))
            return .success
        }
        on(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: event.positionTime, precise: true)
            return .success
        }
        on(center.nextTrackCommand) { _ in
            guard player.nextEpisode != nil else { return .noSuchContent }
            player.playNext()
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    static func update(_ player: PlayerModel, artwork: UIImage? = nil) {
        guard let item = player.item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = item.name
        info[MPMediaItemPropertyArtist] = item.kind == .episode ? [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ") : item.yearText
        info[MPMediaItemPropertyPlaybackDuration] = player.clock.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.clock.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? player.speed : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = player.nextEpisode != nil
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
