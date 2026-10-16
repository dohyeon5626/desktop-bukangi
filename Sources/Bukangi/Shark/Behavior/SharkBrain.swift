import AppKit

/// Where the shark sits in the window stack.
enum SharkLayer: Equatable {
    case top
    case bottom
    case under(CGWindowID)
}

@inline(__always) func wrapAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}

@inline(__always) func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// Motion, behaviour and spine of Bukangi, seen from above.
final class SharkBrain {
    enum Kind { case cruise, deep, surface, hide, skim, circle, rest, flee, summon, curious }

    struct Plan {
        var kind: Kind
        var waypoints: [CGPoint] = []
        var speed: CGFloat = 100
        var timeLeft: Double = 30
        var stage = 0
        var stageTime: Double = 0
        var hold: Double = 0
        var window: CGWindowID?
        var rel = CGPoint(x: 0.5, y: 0.5)
        var edge = 0
        var along: CGFloat = 0.5
        var dir: CGFloat = 1
        var passes = 0
        var maxPasses = 1
        var center = CGPoint.zero
        var radius: CGFloat = 0
        var swept: Double = 0
        var lastAngle: Double = 0
        var from = CGPoint.zero
        var wander: Double = 1
    }

    // MARK: Configuration
    var length: CGFloat = 340

    // MARK: State
    private(set) var head = CGPoint(x: 600, y: 400)
    private(set) var heading: Double = 0
    private(set) var turnRate: Double = 0
    private(set) var speed: CGFloat = 50
    private(set) var tailPhase: Double = 0
    private(set) var tailAmp: Double = 0.05
    private(set) var roll: Double = 0
    private(set) var depth: Double = 1
    private(set) var layer: SharkLayer = .bottom
    private(set) var layerChangedAt: Double = -10
    private(set) var time: Double = 0
    var excitement: Double = 0
    private(set) var spine: [CGPoint] = []
    private(set) var spineAngles: [Double] = []
    var surfacedEvent = false
    var wiggle = 0.0
    /// Small surface ripples left behind while swimming at the top.
    var wakePoints: [CGPoint] = []
    var wakeTimer = 15.0
    var wakeBurst = 0
    /// When the Mac is busy she stays deep and lazy.
    var calm = false
    /// Mood: 0.9 = normal, ~0.6 = leisurely, ~0.35 = slow, ~0.2 = barely drifting.
    private(set) var energy = 0.9
    var energyTarget = 0.9
    var nextMoodChange = 25.0
    var coveredTime = 0.0
    /// 0...1: how surfaced (and so how cute) she looks.
    private(set) var cute = 0.0
    var mouseIdle = 0.0

    var screens: [CGRect] = []
    var windows: [TrackedWindow] = []

    var history: [CGPoint] = []
    var mouse = CGPoint(x: -1e5, y: -1e5)
    var mouseVel = CGVector.zero
    var hasMouse = false
    var plan = Plan(kind: .cruise)
    var depthTarget: Double = 1
    var wantedLayer: SharkLayer = .bottom
    var wantedDepth: Double = 1
    var pendingSince: Double = 0
    var startDepth: Double = 1
    var startLevel = 0
    var exitTarget: CGPoint?
    var desiredSpeed: CGFloat = 90
    var lastKind: Kind = .cruise
    let seedA = Double.random(in: 0...100)
    let seedB = Double.random(in: 0...100)

    var visualScale: CGFloat { 1 - 0.24 * CGFloat(depth) }
    /// Rendered body length in points.
    var L: CGFloat { length * visualScale }
    var center: CGPoint { spine.isEmpty ? head : spine[spine.count / 2] }

    var bodyBounds: CGRect {
        guard !spine.isEmpty else { return CGRect(origin: head, size: .zero) }
        var r = CGRect(origin: spine[0], size: .zero)
        for p in spine { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -L * 0.35, dy: -L * 0.35)
    }

    // MARK: Setup

    func reset() {
        guard let s = screens.first else { return }
        head = randomPoint() ?? CGPoint(x: s.midX, y: s.midY)
        heading = Double.random(in: -Double.pi...Double.pi)
        history = [CGPoint(x: head.x - cos(heading) * L * 1.2, y: head.y - sin(heading) * L * 1.2), head]
        depth = 1
        depthTarget = 1
        layer = .bottom
        wantedLayer = .bottom
        wantedDepth = 1
        exitTarget = nil
        speed = 60
        nextPlan(preferred: .deep)
        computeSpine()
    }

