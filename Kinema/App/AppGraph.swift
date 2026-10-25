import Foundation

/**
 * The app's object graph. Built once and reached through [AppGraph.shared]
 * from the player, background downloads and the interface.
 */
@MainActor
final class AppGraph {
    static let shared = AppGraph()

    let settings = SettingsStore()
    let messages = UiMessages()
    let network = NetworkMonitor()
    let auth = AuthRepository()
    let ui = AppUI()
    let updates = UpdateChecker()
    let markers = MarkersStore()
    // Lazy only so they can be handed `self`; all of them are created in init.
    private(set) lazy var library = LibraryStore(graph: self)
    private(set) lazy var downloads = DownloadManager(graph: self)
    private(set) lazy var player = PlayerModel(graph: self)
    private(set) lazy var actions = AppActions(graph: self)

    private init() {
        _ = (library, downloads, player, actions)
        auth.observeActive { [unowned self] _ in
            self.library.reset()
            self.ui.resetPaths()
            self.downloads.reload()
        }
        if !auth.profiles.isEmpty && !ui.welcomed { ui.finishWelcome() }
        downloads.start()
        Task { await auth.refreshUser() }
    }

    /** An image of the server in use, scaled to about [width] pixels (snapped, so caches keep hitting). */
    func imageURL(_ ref: ImageRef, width: Int) -> URL? {
        let buckets = [120, 240, 360, 540, 780, 1080, 1440, 1920]
        let snapped = buckets.first { $0 >= width } ?? 1920
        return auth.client?.imageURL(ref, maxWidth: snapped)
    }

    /** The streaming bitrate allowed right now. */
    var maxBitrate: Int { settings.settings.maxBitrate(metered: network.metered) }

    /** The device profile for the connection in use. */
    func deviceProfile(maxBitrate: Int? = nil) -> DeviceProfile {
        DeviceProfileBuilder.build(capabilities, maxBitrate: maxBitrate ?? self.maxBitrate, allowDirectPlay: settings.settings.directPlay)
    }

    /** What the phone decodes, less what was turned off in Settings → Playback. */
    var capabilities: DeviceCapabilities {
        var caps = DeviceSupport.capabilities
        let s = settings.settings
        caps.hevc = caps.hevc && s.allowHEVC
        caps.av1 = caps.av1 && s.allowAV1
        caps.dolbyVision = caps.dolbyVision && s.allowDolbyVision && caps.hevc
        caps.hdr = caps.hdr && caps.hevc
        return caps
    }
}
