import Foundation

/** A video ready for the player: where it comes from and how. */
struct ResolvedStream: Hashable {
    var url: URL
    var method: PlayMethod
    var source: MediaSource
    var playSessionId: String?
    /** Why the server repackages or converts it (from its transcoding URL). */
    var transcodeReasons: [String] = []

    var isHLS: Bool { url.path.lowercased().hasSuffix(".m3u8") }

    /** Repackaged only: the streams are copied as they are, nothing is re-encoded. */
    var isRemux: Bool {
        method != .directPlay && !transcodeReasons.isEmpty && transcodeReasons.allSatisfy { StreamResolver.containerReasons.contains($0) }
    }

    /** "Direct Play", "Remux" or "Transcode", as the stats panel shows it. */
    var methodLabel: String {
        switch method {
        case .directPlay: return "Direct Play"
        case .directStream: return "Direct Stream"
        case .transcode: return isRemux ? "Remux" : "Transcode"
        }
    }
}

enum StreamResolver {
    /** Reasons that only change the packaging, not the picture or sound. */
    static let containerReasons: Set<String> = ["ContainerNotSupported", "ContainerBitrateExceedsLimit", "DirectPlayError"]

    /**
     * Whether AVFoundation can show this file's video as it is. HEVC in MP4
     * must carry the hvc1 (or dvh1) tag; files tagged hev1 play sound only,
     * so those go through the server, which re-tags them.
     */
    static func directPlayIsSafe(_ source: MediaSource) -> Bool {
        guard let video = source.videoStream else { return true }
        let codec = (video.codec ?? "").lowercased()
        if codec == "hevc" || codec == "h265" {
            let tag = (video.codecTag ?? "").lowercased()
            return tag == "hvc1" || tag == "dvh1"
        }
        return true
    }

