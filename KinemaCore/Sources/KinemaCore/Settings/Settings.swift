import Foundation

enum ThemeMode: String, Codable, CaseIterable, Hashable {
    case system, dark, light

    var label: String {
        switch self {
        case .system: return "Automatic"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

enum CornerStyle: String, Codable, CaseIterable, Hashable {
    case sharp, soft, round

    var label: String { rawValue.capitalized }
}

enum PosterSize: String, Codable, CaseIterable, Hashable {
    case small, medium, large

    var label: String { rawValue.capitalized }

    /** Posters per row on an iPhone in portrait. */
    var columns: Int {
        switch self {
        case .small: return 4
        case .medium: return 3
        case .large: return 2
        }
    }
}

enum ResumeBehavior: String, Codable, CaseIterable, Hashable {
    case resume, ask, restart

    var label: String {
        switch self {
        case .resume: return "Pick up where I left off"
        case .ask: return "Ask every time"
        case .restart: return "Start from the beginning"
        }
    }
}

/** What happens at an intro, the credits or a recap. */
enum SkipMode: String, Codable, CaseIterable, Hashable {
    case button, automatic, off

    var label: String {
        switch self {
        case .button: return "Show a Skip button"
        case .automatic: return "Skip automatically"
        case .off: return "Do nothing"
        }
    }
}

/** When subtitles come on by themselves (Jellyfin's own modes, plus the server's choice). */
enum SubtitleMode: String, Codable, CaseIterable, Hashable {
    case serverDefault, always, onlyForced, smart, none

    var label: String {
        switch self {
        case .serverDefault: return "As set on the server"
        case .always: return "Always"
        case .onlyForced: return "Only forced"
        case .smart: return "When the audio is in another language"
        case .none: return "Never"
        }
    }
}

enum AspectMode: String, Codable, CaseIterable, Hashable {
    case fit, fill, stretch

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var next: AspectMode {
        switch self {
        case .fit: return .fill
        case .fill: return .stretch
        case .stretch: return .fit
        }
    }
}

enum SubtitleFont: String, Codable, CaseIterable, Hashable {
    case system, rounded, serif, mono

    var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Monospaced"
        }
    }
}

/** Where a second subtitle track goes. */
enum SecondaryPosition: String, Codable, CaseIterable, Hashable {
    case top, abovePrimary

    var label: String { self == .top ? "Top of the picture" : "Above the first" }
}

/** How good a downloaded copy is. */
enum DownloadQuality: String, Codable, CaseIterable, Hashable {
    case original, high, medium, low

    var label: String {
        switch self {
        case .original: return "Original"
        case .high: return "1080p · 20 Mbps"
        case .medium: return "720p · 8 Mbps"
        case .low: return "480p · 3 Mbps"
        }
    }

    var maxBitrate: Int? {
        switch self {
        case .original: return nil
        case .high: return 20_000_000
        case .medium: return 8_000_000
        case .low: return 3_000_000
        }
    }
}

/** A section of the home page. */
enum HomeSection: String, Codable, CaseIterable, Hashable {
    case hero, continueWatching, nextUp, latest, favorites, collections, genres

    var label: String {
        switch self {
        case .hero: return "Featured"
        case .continueWatching: return "Continue Watching"
        case .nextUp: return "Next Up"
        case .latest: return "Recently Added (each library)"
        case .favorites: return "Favorites"
        case .collections: return "Collections"
        case .genres: return "Genres"
        }
    }

    static let defaults: [HomeSection] = [.hero, .continueWatching, .nextUp, .latest, .favorites]
}

/** Streaming quality: the most the server may send. 0 means as much as the file needs. */
enum StreamingQuality {
    static let options: [(Int, String)] = [
        (0, "Maximum"),
        (60_000_000, "60 Mbps"),
        (40_000_000, "40 Mbps"),
        (20_000_000, "20 Mbps · 1080p"),
        (12_000_000, "12 Mbps · 1080p"),
        (8_000_000, "8 Mbps · 720p"),
        (4_000_000, "4 Mbps · 720p"),
        (2_000_000, "2 Mbps · 480p"),
        (1_000_000, "1 Mbps · 360p"),
    ]

    static let maximum = 200_000_000

    static func label(_ bitrate: Int) -> String {
        options.first { $0.0 == bitrate }?.1 ?? Format.bitrate(Double(bitrate))
    }
}

/** Which subtitle files to prefer when one comes on by itself. */
enum SubtitleSource: String, Codable, CaseIterable, Hashable {
    case any, embedded, external

    var label: String {
        switch self {
        case .any: return "Either"
        case .embedded: return "Inside the video"
        case .external: return "Separate files"
        }
    }
}

enum ScreenshotFormat: String, Codable, CaseIterable, Hashable {
    case jpeg, png, heic