    func updateMouse(_ p: CGPoint, dt: Double) {
        if hasMouse && dt > 0 {
            let v = CGVector(dx: (p.x - mouse.x) / dt, dy: (p.y - mouse.y) / dt)
            mouseVel = CGVector(dx: mouseVel.dx * 0.6 + v.dx * 0.4, dy: mouseVel.dy * 0.6 + v.dy * 0.4)
        }
        if hypot(mouseVel.dx, mouseVel.dy) < 30 { mouseIdle += dt } else { mouseIdle = 0 }
        mouse = p
        hasMouse = true
    }

    /// Busy Mac: sink to the bottom and drift.
    func calmDown() {
        if plan.kind != .flee { nextPlan(preferred: .deep) }
    }

    func summon() {
        guard let s = screens.first else { return }
        var p = Plan(kind: .summon)
        p.waypoints = [CGPoint(x: s.midX + CGFloat.random(in: -100...100), y: s.midY + CGFloat.random(in: -60...60))]
        p.speed = 240
        p.timeLeft = 12
        p.wander = 0.3
        requestLayer(.top, depth: 0)
        plan = p
    }

    func setLayer(_ l: SharkLayer) {
        guard l != layer else { return }
        if l == .top { surfacedEvent = true; wiggle = 1.3 }
        layer = l
        layerChangedAt = time
    }

    // MARK: Step

    func step(_ dt: Double) {
        guard !screens.isEmpty else { return }
        time += dt
        if !screens.contains(where: { $0.insetBy(dx: -L * 2, dy: -L * 2).contains(head) }) { reset() }
        if case .under(let id) = layer, window(id) == nil { setLayer(.bottom); wantedLayer = .bottom; depthTarget = 1; wantedDepth = 1 }
        if case .under(let id) = wantedLayer, window(id) == nil { wantedLayer = .bottom; wantedDepth = 1 }

        reactToMouse()
        var target = head
        var spd: CGFloat = 80
        for _ in 0..<4 {
            if let r = planTarget(dt) { target = r.0; spd = r.1; break }
            nextPlan()
        }
        resolveLayer()
        if let e = exitTarget, plan.kind != .flee {
            target = e
            spd = max(spd, 75)
        }
        let paced = [.flee, .summon, .curious].contains(plan.kind) ? 1.0 : energy
        desiredSpeed = spd * CGFloat(paced)
        steer(toward: target, dt: dt)
        updateMood(dt)
        depth += (depthTarget - depth) * min(1, dt * 0.75)
        excitement = max(0, excitement - dt * 0.5)
        wiggle = max(0, wiggle - dt)
        computeSpine()
    }

    func updateMood(_ dt: Double) {
        nextMoodChange -= dt
        if nextMoodChange <= 0 {
            nextMoodChange = .random(in: 18...50)
            let r = Double.random(in: 0...1)
            energyTarget = r < 0.3 ? 0.9 : (r < 0.6 ? 0.6 : (r < 0.85 ? 0.35 : 0.2))
        }
        let goal = calm ? 0.35 : energyTarget
        energy += (goal - energy) * min(1, dt * 0.15)

        cute += ((layer == .top ? max(0, 1 - depth * 1.6) : 0) - cute) * min(1, dt * 1.5)

        // Don't stay invisible under windows for too long.
        if isCovered(center) && plan.kind != .hide && plan.kind != .skim && !calm {
            coveredTime += dt
            if coveredTime > 10 {
                coveredTime = 0
                nextPlan(preferred: Bool.random() ? .surface : .cruise)
                if case .under = layer, Bool.random() { requestLayer(.top, depth: 0) }
            }
        } else {
            coveredTime = 0
        }

        // Only now and then leave a short trail of surface rings.
        wakeTimer -= dt
        if wakeTimer <= 0 {
            if wakeBurst > 0 && layer == .top && depth < 0.25 && speed > 22 {
                if spine.count > 5 { wakePoints.append(spine[5]) }
                wakeBurst -= 1
                wakeTimer = max(0.4, Double(L) * 0.16 / Double(speed))
            } else {
                wakeBurst = Int.random(in: 2...4)
                wakeTimer = .random(in: 20...40)
            }
        }
    }

