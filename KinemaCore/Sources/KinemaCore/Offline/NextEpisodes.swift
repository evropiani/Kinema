import Foundation

/** Which of a show's episodes to keep downloaded (Settings → Downloads → Keep the next episodes). */
enum NextEpisodes {
    /**
     * The next [count] episodes of a show, in order: the ones after the
     * last one watched that aren't watched yet. Specials and episodes the
     * server only knows about (with no file) are left out.
     */
    static func toKeep(_ episodes: [Item], count: Int, isPlayed: (Item) -> Bool) -> [Item] {
        guard count > 0 else { return [] }
        let real = episodes.filter { $0.locationType != "Virtual" && $0.parentIndexNumber != 0 }
        let start = real.lastIndex(where: isPlayed).map { $0 + 1 } ?? 0
        return Array(real[start...].filter { !isPlayed($0) }.prefix(count))
    }
}
