import CoreGraphics
import Foundation
import SceneKit
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

struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
}

struct FinSpec {
    var origin: SIMD3<Float> = .zero
    var axisA = SIMD3<Float>(1, 0, 0)
    var axisB = SIMD3<Float>(0, 1, 0)
    var leRoot: SIMD2<Float>
    var leCtrl: SIMD2<Float>
    var tip: SIMD2<Float>
    var teRoot: SIMD2<Float>
    var teCtrl: SIMD2<Float>
    var thickness: Float
    var paired = false
}

enum SharkMesh {
    static let boneCount = 24
    static var boneSpacing: Float { 1.0 / Float(boneCount - 1) }
    static func boneX(_ i: Int) -> Float { 0.5 - Float(i) * boneSpacing }

    // MARK: Body

    static func body(rings: Int = 150, segments: Int = 72) -> MeshData {
        var m = MeshData()
        let cols = segments + 1
        for i in 0...rings {
            let s = Float(i) / Float(rings)
            let t = pow(s, 1.4)
            for j in 0...segments {
                let th = Float(j) / Float(segments) * 2 * .pi
                m.positions.append(SharkShape.point(t, th))
                m.normals.append(SharkShape.normal(t, th))
                m.uvs.append(SIMD2(t, Float(j) / Float(segments)))
            }
        }
        for i in 0..<rings {
            for j in 0..<segments {
                let a = UInt32(i * cols + j), b = a + 1, c = a + UInt32(cols), d = c + 1
                m.indices += [a, c, b, b, c, d]
            }
        }
        return m
    }

    // MARK: Fins

    private static func bez(_ a: SIMD2<Float>, _ c: SIMD2<Float>, _ b: SIMD2<Float>, _ s: Float) -> SIMD2<Float> {
        let u = 1 - s
        return u * u * a + 2 * u * s * c + s * s * b
    }

    static func fin(_ f: FinSpec, spans: Int = 30, chords: Int = 14) -> MeshData {
        var N = simd_normalize(simd_cross(f.axisA, f.axisB))
        if f.paired && N.y < 0 { N = -N }
        var m = MeshData()
        var expected: [SIMD3<Float>] = []
        for side in 0..<2 {
            let sgn: Float = side == 0 ? 1 : -1
            let base = UInt32(m.positions.count)
            for i in 0...spans {
                let s = Float(i) / Float(spans)
                let le = bez(f.leRoot, f.leCtrl, f.tip, s)
                let te = bez(f.teRoot, f.teCtrl, f.tip, s)
                for j in 0...chords {
                    let c = Float(j) / Float(chords)
                    let p2 = simd_mix(le, te, SIMD2(repeating: c))
                    let thick = f.thickness * (1 - 0.85 * s) * 2.6 * sqrt(c) * (1 - c)
                    m.positions.append(f.origin + p2.x * f.axisA + p2.y * f.axisB + sgn * thick * N)
                    m.normals.append(.zero)
                    m.uvs.append(SIMD2(Float(side) * 0.5 + c * 0.5, s))
                    expected.append(sgn * N)
                }
            }
            let cols = UInt32(chords + 1)
            for i in 0..<spans {
                for j in 0..<chords {
                    let a = base + UInt32(i) * cols + UInt32(j), b = a + 1, c = a + cols, d = c + 1
                    m.indices += [a, b, c, b, d, c]
                }
            }
        }
        for k in stride(from: 0, to: m.indices.count, by: 3) {
            let i0 = Int(m.indices[k]), i1 = Int(m.indices[k + 1]), i2 = Int(m.indices[k + 2])
            var fn = simd_cross(m.positions[i1] - m.positions[i0], m.positions[i2] - m.positions[i0])
            if simd_length_squared(fn) < 1e-14 { continue }
            if simd_dot(fn, expected[i0]) < 0 {
                fn = -fn
                m.indices.swapAt(k + 1, k + 2)
            }
            m.normals[i0] += fn; m.normals[i1] += fn; m.normals[i2] += fn
        }
        for i in m.normals.indices {
            let n = m.normals[i]
            m.normals[i] = simd_length_squared(n) > 1e-16 ? simd_normalize(n) : expected[i]
        }
        return m
    }