    /** Whether a downloaded copy of the original file would play on the phone. */
    static func offlinePlayable(_ source: MediaSource) -> Bool {
        let containers = Set((source.container ?? "").lowercased().split(separator: ",").map(String.init))
        guard !containers.isDisjoint(with: ["mp4", "m4v", "mov"]) else { return false }
        guard directPlayIsSafe(source) else { return false }
        let videoOK: Set<String> = ["h264", "hevc", "h265", "av1"]
        let audioOK: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "flac"]
        if let video = source.videoStream, !videoOK.contains((video.codec ?? "").lowercased()) { return false }
        let audio = source.audioStreams
        return audio.isEmpty || audio.contains { audioOK.contains(($0.codec ?? "").lowercased()) }
    }

    /** The TranscodeReasons in a transcoding URL ("ContainerNotSupported,AudioCodecNotSupported"). */
    static func transcodeReasons(_ url: String?) -> [String] {
        guard let url, let query = url.split(separator: "?", maxSplits: 1).last else { return [] }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "transcodereasons" else { continue }
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            return value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        }
        return []
    }

    /** "Audio codec not supported", for the stats panel. */
    static func describe(reason: String) -> String {
        var words = ""
        for character in reason {
            if character.isUppercase && !words.isEmpty { words += " " }
            words.append(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst().lowercased()
    }

    /**
     * Turn the server's answer into something to play: the source chosen
     * ([sourceId], or the first), played directly when the server allows it,
     * otherwise through the server's transcoding URL.
     */
    static func resolve(_ response: PlaybackInfoResponse, itemId: String, sourceId: String?, client: JellyfinClient) -> ResolvedStream? {
        guard let source = response.mediaSources.first(where: { $0.id == sourceId }) ?? response.mediaSources.first else { return nil }
        if source.supportsDirectPlay, directPlayIsSafe(source), let url = directURL(source, itemId: itemId, client: client) {
            return ResolvedStream(url: url, method: .directPlay, source: source, playSessionId: response.playSessionId)
        }
        if let transcoding = source.transcodingUrl, let url = client.absolute(transcoding) {
            return ResolvedStream(
                url: url,
                method: .transcode,
                source: source,
                playSessionId: response.playSessionId,
                transcodeReasons: transcodeReasons(transcoding)
            )
        }
        return nil
    }

    private static func directURL(_ source: MediaSource, itemId: String, client: JellyfinClient) -> URL? {
        // A source that is itself a web address (a .strm file) plays from there.
        if source.protocol == "Http", let path = source.path, path.hasPrefix("http"), let url = URL(string: path) {
            return url
        }
        return client.directStreamURL(itemId: itemId, source: source)
    }

    // ---------------------------------------------------------------- tracks --

    /** The audio track to start with: one in [language] if there is one, otherwise the default. */
    static func audioIndex(_ source: MediaSource, language: String?) -> Int? {
        let audio = source.audioStreams
        guard !audio.isEmpty else { return nil }
        if let language, !language.isEmpty {
            let matching = audio.filter { Languages.same($0.language, language) }
            if let pick = matching.first(where: \.isDefault) ?? matching.first { return pick.index }
        }
        if let index = source.defaultAudioStreamIndex, audio.contains(where: { $0.index == index }) { return index }
        return (audio.first(where: \.isDefault) ?? audio.first)?.index
    }

    /**
     * The subtitle track to start with, under [mode]. [language] is the
     * preferred subtitle language; [audioLanguage] the language being heard.
     */
    static func subtitleIndex(
        _ source: MediaSource,
        mode: SubtitleMode,
        language: String?,
        audioLanguage: String?,
        prefer: SubtitleSource = .any,
        embedded: Bool = true
    ) -> Int? {
        var subtitles = source.subtitleStreams
        // Embedded tracks may be left out, and one kind tried before the other.
        if !embedded { subtitles = subtitles.filter(\.isExternal) }
        switch prefer {
        case .any: break
        case .embedded: subtitles = subtitles.filter { !$0.isExternal } + subtitles.filter(\.isExternal)
        case .external: subtitles = subtitles.filter(\.isExternal) + subtitles.filter { !$0.isExternal }
        }
        guard !subtitles.isEmpty else { return nil }
        let wanted = (language?.isEmpty == false) ? language : nil
        func inLanguage(_ code: String?) -> [MediaStream] {
            guard let code else { return [] }
            return subtitles.filter { Languages.same($0.language, code) }
        }
        func forced() -> MediaStream? {
            let pool = inLanguage(audioLanguage) + inLanguage(wanted)
            return pool.first(where: \.isForced) ?? (wanted == nil && audioLanguage == nil ? subtitles.first(where: \.isForced) : nil)
        }
        switch mode {
        case .none:
            return nil
        case .onlyForced:
            return forced()?.index
        case .always:
            let pool = inLanguage(wanted)
            if let pick = pool.first(where: { !$0.isForced }) ?? pool.first { return pick.index }
            if wanted != nil { return nil }
            return (subtitles.first(where: { $0.isDefault && !$0.isForced }) ?? subtitles.first(where: { !$0.isForced }) ?? subtitles.first)?.index
        case .smart:
            if let wanted, let audioLanguage, !Languages.same(wanted, audioLanguage) {
                let pool = inLanguage(wanted)
                if let pick = pool.first(where: { !$0.isForced }) ?? pool.first { return pick.index }
            }
            return forced()?.index
        case .serverDefault:
            if let index = source.defaultSubtitleStreamIndex, index >= 0, subtitles.contains(where: { $0.index == index }) { return index }
            return nil
        }
    }
}

/** ISO 639 language codes, which come in two- and three-letter forms (and two three-letter ones for some). */
enum Languages {
    private static let twoToThree: [String: String] = [
        "en": "eng", "de": "deu", "fr": "fra", "es": "spa", "it": "ita", "pt": "por", "nl": "nld", "sv": "swe",
        "no": "nor", "nb": "nob", "nn": "nno", "da": "dan", "fi": "fin", "is": "isl", "pl": "pol", "cs": "ces", "sk": "slk",
        "sl": "slv", "hr": "hrv", "sr": "srp", "bs": "bos", "mk": "mkd", "bg": "bul", "ro": "ron", "hu": "hun",
        "el": "ell", "tr": "tur", "ru": "rus", "uk": "ukr", "be": "bel", "et": "est", "lv": "lav", "lt": "lit",
        "sq": "sqi", "hy": "hye", "ka": "kat", "he": "heb", "ar": "ara", "fa": "fas", "ur": "urd", "hi": "hin",
        "bn": "ben", "ta": "tam", "te": "tel", "ml": "mal", "kn": "kan", "mr": "mar", "th": "tha", "vi": "vie",
        "id": "ind", "ms": "msa", "tl": "tgl", "zh": "zho", "ja": "jpn", "ko": "kor", "ca": "cat", "eu": "eus",
        "gl": "glg", "cy": "cym", "ga": "gle", "af": "afr", "sw": "swa", "my": "mya", "km": "khm", "mn": "mon",
        "ne": "nep", "si": "sin", "lo": "lao", "bo": "bod", "mi": "mri", "lb": "ltz", "mt": "mlt", "kk": "kaz", "uz": "uzb",
    ]

    /** The bibliographic three-letter codes some files use, as their terminology twins. */
    private static let bibliographic: [String: String] = [
        "ger": "deu", "fre": "fra", "dut": "nld", "cze": "ces", "slo": "slk", "rum": "ron", "gre": "ell",
        "alb": "sqi", "arm": "hye", "geo": "kat", "per": "fas", "chi": "zho", "bur": "mya", "baq": "eus",
        "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa", "tib": "bod", "wel": "cym", "scc": "srp", "scr": "hrv",
        "fil": "tgl", "nob": "nor", "nno": "nor", "pob": "por", "spl": "spa",
    ]

    /** The terminology three-letter code for [code], lower-cased; nil for none or "und". */
    static func normalize(_ code: String?) -> String? {
        guard var value = code?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        // "en-US", "pt_BR": the language part is enough.
        if let cut = value.firstIndex(where: { $0 == "-" || $0 == "_" }) { value = String(value[..<cut]) }
        if value == "und" || value == "unk" || value == "mul" || value == "zxx" || value == "mis" { return nil }
        if value.count == 2 { return twoToThree[value] ?? value }
        return bibliographic[value] ?? value
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let x = normalize(a), let y = normalize(b) else { return false }
        return x == y
    }

    /** The two-letter code, for asking the system for a name. */
    static func twoLetter(_ code: String?) -> String? {
        guard let three = normalize(code) else { return nil }
        if three.count == 2 { return three }
        return twoToThree.first { $0.value == three }?.key
    }

    /** Languages to offer in pickers: (three-letter code, English name). */
    static let common: [(String, String)] = [
        ("eng", "English"), ("deu", "German"), ("fra", "French"), ("spa", "Spanish"), ("ita", "Italian"),
        ("por", "Portuguese"), ("nld", "Dutch"), ("swe", "Swedish"), ("nor", "Norwegian"), ("dan", "Danish"),
        ("fin", "Finnish"), ("pol", "Polish"), ("ces", "Czech"), ("slk", "Slovak"), ("slv", "Slovenian"),
        ("hrv", "Croatian"), ("srp", "Serbian"), ("bos", "Bosnian"), ("hun", "Hungarian"), ("ron", "Romanian"),
        ("bul", "Bulgarian"), ("ell", "Greek"), ("tur", "Turkish"), ("rus", "Russian"), ("ukr", "Ukrainian"),
        ("sqi", "Albanian"), ("heb", "Hebrew"), ("ara", "Arabic"), ("fas", "Persian"), ("hin", "Hindi"),
        ("tha", "Thai"), ("vie", "Vietnamese"), ("ind", "Indonesian"), ("msa", "Malay"), ("zho", "Chinese"),
        ("jpn", "Japanese"), ("kor", "Korean"),
    ]
}
