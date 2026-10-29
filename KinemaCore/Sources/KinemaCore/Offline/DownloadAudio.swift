import Foundation

/**
 * The audio language of a download. A copy the server makes (from an MKV,
 * or at a lower quality) can hold only one audio track, so it's chosen
 * before downloading.
 */
enum DownloadAudio {
    /** The languages heard in [items] (normalized codes), most common first. */
    static func languages(_ items: [Item]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in items {
            let codes = Set((item.primarySource?.audioStreams ?? []).compactMap { Languages.normalize($0.language) })
            for code in codes {
                if counts[code] == nil { order.append(code) }
                counts[code, default: 0] += 1
            }
        }
        return order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
    }

    /**
     * The language to look for: the one asked for with the download, else
     * the one set for watching, else the server account's.
     */
    static func wanted(_ asked: String?, watching: String, server: String?) -> String? {
        [asked, watching, server].compactMap { $0 }.first { !$0.isEmpty }
    }
}
