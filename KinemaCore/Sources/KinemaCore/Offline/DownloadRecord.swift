import Foundation

enum DownloadState: String, Codable, Hashable {
    case queued, downloading, paused, failed, done
}

/** How a downloaded copy was made. */
enum DownloadKind: String, Codable, Hashable {
    /** The original file, as it is on the server. */
    case original
    /** An HLS copy made by the server (repackaged or converted), kept as an AVFoundation movie package. */
    case hls
}

/** A subtitle track saved next to a download. */
struct DownloadedSubtitle: Codable, Hashable, Identifiable {
    var index: Int
    var file: String
    var language: String?
    var title: String
    var isForced: Bool
    var isDefault: Bool

    var id: Int { index }
}

/**
 * One downloaded (or downloading) movie or episode: everything needed to
 * list it and play it with no connection, and to tell the server later how
 * far it was watched.
 */
struct DownloadRecord: Codable, Hashable, Identifiable {
    /** The item's id on the server. */
    var id: String
    /** The account (server + user) it belongs to. */
    var profileId: String
    var item: Item
    var mediaSourceId: String?
    var kind: DownloadKind
    var quality: DownloadQuality
    var state: DownloadState
    /** Path relative to the downloads folder (or, for HLS packages, to the app's home). */
    var file: String?
    var bytes: Int64 = 0
    var expectedBytes: Int64?
    var progress: Double = 0
    var error: String?
    var subtitles: [DownloadedSubtitle] = []
    var posterFile: String?
    var backdropFile: String?
    var createdAt: Date
    /** Downloaded by itself, to keep a show's next episodes ready (Settings → Downloads); nil for older records. */
    var automatic: Bool?
    /** Names the background task downloading it now, so a stale task's news is told apart. */
    var taskToken: String?
    /** Whether that task may use mobile data (Settings → Downloads, when it was started). */
    var cellularAllowed: Bool?
    /** The audio language asked for ("" or nil: the usual one, Settings → Playback). */
    var audioLanguage: String?
    /**
     * The one audio track in a copy made by the server (HLS); the server
     * can't put more than one in. Nil for the original file, which has them
     * all, and for downloads made before this was kept.
     */
    var audioIndex: Int?

    /** Watched offline and not yet told to the server. */
    var localPositionTicks: Int64?
    var localPlayed: Bool?
    var pendingSync = false

    init(id: String, profileId: String, item: Item, mediaSourceId: String?, kind: DownloadKind, quality: DownloadQuality) {
        self.id = id
        self.profileId = profileId
        self.item = item
        self.mediaSourceId = mediaSourceId
        self.kind = kind
        self.quality = quality
        state = .queued
        createdAt = Date()
    }

    var isDone: Bool { state == .done }

    /** Where to start: what was watched here, else what the server last said. */
    var resumeTicks: Int64 {
        if localPlayed == true { return 0 }
        return localPositionTicks ?? item.userData?.playbackPositionTicks ?? 0
    }
}
