import CoreGraphics
import Foundation
import simd

enum SharkTextures {
    static let dorsal = SIMD3<Float>(0.33, 0.36, 0.46)
    static let belly = SIMD3<Float>(0.92, 0.92, 0.90)

    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    /// Value noise, periodic in y with the given period.
    static func noise(_ x: Float, _ y: Float, periodY: Int32) -> Float {
        let xi = floor(x), yi = floor(y)
        let fx = x - xi, fy = y - yi
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let x0 = Int32(xi), y0 = ((Int32(yi) % periodY) + periodY) % periodY
        let y1 = (y0 + 1) % periodY
        let a = hash(x0, y0), b = hash(x0 + 1, y0), c = hash(x0, y1), d = hash(x0 + 1, y1)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    static func image(width: Int, height: Int, _ f: (Float, Float) -> SIMD3<Float>) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for j in 0..<height {
            let v = (Float(j) + 0.5) / Float(height)
            for i in 0..<width {
                let u = (Float(i) + 0.5) / Float(width)
                let c = simd_clamp(f(u, v), SIMD3(repeating: 0), SIMD3(repeating: 1))
                let k = (j * width + i) * 4
                data[k] = UInt8(c.x * 255)
                data[k + 1] = UInt8(c.y * 255)
                data[k + 2] = UInt8(c.z * 255)
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func body() -> CGImage {
        let gills: [Float] = [0.355, 0.342, 0.329, 0.316, 0.302].map { SharkShape.t($0) }
        return image(width: 2048, height: 1024) { u, v in
            let th = v * 2 * .pi
            let a = th <= .pi ? th : 2 * .pi - th          // 0 = dorsal midline, π = belly
            let nearSide = th < .pi

            // Countershading boundary, lifted along the flank band.
            var b: Float = 0.60 + 0.012 * sin(u * 40) + 0.008 * sin(u * 97 + 1.3)
            b -= 0.075 * exp(-pow((u - 0.66) / 0.11, 2))
            b += 0.05 * smooth(0.12, 0.0, u)
            let bb = b * .pi
            let n1 = noise(u * 60, v * 24, periodY: 24)
            let n2 = noise(u * 220, v * 90, periodY: 90)
            let n3 = noise(u * 9, v * 6, periodY: 6)
            let wmix = smooth(bb - 0.13, bb + 0.13, a + (n1 - 0.5) * 0.05)

            var col = dorsal * (0.84 + 0.20 * min(a / bb, 1))
            let n4 = noise(u * 26, v * 12, periodY: 12)
            // Soft, plush colouring: only very gentle, large-scale variation.
            let mottle: Float = 1 + (n3 - 0.5) * 0.06 + (n4 - 0.5) * 0.02
            col *= mottle
            col *= 1 - 0.05 * exp(-pow((a - bb + 0.08) / 0.08, 2))
            // Slightly darker along the dorsal ridge and the snout.
            col *= 1 - 0.10 * exp(-pow(a / 0.35, 2))
            col = simd_mix(col, belly * (0.97 + (n2 - 0.5) * 0.04), SIMD3(repeating: wmix))

            // Gill slits.
            if u > 0.16 && u < 0.28 {
                for g in gills {
                    let curve = g + 0.004 * sin((a - 0.5 * .pi) * 2.2)
                    let span = smooth(0.34 * .pi, 0.40 * .pi, a) * smooth(0.68 * .pi, 0.61 * .pi, a)
                    let d = (u - curve) / 0.0016
                    col *= 1 - 0.20 * exp(-d * d) * span
                    let h = (u - curve - 0.0034) / 0.0016
                    col *= 1 + 0.04 * exp(-h * h) * span
                }
            }
            // Mouth line under the snout.
            if u > 0.06 && u < 0.16 {
                let q = (u - 0.065) / 0.085
                let am = Float.pi * (0.98 - 0.30 * pow(max(q, 0), 0.85))
                let d = (a - am) / 0.014
                col *= 1 - 0.45 * exp(-d * d) * smooth(0.06, 0.075, u) * smooth(0.16, 0.14, u)
            }
            // Nostrils.
            let nd = pow((u - 0.032) / 0.006, 2) + pow((a - 0.80 * .pi) / 0.05, 2)
            col *= 1 - 0.35 * exp(-nd)
            // Bukangi's snout wound (reported by NIFS) on the near side.
            if nearSide && u > 0.02 && u < 0.08 {
                let fade = smooth(0.02, 0.03, u) * smooth(0.08, 0.065, u)
                for k in 0..<2 {
                    let as_ = Float.pi * (0.20 + Float(k) * 0.035) + (u - 0.02) * 1.6
                    let d = (a - as_) / 0.012
                    col = simd_mix(col, SIMD3(0.80, 0.70, 0.68), SIMD3(repeating: 0.22 * exp(-d * d) * fade))
                }
            }
            return col
        }
    }

    static func fin(lightUnderside: Bool) -> CGImage {
        image(width: 512, height: 256) { u, v in
            let side = u < 0.5 ? 0 : 1
            let c = (u < 0.5 ? u : u - 0.5) * 2
            let s = v
            let n = noise(u * 40, v * 20, periodY: 20)
            var col = dorsal * 0.95
            if lightUnderside && side == 1 {
                col = simd_mix(belly * 0.95, dorsal, SIMD3(repeating: smooth(0.9, 0.2, c) * 0.2))
            }
            col *= 1 + 0.07 * (1 - c)
            col *= 1 - 0.22 * smooth(0.6, 1.0, s)        // softly dusky fin tips
            col *= 1 + (n - 0.5) * 0.02
            return col
        }
    }
}