    static func finSpecs() -> (vertical: [FinSpec], paired: [FinSpec]) {
        let dorsalBase = SharkShape.top(0.19) - 0.014
        let dorsal = FinSpec(
            leRoot: SIMD2(0.20, dorsalBase), leCtrl: SIMD2(0.135, 0.125), tip: SIMD2(0.045, 0.160),
            teRoot: SIMD2(0.0, SharkShape.top(0.0) - 0.012), teCtrl: SIMD2(0.052, 0.085),
            thickness: 0.009)
        let dorsal2 = FinSpec(
            leRoot: SIMD2(-0.092, SharkShape.top(-0.092) - 0.006), leCtrl: SIMD2(-0.105, 0.046), tip: SIMD2(-0.138, 0.056),
            teRoot: SIMD2(-0.142, SharkShape.top(-0.142) - 0.005), teCtrl: SIMD2(-0.132, 0.04),
            thickness: 0.004)
        let anal = FinSpec(
            leRoot: SIMD2(-0.098, SharkShape.bottom(-0.098) + 0.006), leCtrl: SIMD2(-0.11, -0.034), tip: SIMD2(-0.142, -0.046),
            teRoot: SIMD2(-0.148, SharkShape.bottom(-0.148) + 0.005), teCtrl: SIMD2(-0.136, -0.028),
            thickness: 0.004)
        let caudalUpper = FinSpec(
            leRoot: SIMD2(-0.17, SharkShape.top(-0.17) - 0.004), leCtrl: SIMD2(-0.32, 0.075), tip: SIMD2(-0.50, 0.19),
            teRoot: SIMD2(-0.30, SharkShape.center(1) - 0.002), teCtrl: SIMD2(-0.385, 0.075),
            thickness: 0.0065)
        let caudalLower = FinSpec(
            leRoot: SIMD2(-0.17, SharkShape.bottom(-0.17) + 0.004), leCtrl: SIMD2(-0.245, -0.065), tip: SIMD2(-0.345, -0.105),
            teRoot: SIMD2(-0.29, SharkShape.center(1) - 0.004), teCtrl: SIMD2(-0.295, -0.05),
            thickness: 0.006)

        var paired: [FinSpec] = []
        for side: Float in [1, -1] {
            let px: Float = 0.27
            let pect = FinSpec(
                origin: SIMD3(0, SharkShape.center(SharkShape.t(px)) - 0.55 * SharkShape.hBot(SharkShape.t(px)),
                              side * 0.62 * SharkShape.side(px)),
                axisA: SIMD3(1, 0, 0),
                axisB: simd_normalize(SIMD3(0, -0.36, side * 0.93)),
                leRoot: SIMD2(0.305, -0.006), leCtrl: SIMD2(0.262, 0.118), tip: SIMD2(0.145, 0.188),
                teRoot: SIMD2(0.205, -0.006), teCtrl: SIMD2(0.200, 0.098),
                thickness: 0.0085, paired: true)
            let vx: Float = -0.03
            let pelvic = FinSpec(
                origin: SIMD3(0, SharkShape.bottom(vx) + 0.012, side * 0.4 * SharkShape.side(vx)),
                axisA: SIMD3(1, 0, 0),
                axisB: simd_normalize(SIMD3(0, -0.55, side * 0.83)),
                leRoot: SIMD2(0.0, -0.004), leCtrl: SIMD2(-0.012, 0.036), tip: SIMD2(-0.058, 0.052),
                teRoot: SIMD2(-0.052, -0.004), teCtrl: SIMD2(-0.046, 0.026),
                thickness: 0.004, paired: true)
            paired += [pect, pelvic]
        }
        return ([dorsal, dorsal2, anal, caudalUpper, caudalLower], paired)
    }

