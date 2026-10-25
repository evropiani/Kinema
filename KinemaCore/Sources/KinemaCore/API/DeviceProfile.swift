import Foundation

// What this iPhone can play, told to the server so it can choose between
// playing the file as it is, repackaging it (cheap: the streams are copied
// into HLS) or converting it. Kinema plays through AVFoundation, which takes
// MP4 and QuickTime files and HLS; everything else (MKV, AVI, DTS, TrueHD,
// picture subtitles) is repackaged or converted by the server on the fly.

struct ProfileCondition: Codable, Hashable {
    var condition: String
    var property: String
    var value: String
    var isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case condition = "Condition", property = "Property", value = "Value", isRequired = "IsRequired"
    }

    init(_ condition: String, _ property: String, _ value: String, required: Bool = false) {
        self.condition = condition
        self.property = property
        self.value = value
        isRequired = required
    }
}

struct DirectPlayProfile: Codable, Hashable {
    var container: String
    var type: String
    var videoCodec: String?
    var audioCodec: String?

    enum CodingKeys: String, CodingKey {
        case container = "Container", type = "Type", videoCodec = "VideoCodec", audioCodec = "AudioCodec"
    }
}

struct TranscodingProfile: Codable, Hashable {
    var container: String
    var type: String
    var videoCodec: String?
    var audioCodec: String?
    var `protocol`: String
    var context: String
    var maxAudioChannels: String?
    var minSegments: Int?
    var breakOnNonKeyFrames: Bool?
    var copyTimestamps: Bool?
    var enableSubtitlesInManifest: Bool?

    enum CodingKeys: String, CodingKey {
        case container = "Container", type = "Type", videoCodec = "VideoCodec", audioCodec = "AudioCodec"
        case `protocol` = "Protocol", context = "Context", maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments", breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case copyTimestamps = "CopyTimestamps", enableSubtitlesInManifest = "EnableSubtitlesInManifest"
    }
}

struct CodecProfile: Codable, Hashable {
    var type: String
    var codec: String?
    var container: String?
    var conditions: [ProfileCondition]
    var applyConditions: [ProfileCondition]?

    enum CodingKeys: String, CodingKey {
        case type = "Type", codec = "Codec", container = "Container", conditions = "Conditions", applyConditions = "ApplyConditions"
    }
}

struct SubtitleProfile: Codable, Hashable {
    var format: String
    var method: String

    enum CodingKeys: String, CodingKey {
        case format = "Format", method = "Method"
    }
}

struct DeviceProfile: Codable, Hashable {
    var name: String
    var maxStreamingBitrate: Int
    var maxStaticBitrate: Int
    var musicStreamingTranscodingBitrate: Int
    var directPlayProfiles: [DirectPlayProfile]
    var transcodingProfiles: [TranscodingProfile]
    var containerProfiles: [String]
    var codecProfiles: [CodecProfile]
    var subtitleProfiles: [SubtitleProfile]

    enum CodingKeys: String, CodingKey {
        case name = "Name", maxStreamingBitrate = "MaxStreamingBitrate", maxStaticBitrate = "MaxStaticBitrate"
        case musicStreamingTranscodingBitrate = "MusicStreamingTranscodingBitrate"
        case directPlayProfiles = "DirectPlayProfiles", transcodingProfiles = "TranscodingProfiles"
        case containerProfiles = "ContainerProfiles", codecProfiles = "CodecProfiles", subtitleProfiles = "SubtitleProfiles"
    }
}

/** What the phone's decoders and screen can do; the app fills this in from VideoToolbox and the screen. */
struct DeviceCapabilities: Hashable {
    var hevc = true
    var av1 = false
    var dolbyVision = false
    /** HDR10 and HLG: every iPhone with HEVC plays them, tone-mapped when the screen is not HDR. */
    var hdr = true
    var maxAudioChannels = 8

    init(hevc: Bool = true, av1: Bool = false, dolbyVision: Bool = false, hdr: Bool = true, maxAudioChannels: Int = 8) {
        self.hevc = hevc
        self.av1 = av1
        self.dolbyVision = dolbyVision
        self.hdr = hdr
        self.maxAudioChannels = maxAudioChannels
    }
}