    var label: String { rawValue.uppercased() }
}

/** How far a sideways swipe on the picture seeks. */
enum SeekSensitivity: String, Codable, CaseIterable, Hashable {
    case low, normal, high

    var label: String { rawValue.capitalized }

    var factor: Double {
        switch self {
        case .low: return 0.5
        case .normal: return 1
        case .high: return 2
        }
    }
}

/**
 * Every preference, kept as one JSON document. Unknown or missing fields fall
 * back to their defaults, so settings survive upgrades in both directions.
 */
struct Settings: Codable, Hashable {
    // Appearance
    var theme: ThemeMode = .dark
    var nightMode = false
    var corners: CornerStyle = .soft
    var posterSize: PosterSize = .medium
    var backdrops = true
    var reduceMotion = false
    var homeSections: [HomeSection] = HomeSection.defaults
    var hiddenLibraries: [String] = []
    var mergeNextUp = false

    // General
    var hideSpoilers = false
    var defaultSort = "name"
    var defaultSortDescending = false
    var askOnCellular = false

    // Playback
    var maxBitrateWifi = 0
    var maxBitrateCellular = 8_000_000
    var directPlay = true
    var resume: ResumeBehavior = .resume
    var autoplayNext = true
    var upNextCountdown = 10
    var skipIntro: SkipMode = .button
    var skipCredits: SkipMode = .button
    var skipRecap: SkipMode = .button
    var skipBack = 10
    var skipForward = 10
    var doubleTapSeek = true
    var defaultSpeed = 1.0
    var holdSpeed = 2.0
    var brightnessGesture = true
    var volumeGesture = true
    var seekGesture = true
    var pinchToZoom = true
    var autoPiP = true
    var backgroundAudio = false
    var aspect: AspectMode = .fit
    var showRemaining = false
    var audioLanguage = ""
    var subtitleMode: SubtitleMode = .serverDefault
    var subtitleLanguage = ""
    var showSkipButtons = true
    var showEpisodeButtons = true
    var rememberSpeed = false
    var lastSpeed = 1.0
    var preloadNextEpisode = true
    /** Megabytes of video to load ahead; 0 lets iOS decide. */
    var maxCacheMB = 0
    var allowHEVC = true
    var allowAV1 = true
    var allowDolbyVision = true

    // Player interface
    /** Seconds before the controls hide; 0 keeps them until tapped. */
    var controlsHideDelay = 4
    var controlsShadow = true
    var landscapeByDefault = true
    var showCaptureButtons = true
    var seekSensitivity: SeekSensitivity = .normal

    // Screenshots and GIFs
    var screenshotFormat: ScreenshotFormat = .jpeg
    var gifFrameRate = 15
    var gifWidth = 480

    // Subtitles
    var subtitleSize = 100.0
    var subtitleColor = "#FFFFFF"
    var subtitleOutline = 2.0
    var subtitleBackground = 0.0
    var subtitleBold = false
    var subtitleFont: SubtitleFont = .system
    var subtitleMargin = 6.0
    var subtitleBrightness = 1.0
    var secondaryPosition: SecondaryPosition = .top
    var secondaryScale = 0.85
    var subtitleSource: SubtitleSource = .any
    var loadEmbeddedSubtitles = true
    var onlineSubtitleLanguage = ""

    // Downloads
    var downloadQuality: DownloadQuality = .original
    var downloadOnCellular = false
    var downloadSubtitles = true
    var concurrentDownloads = 2
    var showDownloadIndicator = true
    var pauseDownloadsWhilePlaying = false