    // MARK: Mouse

    func reactToMouse() {
        guard hasMouse, !spine.isEmpty else { return }
        var best = CGFloat.greatestFiniteMagnitude
        var nearest = head
        for i in stride(from: 0, to: spine.count, by: 2) {
            let d = dist(spine[i], mouse)
            if d < best { best = d; nearest = spine[i] }
        }
        if isCovered(nearest) { return }
        let ms = hypot(mouseVel.dx, mouseVel.dy)
        let approaching = mouseVel.dx * (nearest.x - mouse.x) + mouseVel.dy * (nearest.y - mouse.y) > 0
        let close = best < L * 0.30
        let startle = (ms > 1100 && best < L * 0.95 && approaching) || (plan.kind == .curious && plan.stage > 0 && ms > 160)
        if close || startle {
            startFlee(dive: startle ? Double.random(in: 0...1) < 0.3 : Double.random(in: 0...1) < 0.15)
        }
    }

    func startFlee(dive: Bool) {
        excitement = 1
        if plan.kind == .flee {
            plan.from = mouse
            plan.timeLeft = max(plan.timeLeft, 1.0)
            return
        }
        var p = Plan(kind: .flee)
        p.from = mouse
        p.timeLeft = 1.5
        p.wander = 0.15
        if dive { requestLayer(.bottom, depth: 1) }
        tailAmp = max(tailAmp, 0.085)
        plan = p
    }

    // MARK: Steering

    func steer(toward target: CGPoint, dt: Double) {
        var dx = Double(target.x - head.x), dy = Double(target.y - head.y)
        let dl = max(hypot(dx, dy), 1e-3)
        dx /= dl; dy /= dl

        if hasMouse && !isCovered(center) {
            let c = center
            let mx = Double(c.x - mouse.x), my = Double(c.y - mouse.y)
            let md = hypot(mx, my), R = Double(L) * 0.85
            if md < R && md > 1 {
                let w = 2.6 * pow(1 - md / R, 2)
                dx += mx / md * w; dy += my / md * w
            }
        }
        if let r = screenFor(head) {
            let m = Double(L) * 0.30
            func push(_ d: CGFloat) -> Double { Double(d) < m ? 1.8 * (1 - max(Double(d), 0) / m) : 0 }
            dx += push(head.x - r.minX); dx -= push(r.maxX - head.x)
            dy += push(head.y - r.minY); dy -= push(r.maxY - head.y)
        }

        let wander = plan.wander * (0.30 * sin(time * 0.23 + seedA) + 0.18 * sin(time * 0.71 + seedB))
        let desired = atan2(dy, dx) + wander
        let diff = wrapAngle(desired - heading)

        let fleeing = plan.kind == .flee
        // Never turn tighter than the body can follow (radius ~half a body length).
        var maxTurn = 0.04 + Double(speed) / Double(L * 0.5)
        maxTurn = min(maxTurn, fleeing ? 2.6 : 1.5)
        let wantTurn = max(-maxTurn, min(maxTurn, diff * (fleeing ? 2.4 : 1.3)))
        turnRate += (wantTurn - turnRate) * min(1, dt * (fleeing ? 4 : 2.0))
        heading = wrapAngle(heading + turnRate * dt)

        // Swim slower through tight turns; breathe a little in cruise speed.
        let breathe = 1 + 0.12 * sin(time * 0.37 + seedA)
        let ts = desiredSpeed * CGFloat(1 - 0.35 * min(1, abs(diff) / .pi)) * CGFloat(fleeing ? 1 : breathe)
        speed += (ts - speed) * CGFloat(min(1, dt * (ts > speed ? (fleeing ? 4.0 : 1.2) : 0.6)))
        speed = max(speed, 16)
        head.x += CGFloat(cos(heading)) * speed * CGFloat(dt)
        head.y += CGFloat(sin(heading)) * speed * CGFloat(dt)

        let rollGoal = max(-0.42, min(0.42, -turnRate * Double(speed) / 300))
        roll += (rollGoal - roll) * min(1, dt * 2.2)

        // Tail: thrust when accelerating, glide when coasting.
        let thrust = max(0, Double(ts - speed)) / max(Double(ts), 1)
        var ampGoal = 0.046 + 0.018 * min(1, Double(speed) / 300) + 0.05 * min(1, thrust * 2.5)
            + 0.016 * min(1, abs(turnRate))
        if speed > ts + 18 { ampGoal *= 0.35 }
        let wig = min(1, wiggle)
        ampGoal += 0.035 * wig
        tailAmp += (ampGoal - tailAmp) * min(1, dt * 1.6)
        let freq = min(3.6, max(0.36, Double(speed) / (0.62 * Double(L))) + thrust * 0.6 + 1.6 * wig)
        tailPhase += 2 * .pi * freq * dt

        // Path history for follow-the-leader: commit a point every so often along the way.
        // (Measuring from the last committed point, not last frame's head, so slow swimming
        // still records its curve instead of one long straight chord.)
        if history.last.map({ dist($0, head) >= 1.0 }) ?? true {
            history.append(head)
        }
        if history.count > 64 {
            var acc: CGFloat = 0
            var cut = 0
            for i in stride(from: history.count - 1, to: 0, by: -1) {
                acc += dist(history[i], history[i - 1])
                if acc > L * 1.4 { cut = i - 1; break }
            }
            if cut > 0 { history.removeFirst(cut) }
        }
    }

