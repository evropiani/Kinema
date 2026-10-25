import Foundation

/**
 * BlurHash: a few dozen characters the server sends with each image that
 * describe a soft, blurred version of it. Kinema paints that while the real
 * image downloads, so posters fade in from their own colours instead of from
 * grey. (Algorithm by Wolt, https://blurha.sh.)
 */
enum BlurHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let lookup: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = i }
        return map
    }()

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for c in chars {
            guard let digit = lookup[c] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func srgbToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ value: Double) -> UInt8 {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, Int(s * 255 + 0.5))))
    }

    private static func signPow(_ value: Double, _ exponent: Double) -> Double {
        copysign(pow(abs(value), exponent), value)
    }

    /**
     * The picture as RGBA bytes, [width] × [height] (small sizes, 32 × 32 or
     * less, are plenty: it is scaled up and is blurry anyway).
     */
    static func decode(_ hash: String, width: Int, height: Int, punch: Double = 1) -> [UInt8]? {
        let chars = Array(hash)
        guard chars.count >= 6, width > 0, height > 0, let sizeFlag = decode83(chars[0...0]) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        guard chars.count == 4 + 2 * numX * numY, let quantisedMax = decode83(chars[1...1]) else { return nil }
        let maximum = Double(quantisedMax + 1) / 166

        var colors: [(Double, Double, Double)] = []
        colors.reserveCapacity(numX * numY)
        for i in 0..<(numX * numY) {
            if i == 0 {
                guard let value = decode83(chars[2..<6]) else { return nil }
                colors.append((srgbToLinear(value >> 16), srgbToLinear((value >> 8) & 255), srgbToLinear(value & 255)))
            } else {
                let start = 4 + i * 2
                guard let value = decode83(chars[start..<(start + 2)]) else { return nil }
                let r = Double(value / (19 * 19))
                let g = Double((value / 19) % 19)
                let b = Double(value % 19)
                colors.append((
                    signPow((r - 9) / 9, 2) * maximum * punch,
                    signPow((g - 9) / 9, 2) * maximum * punch,
                    signPow((b - 9) / 9, 2) * maximum * punch
                ))
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var cosX = [Double](repeating: 0, count: width * numX)
        var cosY = [Double](repeating: 0, count: height * numY)
        for x in 0..<width {
            for i in 0..<numX { cosX[x * numX + i] = cos(Double.pi * Double(x) * Double(i) / Double(width)) }
        }
        for y in 0..<height {
            for j in 0..<numY { cosY[y * numY + j] = cos(Double.pi * Double(y) * Double(j) / Double(height)) }
        }
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<numY {
                    let cy = cosY[y * numY + j]
                    for i in 0..<numX {
                        let basis = cosX[x * numX + i] * cy
                        let color = colors[i + j * numX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = linearToSrgb(r)
                pixels[offset + 1] = linearToSrgb(g)
                pixels[offset + 2] = linearToSrgb(b)
            }
        }
        return pixels
    }

    /** The image's average colour, as packed RGB, straight from the hash. */
    static func averageColor(_ hash: String) -> UInt32? {
        let chars = Array(hash)
        guard chars.count >= 6, let value = decode83(chars[2..<6]) else { return nil }
        return 0xFF00_0000 | UInt32(value & 0xFF_FFFF)
    }
}