    var hasSeenWelcome = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case theme, nightMode, corners, posterSize, backdrops, reduceMotion, homeSections, hiddenLibraries, mergeNextUp
        case hideSpoilers, defaultSort, defaultSortDescending, askOnCellular
        case rememberSpeed, lastSpeed, preloadNextEpisode, maxCacheMB, allowHEVC, allowAV1, allowDolbyVision
        case controlsHideDelay, controlsShadow, landscapeByDefault, showCaptureButtons, seekSensitivity
        case screenshotFormat, gifFrameRate, gifWidth
        case subtitleSource, loadEmbeddedSubtitles, onlineSubtitleLanguage
        case concurrentDownloads, showDownloadIndicator, pauseDownloadsWhilePlaying
        case maxBitrateWifi, maxBitrateCellular, directPlay, resume, autoplayNext, upNextCountdown, skipIntro, skipCredits, skipRecap
        case skipBack, skipForward, doubleTapSeek, defaultSpeed, holdSpeed, brightnessGesture, volumeGesture, seekGesture, pinchToZoom
        case autoPiP, backgroundAudio, aspect, showRemaining, audioLanguage, subtitleMode, subtitleLanguage, showSkipButtons, showEpisodeButtons
        case subtitleSize, subtitleColor, subtitleOutline, subtitleBackground, subtitleBold, subtitleFont, subtitleMargin, subtitleBrightness
        case secondaryPosition, secondaryScale
        case downloadQuality, downloadOnCellular, downloadSubtitles, hasSeenWelcome
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        theme = c.lenient(ThemeMode.self, .theme) ?? d.theme
        nightMode = c.lenient(Bool.self, .nightMode) ?? d.nightMode
        corners = c.lenient(CornerStyle.self, .corners) ?? d.corners
        posterSize = c.lenient(PosterSize.self, .posterSize) ?? d.posterSize
        backdrops = c.lenient(Bool.self, .backdrops) ?? d.backdrops
        reduceMotion = c.lenient(Bool.self, .reduceMotion) ?? d.reduceMotion
        // Sections this version doesn't know are dropped rather than failing the list.
        if let raw = c.lenient([String].self, .homeSections) {
            homeSections = raw.compactMap(HomeSection.init(rawValue:))
        }
        hiddenLibraries = c.lenient([String].self, .hiddenLibraries) ?? d.hiddenLibraries
        mergeNextUp = c.lenient(Bool.self, .mergeNextUp) ?? d.mergeNextUp

        hideSpoilers = c.lenient(Bool.self, .hideSpoilers) ?? d.hideSpoilers
        defaultSort = c.lenient(String.self, .defaultSort) ?? d.defaultSort
        defaultSortDescending = c.lenient(Bool.self, .defaultSortDescending) ?? d.defaultSortDescending
        askOnCellular = c.lenient(Bool.self, .askOnCellular) ?? d.askOnCellular
        rememberSpeed = c.lenient(Bool.self, .rememberSpeed) ?? d.rememberSpeed
        lastSpeed = c.number(.lastSpeed) ?? d.lastSpeed
        preloadNextEpisode = c.lenient(Bool.self, .preloadNextEpisode) ?? d.preloadNextEpisode
        maxCacheMB = c.int(.maxCacheMB) ?? d.maxCacheMB
        allowHEVC = c.lenient(Bool.self, .allowHEVC) ?? d.allowHEVC
        allowAV1 = c.lenient(Bool.self, .allowAV1) ?? d.allowAV1
        allowDolbyVision = c.lenient(Bool.self, .allowDolbyVision) ?? d.allowDolbyVision
        controlsHideDelay = c.int(.controlsHideDelay) ?? d.controlsHideDelay
        controlsShadow = c.lenient(Bool.self, .controlsShadow) ?? d.controlsShadow
        landscapeByDefault = c.lenient(Bool.self, .landscapeByDefault) ?? d.landscapeByDefault
        showCaptureButtons = c.lenient(Bool.self, .showCaptureButtons) ?? d.showCaptureButtons
        seekSensitivity = c.lenient(SeekSensitivity.self, .seekSensitivity) ?? d.seekSensitivity
        screenshotFormat = c.lenient(ScreenshotFormat.self, .screenshotFormat) ?? d.screenshotFormat
        gifFrameRate = c.int(.gifFrameRate) ?? d.gifFrameRate
        gifWidth = c.int(.gifWidth) ?? d.gifWidth
        subtitleSource = c.lenient(SubtitleSource.self, .subtitleSource) ?? d.subtitleSource
        loadEmbeddedSubtitles = c.lenient(Bool.self, .loadEmbeddedSubtitles) ?? d.loadEmbeddedSubtitles
        onlineSubtitleLanguage = c.lenient(String.self, .onlineSubtitleLanguage) ?? d.onlineSubtitleLanguage
        concurrentDownloads = c.int(.concurrentDownloads) ?? d.concurrentDownloads
        showDownloadIndicator = c.lenient(Bool.self, .showDownloadIndicator) ?? d.showDownloadIndicator
        pauseDownloadsWhilePlaying = c.lenient(Bool.self, .pauseDownloadsWhilePlaying) ?? d.pauseDownloadsWhilePlaying

