import Foundation

/**
 * The colour the interface takes from the artwork on screen.
 *
 * Works on packed ARGB pixels from a small downscaled copy of the artwork:
 * bucket colours coarsely and pick the most common one that is neither
 * near-black, near-white nor fully desaturated, then lift it into a range
 * that reads as an accent.
 */
enum ArtworkColor {
    private struct Bucket {
        var count = 0
        var r = 0
        var g = 0
        var b = 0
    }

    static func dominant(_ pixels: [UInt32]) -> UInt32? {
        var counts: [Int: Bucket] = [:]
        for argb in pixels {
            let alpha = Int(argb >> 24 & 0xff)
            if alpha < 200 { continue }
            let r = Int(argb >> 16 & 0xff)
            let g = Int(argb >> 8 & 0xff)
            let b = Int(argb & 0xff)
            let hi = max(r, max(g, b))
            let lo = min(r, min(g, b))
            let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            if luma < 28 || luma > 235 { continue }
            let saturation = hi == 0 ? 0.0 : Double(hi - lo) / Double(hi)
            if saturation < 0.12 { continue }
            let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            var bucket = counts[key] ?? Bucket()
            bucket.count += 1
            bucket.r += r
            bucket.g += g
            bucket.b += b
            counts[key] = bucket
        }
        // Most common bucket; ties go to the lower key so the result is stable.
        guard let best = counts.max(by: { lhs, rhs in
            lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : lhs.key > rhs.key
        })?.value else { return nil }
        let n = best.count
        return lift(best.r / n, best.g / n, best.b / n)
    }

    /** Nudge a sampled colour into a range that still reads as an accent. */
    static func lift(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        var scale = 1.0
        if luma < 90 { scale = 90 / max(luma, 1.0) }
        if luma > 200 { scale = 200 / luma }
        return rgb(
            min(255, Int((Double(r) * scale).rounded())),
            min(255, Int((Double(g) * scale).rounded())),
            min(255, Int((Double(b) * scale).rounded()))
        )
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xff00_0000 | UInt32(r & 0xff) << 16 | UInt32(g & 0xff) << 8 | UInt32(b & 0xff)
    }

    /** "#7c8cff" → ARGB, or nil. */
    static func parseHex(_ hex: String) -> UInt32? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy({ $0.isHexDigit }), let value = UInt32(text, radix: 16) else { return nil }
        return 0xff00_0000 | value
    }

    static func toHex(_ argb: UInt32) -> String {
        String(format: "#%06x", argb & 0xff_ffff)
    }

    /** Mix [b] into [a] by [amount] (0..1). */
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(1, max(0, amount))
        func channel(_ shift: UInt32) -> Int {
            let x = Double((a >> shift) & 0xff)
            let y = Double((b >> shift) & 0xff)
            return Int((x * (1 - t) + y * t).rounded())
        }
        return rgb(channel(16), channel(8), channel(0))
    }

    /** Relative luminance (0..1) of an ARGB colour, as Compose computes it. */
    static func luminance(_ argb: UInt32) -> Double {
        func linear(_ component: UInt32) -> Double {
            let c = Double(component & 0xff) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(argb >> 16) + 0.7152 * linear(argb >> 8) + 0.0722 * linear(argb)
    }
}
