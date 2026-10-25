import Foundation

/** A run of subtitle text with its emphasis. */
struct SubtitleRun: Hashable {
    var text: String
    var italic = false
    var bold = false
}

/** One subtitle on screen from [start] to [end] seconds. */
struct SubtitleCue: Hashable {
    var start: Double
    var end: Double
    var runs: [SubtitleRun]
    /** Asked to sit at the top of the picture ({\an8} and friends, or VTT's line:0). */
    var top = false

    var text: String { runs.map(\.text).joined() }
}

/**
 * A whole subtitle track, read once and searched by time while the video
 * plays. Reads SubRip (SRT), WebVTT and SubStation Alpha (ASS/SSA); styling
 * beyond italics, bold and top placement is left to Kinema's own style.
 */
struct SubtitleTrack: Hashable {
    let cues: [SubtitleCue]
    /** For each cue, the latest end of it and every cue before it, so overlaps are found quickly. */
    private let reach: [Double]

    init(cues: [SubtitleCue]) {
        let sorted = cues.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        self.cues = sorted
        var reach: [Double] = []
        reach.reserveCapacity(sorted.count)
        var latest = -Double.infinity
        for cue in sorted {
            latest = max(latest, cue.end)
            reach.append(latest)
        }
        self.reach = reach
    }

    static let empty = SubtitleTrack(cues: [])