        maxBitrateWifi = c.int(.maxBitrateWifi) ?? d.maxBitrateWifi
        maxBitrateCellular = c.int(.maxBitrateCellular) ?? d.maxBitrateCellular
        directPlay = c.lenient(Bool.self, .directPlay) ?? d.directPlay
        resume = c.lenient(ResumeBehavior.self, .resume) ?? d.resume
        autoplayNext = c.lenient(Bool.self, .autoplayNext) ?? d.autoplayNext
        upNextCountdown = c.int(.upNextCountdown) ?? d.upNextCountdown
        skipIntro = c.lenient(SkipMode.self, .skipIntro) ?? d.skipIntro
        skipCredits = c.lenient(SkipMode.self, .skipCredits) ?? d.skipCredits
        skipRecap = c.lenient(SkipMode.self, .skipRecap) ?? d.skipRecap
        skipBack = c.int(.skipBack) ?? d.skipBack
        skipForward = c.int(.skipForward) ?? d.skipForward
        doubleTapSeek = c.lenient(Bool.self, .doubleTapSeek) ?? d.doubleTapSeek
        defaultSpeed = c.number(.defaultSpeed) ?? d.defaultSpeed
        holdSpeed = c.number(.holdSpeed) ?? d.holdSpeed
        brightnessGesture = c.lenient(Bool.self, .brightnessGesture) ?? d.brightnessGesture
        volumeGesture = c.lenient(Bool.self, .volumeGesture) ?? d.volumeGesture
        seekGesture = c.lenient(Bool.self, .seekGesture) ?? d.seekGesture
        pinchToZoom = c.lenient(Bool.self, .pinchToZoom) ?? d.pinchToZoom
        autoPiP = c.lenient(Bool.self, .autoPiP) ?? d.autoPiP
        backgroundAudio = c.lenient(Bool.self, .backgroundAudio) ?? d.backgroundAudio
        aspect = c.lenient(AspectMode.self, .aspect) ?? d.aspect
        showRemaining = c.lenient(Bool.self, .showRemaining) ?? d.showRemaining
        audioLanguage = c.lenient(String.self, .audioLanguage) ?? d.audioLanguage
        subtitleMode = c.lenient(SubtitleMode.self, .subtitleMode) ?? d.subtitleMode
        subtitleLanguage = c.lenient(String.self, .subtitleLanguage) ?? d.subtitleLanguage
        showSkipButtons = c.lenient(Bool.self, .showSkipButtons) ?? d.showSkipButtons
        showEpisodeButtons = c.lenient(Bool.self, .showEpisodeButtons) ?? d.showEpisodeButtons

        subtitleSize = c.number(.subtitleSize) ?? d.subtitleSize
        subtitleColor = c.lenient(String.self, .subtitleColor) ?? d.subtitleColor
        subtitleOutline = c.number(.subtitleOutline) ?? d.subtitleOutline
        subtitleBackground = c.number(.subtitleBackground) ?? d.subtitleBackground
        subtitleBold = c.lenient(Bool.self, .subtitleBold) ?? d.subtitleBold
        subtitleFont = c.lenient(SubtitleFont.self, .subtitleFont) ?? d.subtitleFont
        subtitleMargin = c.number(.subtitleMargin) ?? d.subtitleMargin
        subtitleBrightness = c.number(.subtitleBrightness) ?? d.subtitleBrightness
        secondaryPosition = c.lenient(SecondaryPosition.self, .secondaryPosition) ?? d.secondaryPosition
        secondaryScale = c.number(.secondaryScale) ?? d.secondaryScale

        downloadQuality = c.lenient(DownloadQuality.self, .downloadQuality) ?? d.downloadQuality
        downloadOnCellular = c.lenient(Bool.self, .downloadOnCellular) ?? d.downloadOnCellular
        downloadSubtitles = c.lenient(Bool.self, .downloadSubtitles) ?? d.downloadSubtitles
        hasSeenWelcome = c.lenient(Bool.self, .hasSeenWelcome) ?? d.hasSeenWelcome
    }

    /** The speeds offered in the player. */
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]

    static let skipIntervals = [5, 10, 15, 30, 60]

    static let hideDelays = [2, 3, 4, 6, 8, 0]

    static let gifFrameRates = [10, 15, 20, 24]

    static let gifWidths = [320, 480, 640, 800]
}

extension Settings {
    /** The most the server may stream right now, on a metered connection or not. */
    func maxBitrate(metered: Bool) -> Int {
        let chosen = metered ? maxBitrateCellular : maxBitrateWifi
        return chosen > 0 ? chosen : StreamingQuality.maximum
    }

    /** The speed a video starts at. */
    var startSpeed: Double { rememberSpeed ? lastSpeed : defaultSpeed }

    /**
     * Seconds of video to load ahead for a stream of [bitrate] bits a second,
     * from the maximum cache; 0 lets iOS decide.
     */
    func forwardBuffer(bitrate: Int?) -> Double {
        guard maxCacheMB > 0 else { return 0 }
        let rate = Double(max(500_000, bitrate ?? 8_000_000))
        return min(3600, max(15, Double(maxCacheMB) * 8_000_000 / rate))
    }
}