    // MARK: Spine

    func computeSpine() {
        let n = SharkMesh.boneCount
        let Lp = Double(L)
        let seg = Lp / Double(n - 1)
        var base = [CGPoint](repeating: head, count: n)
        var tang = [Double](repeating: heading, count: n)
        // The live head is always the newest point of the path.
        let path = dist(history.last ?? head, head) > 0.01 ? history + [head] : history
        var idx = path.count - 1
        var acc = 0.0
        var segDir = heading
        for i in 1..<n {
            let target = Double(i) * seg
            while true {
                if idx <= 0 {
                    let p = path.first ?? head
                    let rem = target - acc
                    base[i] = CGPoint(x: p.x - CGFloat(cos(segDir) * rem), y: p.y - CGFloat(sin(segDir) * rem))
                    tang[i] = segDir
                    break
                }
                let a = path[idx], b = path[idx - 1]
                let d = Double(dist(a, b))
                if d > 1e-6 { segDir = atan2(Double(a.y - b.y), Double(a.x - b.x)) }
                if acc + d >= target {
                    let f = CGFloat((target - acc) / d)
                    base[i] = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                    tang[i] = segDir
                    break
                }
                acc += d
                idx -= 1
            }
        }

        // Travelling body wave, growing toward the tail.
        let k = 2 * Double.pi * 0.85
        var pts = [CGPoint](repeating: .zero, count: n)
        for i in 0..<n {
            let s = Double(i) / Double(n - 1)
            let env = 0.09 + 0.91 * pow(s, 2.1)
            let lat = Lp * tailAmp * env * sin(tailPhase - k * s)
            pts[i] = CGPoint(x: base[i].x - CGFloat(sin(tang[i]) * lat), y: base[i].y + CGFloat(cos(tang[i]) * lat))
        }
        // Rebuild the body from the head out with fixed segment lengths. Each joint's bend comes
        // from the target curve itself and eases toward a soft limit, so the body can't kink and
        // never snaps from one side to the other.
        let maxBend = 0.17
        var targetDir = [Double](repeating: heading, count: n)
        for i in 1..<n {
            targetDir[i] = atan2(Double(pts[i - 1].y - pts[i].y), Double(pts[i - 1].x - pts[i].x))
        }
        var dir = targetDir[1]
        for i in 1..<n {
            if i > 1 {
                let bend = wrapAngle(targetDir[i] - targetDir[i - 1])
                dir += maxBend * tanh(bend / maxBend)
            }
            pts[i] = CGPoint(x: pts[i - 1].x - CGFloat(cos(dir) * seg), y: pts[i - 1].y - CGFloat(sin(dir) * seg))
        }
        var angles = [Double](repeating: heading, count: n)
        for i in 0..<n {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, n - 1)]
            angles[i] = atan2(Double(a.y - b.y), Double(a.x - b.x))
        }
        spine = pts
        spineAngles = angles
    }
}