    /** The cues showing at [time] seconds, in the order they began. */
    func cues(at time: Double) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        // The last cue starting at or before [time]…
        var low = 0
        var high = cues.count - 1
        var last = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                last = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard last >= 0 else { return [] }
        // …and walk back while earlier cues could still be on screen.
        var result: [SubtitleCue] = []
        var i = last
        while i >= 0 && reach[i] > time {
            if cues[i].end > time { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /** The start of the next cue after [time], for jumping between lines. */
    func nextStart(after time: Double) -> Double? {
        cues.first { $0.start > time + 0.05 }?.start
    }

    static func parse(_ data: Data) -> SubtitleTrack {
        parse(SubtitleParser.decodeText(data))
    }

    static func parse(_ text: String) -> SubtitleTrack {
        SubtitleTrack(cues: SubtitleParser.parse(text))
    }
}

enum SubtitleParser {
    /** Subtitle files come in all encodings; UTF-8 first, then the likely others. */
    static func decodeText(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if let text = String(data: bytes, encoding: .windowsCP1252) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let head = text.prefix(2000)
        if head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") { return parseVTT(text) }
        if head.contains("[Script Info]") || head.contains("[Events]") || text.contains("\nDialogue:") { return parseASS(text) }
        return parseSRT(text)
    }

    // -------------------------------------------------------------- times --

    /** "01:02:03,456", "01:02:03.456", "02:03.456", "0:01:02.34". */
    static func time(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        var seconds = 0.0
        for (i, part) in parts.enumerated() {
            guard let number = Double(part) else { return nil }
            seconds += number * pow(60, Double(parts.count - 1 - i))
        }
        return seconds
    }

    private static func timing(_ line: String) -> (Double, Double, String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = String(line[..<arrow.lowerBound])
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endText = right.split(separator: " ", maxSplits: 1).first.map(String.init) ?? right
        let settings = right.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        guard let start = time(left), let end = time(endText) else { return nil }
        return (start, end, settings)
    }

    // ---------------------------------------------------------------- SRT --

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard let (start, end, _) = timing(lines[i]) else {
                i += 1
                continue
            }
            i += 1
            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                // A missing blank line before the next cue: stop at its timing line.
                if timing(lines[i]) != nil { break }
                if i + 1 < lines.count, timing(lines[i + 1]) != nil, Int(lines[i].trimmingCharacters(in: .whitespaces)) != nil { break }
                body.append(lines[i])
                i += 1
            }
            let (runs, top) = markup(body.joined(separator: "\n"))
            cues.append(SubtitleCue(start: start, end: end, runs: runs, top: top))
        }
        return cues
    }

    // ---------------------------------------------------------------- VTT --

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end, settings) = timing(lines[timingIndex])
            else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            var (runs, top) = markup(body)
            if settings.contains("line:0") || settings.contains("line:1") || settings.contains("line:10%") { top = true }
            cues.append(SubtitleCue(start: start, end: end, runs: runs, top: top))
        }
        return cues
    }

    // ---------------------------------------------------------------- ASS --

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        var format: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                format = trimmed.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard trimmed.hasPrefix("Dialogue:") else { continue }
            let fields = trimmed.dropFirst(9).split(separator: ",", maxSplits: max(0, format.count - 1), omittingEmptySubsequences: false)
                .map { String($0) }
            guard fields.count == format.count,
                  let startIndex = format.firstIndex(of: "start"),
                  let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text"),
                  let start = time(fields[startIndex]),
                  let end = time(fields[endIndex])
            else { continue }
            var body = fields[textIndex]
            // Drawings (\p1 … \p0) are shapes, not words.
            if body.contains("\\p1") || body.contains("\\p2") || body.contains("\\p4") { continue }
            body = body.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            let (runs, top) = markup(body)
            cues.append(SubtitleCue(start: start, end: end, runs: runs, top: top))
        }
        return cues
    }

    // ------------------------------------------------------------- markup --

    /**
     * Read the emphasis in a cue's text: HTML-ish tags (<i>, <b>, <font>, VTT's
     * <c> and <v>) and ASS overrides ({\i1}, {\b1}, {\an8}). Everything else
     * is dropped.
     */
    static func markup(_ text: String) -> ([SubtitleRun], Bool) {
        var runs: [SubtitleRun] = []
        var italic = false
        var bold = false
        var top = false
        var current = ""
        let chars = Array(text)
        var i = 0

        func flush() {
            if !current.isEmpty { runs.append(SubtitleRun(text: current, italic: italic, bold: bold)) }
            current = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let tag = String(chars[(i + 1)..<close]).lowercased().trimmingCharacters(in: .whitespaces)
                let name = tag.split(separator: " ").first.map(String.init) ?? tag
                switch name {
                case "i": flush(); italic = true
                case "/i": flush(); italic = false
                case "b": flush(); bold = true
                case "/b": flush(); bold = false
                case "br", "br/": current += "\n"
                default: break
                }
                i = close + 1
                continue
            }
            if c == "{", let close = chars[i...].firstIndex(of: "}") {
                let block = String(chars[(i + 1)..<close])
                if block.hasPrefix("\\") {
                    for override in block.split(separator: "\\") {
                        switch override {
                        case "i1": flush(); italic = true
                        case "i0", "i": flush(); italic = false
                        case "b1": flush(); bold = true
                        case "b0": flush(); bold = false
                        case "an7", "an8", "an9": top = true
                        default:
                            if override.hasPrefix("a") && ["5", "6", "7"].contains(override.dropFirst().description) { top = true }
                        }
                    }
                }
                i = close + 1
                continue
            }
            current.append(c)
            i += 1
        }
        flush()
        // Tidy the edges and entity escapes.
        let cleaned = runs.map { run -> SubtitleRun in
            var copy = run
            copy.text = run.text.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            return copy
        }
        return (trim(cleaned), top)
    }

    private static func trim(_ runs: [SubtitleRun]) -> [SubtitleRun] {
        var result = runs.filter { !$0.text.isEmpty }
        while let first = result.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.removeFirst() }
        while let last = result.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.removeLast() }
        if !result.isEmpty {
            result[0].text = String(result[0].text.drop { $0 == " " || $0 == "\n" })
            let lastIndex = result.count - 1
            while let end = result[lastIndex].text.last, end == " " || end == "\n" { result[lastIndex].text.removeLast() }
        }
        return result
    }
}
