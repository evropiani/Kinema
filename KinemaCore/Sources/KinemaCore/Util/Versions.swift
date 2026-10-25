import Foundation

/**
 * Release versions like "1.4.0" or a tag like "v1.4.0", compared number by
 * number ("1.10.0" is newer than "1.9.2"). Anything after a dash ("1.5.0-beta")
 * makes it come just before the plain version.
 */
enum Versions {
    private struct Parsed {
        let numbers: [Int]
        let preRelease: Bool
    }

    private static func parse(_ version: String) -> Parsed? {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let plain = core.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        var numbers: [Int] = []
        for part in plain.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        return Parsed(numbers: numbers, preRelease: text.contains("-"))
    }

    /** Negative if [a] is older than [b], positive if newer, 0 if the same (or either is not a version). */
    static func compare(_ a: String, _ b: String) -> Int {
        guard let x = parse(a), let y = parse(b) else { return 0 }
        for i in 0..<max(x.numbers.count, y.numbers.count) {
            let difference = (i < x.numbers.count ? x.numbers[i] : 0) - (i < y.numbers.count ? y.numbers[i] : 0)
            if difference != 0 { return difference }
        }
        if x.preRelease == y.preRelease { return 0 }
        return x.preRelease ? -1 : 1
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool { compare(candidate, current) > 0 }

    /** "v1.4.0" → "1.4.0". */
    static func fromTag(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }
}