enum DeviceProfileBuilder {
    /** Text subtitles: the server hands them over as files, and Kinema draws them itself. */
    static let textSubtitleFormats = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "ttml", "mov_text", "tx3g", "smi", "sami", "microdvd", "sub", "text"]
    /** Picture subtitles: only the server can draw these, into the video. */
    static let imageSubtitleFormats = ["pgs", "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "sup", "xsub"]

    static let directPlayAudio = "aac,mp3,ac3,eac3,alac,flac"
    static let streamingAudio = "aac,ac3,eac3"

    /**
     * The profile for [capabilities], streaming at most [maxBitrate] bits a
     * second. With [allowDirectPlay] off, files are never played as they are,
     * which makes the server repackage or convert everything.
     */
    static func build(_ capabilities: DeviceCapabilities, maxBitrate: Int, allowDirectPlay: Bool = true) -> DeviceProfile {
        var videoCodecs = ["h264"]
        if capabilities.hevc { videoCodecs.append("hevc") }
        if capabilities.av1 { videoCodecs.append("av1") }

        let direct: [DirectPlayProfile] = allowDirectPlay ? [
            DirectPlayProfile(container: "mp4,m4v,mov", type: "Video", videoCodec: videoCodecs.joined(separator: ","), audioCodec: directPlayAudio),
        ] : []

        // HLS with fragmented MP4 segments. H.264 comes first, so a conversion
        // makes H.264 (which every server can encode quickly); HEVC is listed
        // so HEVC video can be copied as it is.
        let hlsVideo = capabilities.hevc ? "h264,hevc" : "h264"
        let channels = String(max(2, capabilities.maxAudioChannels))
        let transcoding = [
            TranscodingProfile(
                container: "mp4", type: "Video", videoCodec: hlsVideo, audioCodec: streamingAudio,
                protocol: "hls", context: "Streaming", maxAudioChannels: channels, minSegments: 1,
                breakOnNonKeyFrames: true, copyTimestamps: false, enableSubtitlesInManifest: false
            ),
            TranscodingProfile(
                container: "mp4", type: "Video", videoCodec: "h264", audioCodec: "aac",
                protocol: "http", context: "Static", maxAudioChannels: "2", minSegments: nil,
                breakOnNonKeyFrames: nil, copyTimestamps: nil, enableSubtitlesInManifest: nil
            ),
        ]

        var ranges = ["SDR"]
        if capabilities.hdr { ranges += ["HDR10", "HDR10Plus", "HLG"] }
        if capabilities.dolbyVision {
            ranges += ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR", "DOVIWithHDR10Plus"]
        } else if capabilities.hdr {
            // Without Dolby Vision the HDR10 / HLG base layer still plays.
            ranges += ["DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR", "DOVIWithHDR10Plus"]
        }

        var codecProfiles = [
            CodecProfile(type: "Video", codec: "h264", container: nil, conditions: [
                ProfileCondition("EqualsAny", "VideoProfile", "high|main|baseline|constrained baseline"),
                ProfileCondition("LessThanEqual", "VideoLevel", "52"),
                ProfileCondition("NotEquals", "IsInterlaced", "true"),
                ProfileCondition("EqualsAny", "VideoRangeType", "SDR"),
            ], applyConditions: nil),
        ]
        if capabilities.hevc {
            codecProfiles.append(CodecProfile(type: "Video", codec: "hevc", container: nil, conditions: [
                ProfileCondition("EqualsAny", "VideoProfile", "main|main 10"),
                ProfileCondition("LessThanEqual", "VideoLevel", "183"),
                ProfileCondition("NotEquals", "IsInterlaced", "true"),
                ProfileCondition("EqualsAny", "VideoRangeType", ranges.joined(separator: "|")),
            ], applyConditions: nil))
            // AVFoundation only shows HEVC in MP4 when it is tagged hvc1 (or
            // dvh1). That is not a condition here, because the server would then
            // refuse to copy untagged HEVC into HLS too (which it re-tags);
            // StreamResolver turns direct play off for such files instead.
        }
        if capabilities.av1 {
            codecProfiles.append(CodecProfile(type: "Video", codec: "av1", container: nil, conditions: [
                ProfileCondition("EqualsAny", "VideoRangeType", (["SDR"] + (capabilities.hdr ? ["HDR10", "HDR10Plus", "HLG"] : [])).joined(separator: "|")),
            ], applyConditions: nil))
        }
        codecProfiles.append(CodecProfile(type: "VideoAudio", codec: nil, container: nil, conditions: [
            ProfileCondition("LessThanEqual", "AudioChannels", channels),
        ], applyConditions: nil))

        let subtitles = textSubtitleFormats.map { SubtitleProfile(format: $0, method: "External") }
            + imageSubtitleFormats.map { SubtitleProfile(format: $0, method: "Encode") }

        return DeviceProfile(
            name: "Kinema",
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: max(maxBitrate, 200_000_000),
            musicStreamingTranscodingBitrate: 320_000,
            directPlayProfiles: direct,
            transcodingProfiles: transcoding,
            containerProfiles: [],
            codecProfiles: codecProfiles,
            subtitleProfiles: subtitles
        )
    }
}

/** The body of a PlaybackInfo request. */
struct PlaybackInfoRequest: Encodable {
    var userId: String
    var maxStreamingBitrate: Int
    var startTimeTicks: Int64
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var mediaSourceId: String?
    var deviceProfile: DeviceProfile
    var enableDirectPlay: Bool
    var enableDirectStream: Bool
    var enableTranscoding: Bool
    var allowVideoStreamCopy: Bool
    var allowAudioStreamCopy: Bool
    var autoOpenLiveStream: Bool
    var alwaysBurnInSubtitleWhenTranscoding: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "UserId", maxStreamingBitrate = "MaxStreamingBitrate", startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex", subtitleStreamIndex = "SubtitleStreamIndex", mediaSourceId = "MediaSourceId"
        case deviceProfile = "DeviceProfile", enableDirectPlay = "EnableDirectPlay", enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding", allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy", autoOpenLiveStream = "AutoOpenLiveStream"
        case alwaysBurnInSubtitleWhenTranscoding = "AlwaysBurnInSubtitleWhenTranscoding"
    }
}

/** How a video reaches the player, as Jellyfin counts it. */
enum PlayMethod: String, Codable, Hashable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

/** A playback report: started, still going, or stopped. */
struct PlaybackReport: Encodable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var positionTicks: Int64
    var isPaused: Bool
    var isMuted = false
    var playMethod: PlayMethod?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var canSeek = true
    var eventName: String?
    var failed: Bool?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId", mediaSourceId = "MediaSourceId", playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks", isPaused = "IsPaused", isMuted = "IsMuted", playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex", subtitleStreamIndex = "SubtitleStreamIndex"
        case canSeek = "CanSeek", eventName = "EventName", failed = "Failed"
    }
}

/** A change to what the user has done with an item, sent after watching offline. */
struct UserDataUpdate: Encodable {
    var playbackPositionTicks: Int64?
    var played: Bool?
    var isFavorite: Bool?
    var lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks", played = "Played", isFavorite = "IsFavorite", lastPlayedDate = "LastPlayedDate"
    }
}
