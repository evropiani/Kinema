import Foundation

/**
 * Following tracks across the server's renumbering. Jellyfin lists subtitle
 * files that sit next to the video first and numbers every track again when
 * one is added (a subtitle found online, say), so the file's own English
 * audio can go from 2 to 3. The file's own tracks keep their order, and the
 * separate files are told apart by what they are.
 */
enum StreamRemap {
    /** Where each track of [old] is in [new], by its number in each. */
    static func indexMap(from old: [MediaStream], to new: [MediaStream]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        let oldInside = old.filter { !$0.isExternal }.sorted { $0.index < $1.index }
        let newInside = new.filter { !$0.isExternal }.sorted { $0.index < $1.index }
        for type in Set(oldInside.map(\.type)) {
            for (a, b) in zip(oldInside.filter { $0.type == type }, newInside.filter { $0.type == type }) {
                map[a.index] = b.index
            }
        }
        var unmatched = new.filter(\.isExternal).sorted { $0.index < $1.index }
        for stream in old.filter(\.isExternal).sorted(by: { $0.index < $1.index }) {
            guard let i = unmatched.firstIndex(where: { candidate in
                candidate.type == stream.type
                    && Languages.normalize(candidate.language) == Languages.normalize(stream.language)
                    && candidate.codec?.lowercased() == stream.codec?.lowercased()
                    && (candidate.title ?? candidate.displayTitle) == (stream.title ?? stream.displayTitle)
            }) else { continue }
            map[stream.index] = unmatched.remove(at: i).index
        }
        return map
    }
}
