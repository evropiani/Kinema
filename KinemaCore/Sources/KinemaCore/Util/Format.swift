import Foundation

/** How numbers, times and media details read in the interface. */
enum Format {
    /** "2h 14m", "48m", "35s". */
    static func runtime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds))s" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func runtime(ticks: Int64?) -> String {
        runtime(Ticks.seconds(ticks))
    }

    /** "1:02:03" or "2:03", for the player. */
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /** "23m left", "1h 5m left". */
    static func remaining(_ seconds: Double) -> String {
        let text = runtime(seconds)
        return text.isEmpty ? "" : "\(text) left"
    }

    /** "1.2 GB", "640 MB". */
    static func fileSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        return value >= 100 ? String(format: "%.0f %@", value, units[unit]) : String(format: "%.1f %@", value, units[unit])
    }

    /** "12.4 Mbps", "640 kbps". */
    static func bitrate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "–" }
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        return String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    /** "4K", "1080p", "720p"… from the picture's size. */
    static func resolution(width: Int?, height: Int?) -> String? {
        let w = width ?? 0
        let h = height ?? 0
        guard w > 0 || h > 0 else { return nil }
        // Wide films are short for their width, so judge mostly by width.
        if w >= 3800 || h >= 2100 { return "4K" }
        if w >= 2500 || h >= 1400 { return "1440p" }
        if w >= 1800 || h >= 1000 { return "1080p" }
        if w >= 1200 || h >= 700 { return "720p" }
        if w >= 700 || h >= 560 { return "576p" }
        if h >= 470 || w >= 600 { return "480p" }
        return "SD"
    }

    /** "Dolby Vision", "HDR10+", "HDR10", "HLG", or nil for SDR. */
    static func dynamicRange(_ rangeType: String?) -> String? {
        guard let type = rangeType else { return nil }
        if type.hasPrefix("DOVI") && type != "DOVIInvalid" { return "Dolby Vision" }
        switch type {
        case "HDR10Plus": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        case "HDR": return "HDR"
        default: return nil
        }
    }

    /** "Dolby Atmos", "DTS:X", "TrueHD", "DTS-HD MA", "Dolby Digital+", "AAC"… */
    static func audioFormat(codec: String?, profile: String?, spatial: String?) -> String? {
        let c = (codec ?? "").lowercased()
        let p = (profile ?? "").lowercased()
        if spatial == "DolbyAtmos" || p.contains("atmos") { return c == "truehd" ? "TrueHD Atmos" : "Dolby Atmos" }
        if spatial == "DTSX" || p.contains("dts:x") { return "DTS:X" }
        switch c {
        case "": return nil
        case "truehd": return "TrueHD"
        case "dts", "dca":
            if p.contains("ma") { return "DTS-HD MA" }
            if p.contains("hra") || p.contains("hd") { return "DTS-HD" }
            return "DTS"
        case "eac3": return "Dolby Digital+"
        case "ac3": return "Dolby Digital"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_bluray", "pcm_dvd": return "PCM"
        default: return c.uppercased()
        }
    }

    /** "7.1", "5.1", "Stereo", "Mono". */
    static func channels(_ count: Int?, layout: String? = nil) -> String? {
        if let layout = layout?.lowercased() {
            if layout.hasPrefix("7.1") { return "7.1" }
            if layout.hasPrefix("5.1") { return "5.1" }
            if layout == "stereo" { return "Stereo" }
            if layout == "mono" { return "Mono" }
        }
        guard let count, count > 0 else { return nil }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) ch"
        }
    }

    /** "SRT", "ASS", "PGS"… */
    static func subtitleFormat(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt", "vtt": return "VTT"
        case "mov_text", "tx3g": return "Text"
        case "pgssub", "pgs", "hdmv_pgs_subtitle", "sup": return "PGS"
        case "dvdsub", "dvd_subtitle", "vobsub": return "VobSub"
        case "dvbsub", "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    /** The language's name, in the phone's language. */
    static func languageName(_ code: String?) -> String? {
        guard let normalized = Languages.normalize(code) else { return nil }
        let lookup = Languages.twoLetter(normalized) ?? normalized
        if let name = Locale.current.localizedString(forLanguageCode: lookup), name.lowercased() != lookup {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        if let english = Languages.common.first(where: { $0.0 == normalized })?.1 { return english }
        return normalized.uppercased()
    }

    /** "Good morning", "Good afternoon", "Good evening". */
    static func greeting(_ hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /** "3 episodes", "1 movie". */
    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: n)) ?? String(n)
        return "\(number) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }

    /** "★ 7.4". */
    static func rating(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%.1f", value)
    }

    /** Up to two initials, for a placeholder. */
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.joined()
    }

    /** "12 Mar 2024". */
    static func date(_ jellyfin: String?) -> String? {
        guard let text = jellyfin, let date = JellyfinDate.parse(text) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /** "just now", "5 min ago", "yesterday". */
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 172_800 { return "yesterday" }
        return "\(Int(seconds / 86_400)) days ago"
    }

    /** "Season 1 · Episode 3". */
    static func episodeLong(_ item: Item) -> String? {
        var parts: [String] = []
        if let season = item.parentIndexNumber { parts.append(season == 0 ? "Special" : "Season \(season)") }
        if let episode = item.indexNumber { parts.append("Episode \(episode)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
