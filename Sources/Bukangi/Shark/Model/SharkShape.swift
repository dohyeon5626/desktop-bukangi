import simd

/// Unit-length dusky shark (Carcharhinus obscurus) in model space.
/// +x is the snout (x = 0.5), -x the tip of the caudal fin (x = -0.5),
/// +y is dorsal, z is lateral.
enum SharkShape {
    static let xSnout: Float = 0.5
    static let xEnd: Float = -0.30
    static var span: Float { xSnout - xEnd }

    static func x(_ t: Float) -> Float { xSnout - t * span }
    static func t(_ x: Float) -> Float { (xSnout - x) / span }

    static func profile(_ t: Float, frontExp: Float) -> Float {
        let tm: Float = 0.33
        if t <= 0 { return 0 }
        if t < tm { return pow(sin((t / tm) * .pi / 2), frontExp) }
        let s = min(1, (t - tm) / (1 - tm))
        let base = 0.5 + 0.5 * cos(.pi * s)
        return 0.10 + 0.90 * pow(base, 0.56)
    }

    static func hTop(_ t: Float) -> Float { 0.064 * profile(t, frontExp: 0.56) }
    static func hBot(_ t: Float) -> Float { 0.054 * profile(t, frontExp: 0.72) }
    /// Seen from above a dusky shark has a broad, bluntly rounded snout.
    static func halfWidth(_ t: Float) -> Float { 0.069 * profile(t, frontExp: 0.40) * (1 - 0.24 * t) }
    static func center(_ t: Float) -> Float { -0.004 + 0.012 * t }

    static func point(_ t: Float, _ th: Float) -> SIMD3<Float> {
        let ct = cos(th), st = sin(th)
        let p: Float = ct >= 0 ? 1.0 : 0.74   // flatter belly
        let yv = (ct >= 0 ? hTop(t) : hBot(t)) * copysign(pow(abs(ct), p), ct)
        let zv = halfWidth(t) * copysign(pow(abs(st), p), st)
        return SIMD3(x(t), center(t) + yv, zv)
    }

    static func normal(_ t: Float, _ th: Float) -> SIMD3<Float> {
        if t < 1e-4 { return SIMD3(1, 0, 0) }
        let e: Float = 1e-3
        let dt = point(min(t + e, 1), th) - point(max(t - e, 0), th)
        let dth = point(t, th + e) - point(t, th - e)
        var n = simd_normalize(simd_cross(dt, dth))
        let radial = point(t, th) - SIMD3(x(t), center(t), 0)
        if simd_dot(n, radial) < 0 { n = -n }
        return n
    }

    static func top(_ x: Float) -> Float { let tt = t(x); return center(tt) + hTop(tt) }
    static func bottom(_ x: Float) -> Float { let tt = t(x); return center(tt) - hBot(tt) }
    static func side(_ x: Float) -> Float { halfWidth(t(x)) }
}