    /// Eye centres on the +z / -z sides, in model space.
    static func eyePositions() -> [SIMD3<Float>] {
        let t: Float = 0.085
        let th: Float = 0.29 * .pi
        let p = SharkShape.point(t, th)
        let n = SharkShape.normal(t, th)
        let c = p - n * 0.0058
        return [c, SIMD3(c.x, c.y, -c.z)]
    }
}

/// A single skinned mesh: body + all fins, grouped by material.
struct SkinnedShark {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var boneIndices: [SIMD4<UInt16>] = []
    var boneWeights: [SIMD4<Float>] = []
    var groups: [[UInt32]] = [[], [], []]   // 0 body, 1 vertical fins, 2 paired fins

    /// Cubic B-spline weights over four neighbouring bones: the skin bends as a smooth curve
    /// instead of kinking at each joint.
    static func boneBinding(forX x: Float) -> (SIMD4<UInt16>, SIMD4<Float>) {
        let n = SharkMesh.boneCount
        let b = min(max((0.5 - x) / SharkMesh.boneSpacing, 0), Float(n - 1))
        let i0 = min(Int(floor(b)), n - 2)
        let f = b - Float(i0)
        let f2 = f * f, f3 = f2 * f
        let w: [Float] = [(1 - f) * (1 - f) * (1 - f) / 6,
                          (3 * f3 - 6 * f2 + 4) / 6,
                          (-3 * f3 + 3 * f2 + 3 * f + 1) / 6,
                          f3 / 6]
        var acc = [Int: Float]()
        for k in 0..<4 {
            let bone = min(max(i0 - 1 + k, 0), n - 1)
            acc[bone, default: 0] += w[k]
        }
        let pairs = acc.sorted { $0.key < $1.key }
        var idx = SIMD4<UInt16>(0, 0, 0, 0), wt = SIMD4<Float>(0, 0, 0, 0)
        for (k, p) in pairs.prefix(4).enumerated() { idx[k] = UInt16(p.key); wt[k] = p.value }
        return (idx, wt)
    }

    mutating func append(_ m: MeshData, group: Int, rigidX: Float? = nil) {
        let base = UInt32(positions.count)
        positions += m.positions
        normals += m.normals
        uvs += m.uvs
        for p in m.positions {
            let (i, w) = Self.boneBinding(forX: rigidX ?? p.x)
            boneIndices.append(i)
            boneWeights.append(w)
        }
        groups[group] += m.indices.map { $0 + base }
    }

    static func build() -> SkinnedShark {
        var s = SkinnedShark()
        s.append(SharkMesh.body(), group: 0)
        let fins = SharkMesh.finSpecs()
        for f in fins.vertical { s.append(SharkMesh.fin(f), group: 1) }
        for f in fins.paired { s.append(SharkMesh.fin(f), group: 2, rigidX: f.leRoot.x - 0.03) }
        return s
    }

    func geometry() -> (SCNGeometry, SCNGeometrySource, SCNGeometrySource) {
        let v = SCNGeometrySource(vertices: positions.map { SCNVector3($0) })
        let n = SCNGeometrySource(normals: normals.map { SCNVector3($0) })
        let t = SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        let elements = groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let g = SCNGeometry(sources: [v, n, t], elements: elements)

        let wData = boneWeights.withUnsafeBufferPointer { Data(buffer: $0) }
        let iData = boneIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let w = SCNGeometrySource(data: wData, semantic: .boneWeights, vectorCount: boneWeights.count,
                                  usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                  dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let i = SCNGeometrySource(data: iData, semantic: .boneIndices, vectorCount: boneIndices.count,
                                  usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2,
                                  dataOffset: 0, dataStride: MemoryLayout<SIMD4<UInt16>>.stride)
        return (g, w, i)
    }
}
