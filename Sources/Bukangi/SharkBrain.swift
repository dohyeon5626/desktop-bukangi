import AppKit

struct TrackedWindow {
    let id: CGWindowID
    /// Cocoa global coordinates (origin bottom-left of the primary screen).
    let frame: CGRect
}

/// Where the shark sits in the window stack.
enum SharkLayer: Equatable {
    case top
    case bottom
    case under(CGWindowID)
}

@inline(__always) private func wrapAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}

@inline(__always) private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

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
    private(set) var excitement: Double = 0
    private(set) var spine: [CGPoint] = []
    private(set) var spineAngles: [Double] = []
    var surfacedEvent = false
    private var wiggle = 0.0
    /// Small surface ripples left behind while swimming at the top.
    var wakePoints: [CGPoint] = []
    private var wakeTimer = 15.0
    private var wakeBurst = 0
    /// When the Mac is busy she stays deep and lazy.
    var calm = false
    /// Mood: 1 = normal, ~0.6 = leisurely, ~0.3 = barely gliding.
    private(set) var energy = 1.0
    private var energyTarget = 1.0
    private var nextMoodChange = 25.0
    private var coveredTime = 0.0
    /// 0...1: how surfaced (and so how cute) she looks.
    private(set) var cute = 0.0
    private var mouseIdle = 0.0

    var screens: [CGRect] = []
    var windows: [TrackedWindow] = []

    private var history: [CGPoint] = []
    private var mouse = CGPoint(x: -1e5, y: -1e5)
    private var mouseVel = CGVector.zero
    private var hasMouse = false
    private var plan = Plan(kind: .cruise)
    private var depthTarget: Double = 1
    private var wantedLayer: SharkLayer = .bottom
    private var wantedDepth: Double = 1
    private var pendingSince: Double = 0
    private var startDepth: Double = 1
    private var startLevel = 0
    private var exitTarget: CGPoint?
    private var desiredSpeed: CGFloat = 90
    private var lastKind: Kind = .cruise
    private let seedA = Double.random(in: 0...100)
    private let seedB = Double.random(in: 0...100)

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

    // MARK: Window stack

    var frontWindows: ArraySlice<TrackedWindow> {
        switch layer {
        case .top: return []
        case .bottom: return windows[...]
        case .under(let id):
            if let i = windows.firstIndex(where: { $0.id == id }) { return windows[...i] }
            return windows[...]
        }
    }

    func isCovered(_ p: CGPoint) -> Bool {
        frontWindows.contains { $0.frame.contains(p) }
    }

    private func window(_ id: CGWindowID?) -> TrackedWindow? {
        guard let id else { return nil }
        return windows.first { $0.id == id }
    }

    /// Ask to move to another layer. The change only happens once her body is clear of every
    /// window whose stacking relation to her would flip, so she never ghosts through a window:
    /// she swims out from under (or off) it first, then rises or dives.
    /// Ask to move to another layer. Windows are treated like terrain: she only changes her
    /// relation to a window while she isn't overlapping it, one window at a time, so she
    /// slips under (or glides over) each window right at its edge as she swims past.
    private func requestLayer(_ l: SharkLayer, depth d: Double) {
        if l != wantedLayer || abs(d - wantedDepth) > 0.01 {
            pendingSince = time
            startDepth = depthTarget
            startLevel = level(of: layer)
        }
        wantedLayer = l
        wantedDepth = d
        resolveLayer()
    }

    /// 0 = above every window, n = below every window, i = just below windows[i - 1].
    private func level(of l: SharkLayer) -> Int {
        switch l {
        case .top: return 0
        case .bottom: return windows.count
        case .under(let id): return (windows.firstIndex { $0.id == id }).map { $0 + 1 } ?? windows.count
        }
    }

    private func layer(atLevel k: Int) -> SharkLayer {
        if k <= 0 { return .top }
        if k >= windows.count { return .bottom }
        return .under(windows[k - 1].id)
    }

    private func front(_ l: SharkLayer) -> ArraySlice<TrackedWindow> {
        switch l {
        case .top: return []
        case .bottom: return windows[...]
        case .under(let id):
            if let i = windows.firstIndex(where: { $0.id == id }) { return windows[...i] }
            return windows[...]
        }
    }

    private func resolveLayer() {
        let goal = level(of: wantedLayer)
        var current = level(of: layer)
        let margin = L * 0.2
        func overlaps(_ w: TrackedWindow) -> Bool {
            let f = w.frame.insetBy(dx: -margin, dy: -margin)
            return spine.contains { f.contains($0) }
        }
        // Step through the stack one window at a time while she is clear of that window.
        var blocker: TrackedWindow?
        while current != goal {
            let next = current + (goal > current ? 1 : -1)
            let w = windows[min(current, next)]
            if overlaps(w) { blocker = w; break }
            current = next
            setLayer(layer(atLevel: current))
        }
        if current == goal { setLayer(wantedLayer) }

        // Depth (blur, size, tint) follows how far through the stack she has got.
        let total = max(1, abs(goal - startLevel))
        let done = Double(total - abs(goal - current)) / Double(total)
        depthTarget = current == goal ? wantedDepth : startDepth + (wantedDepth - startDepth) * done

        guard let b = blocker, time - pendingSince > 12 else {
            exitTarget = nil
            return
        }
        // Stuck for a long while: swim out past the nearest edge of that window.
        let f = b.frame
        let out = L * 0.75
        let c = CGPoint(x: min(max(head.x, f.minX), f.maxX), y: min(max(head.y, f.minY), f.maxY))
        let candidates = [
            CGPoint(x: f.minX - out, y: c.y), CGPoint(x: f.maxX + out, y: c.y),
            CGPoint(x: c.x, y: f.minY - out), CGPoint(x: c.x, y: f.maxY + out),
        ].filter { covers($0) }
        if let e = exitTarget, candidates.contains(where: { dist($0, e) < L * 0.4 }) { return }
        exitTarget = candidates.min { dist($0, head) < dist($1, head) }
    }

    private func setLayer(_ l: SharkLayer) {
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

    private func updateMood(_ dt: Double) {
        nextMoodChange -= dt
        if nextMoodChange <= 0 {
            nextMoodChange = .random(in: 18...50)
            let r = Double.random(in: 0...1)
            energyTarget = r < 0.4 ? 1.0 : (r < 0.75 ? 0.6 : 0.32)
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

    private func reactToMouse() {
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

    private func startFlee(dive: Bool) {
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

    private func steer(toward target: CGPoint, dt: Double) {
        var dx = Double(target.x - head.x), dy = Double(target.y - head.y)
        let dl = max(hypot(dx, dy), 1e-3)
        dx /= dl; dy /= dl

        // Keep away from the cursor.
        if hasMouse && !isCovered(center) {
            let c = center
            let mx = Double(c.x - mouse.x), my = Double(c.y - mouse.y)
            let md = hypot(mx, my), R = Double(L) * 0.85
            if md < R && md > 1 {
                let w = 2.6 * pow(1 - md / R, 2)
                dx += mx / md * w; dy += my / md * w
            }
        }
        // Soft screen walls.
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
        var maxTurn = 0.3 + Double(speed) / Double(L * 0.34)
        maxTurn = min(maxTurn, fleeing ? 2.6 : 1.5)
        let wantTurn = max(-maxTurn, min(maxTurn, diff * (fleeing ? 2.4 : 1.3)))
        turnRate += (wantTurn - turnRate) * min(1, dt * (fleeing ? 4 : 2.0))
        heading = wrapAngle(heading + turnRate * dt)

        // Swim slower through tight turns; breathe a little in cruise speed.
        let breathe = 1 + 0.12 * sin(time * 0.37 + seedA)
        let ts = desiredSpeed * CGFloat(1 - 0.35 * min(1, abs(diff) / .pi)) * CGFloat(fleeing ? 1 : breathe)
        speed += (ts - speed) * CGFloat(min(1, dt * (ts > speed ? (fleeing ? 4.0 : 1.2) : 0.6)))
        speed = max(speed, 10)
        head.x += CGFloat(cos(heading)) * speed * CGFloat(dt)
        head.y += CGFloat(sin(heading)) * speed * CGFloat(dt)

        // Bank into turns.
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

        // Path history for follow-the-leader.
        if let last = history.last, dist(last, head) < 0.75 {
            history[history.count - 1] = head
        } else {
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

    private func computeSpine() {
        let n = SharkMesh.boneCount
        let Lp = Double(L)
        let seg = Lp / Double(n - 1)
        var base = [CGPoint](repeating: head, count: n)
        var tang = [Double](repeating: heading, count: n)
        var idx = history.count - 1
        var acc = 0.0
        var segDir = heading
        for i in 1..<n {
            let target = Double(i) * seg
            while true {
                if idx <= 0 {
                    let p = history.first ?? head
                    let rem = target - acc
                    base[i] = CGPoint(x: p.x - CGFloat(cos(segDir) * rem), y: p.y - CGFloat(sin(segDir) * rem))
                    tang[i] = segDir
                    break
                }
                let a = history[idx], b = history[idx - 1]
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
        // Keep segment lengths constant and never let one joint bend sharply.
        let maxBend = 0.16
        var prevDir = atan2(Double(pts[0].y - pts[1].y), Double(pts[0].x - pts[1].x))
        for i in 1..<n {
            var dir = atan2(Double(pts[i - 1].y - pts[i].y), Double(pts[i - 1].x - pts[i].x))
            if i > 1 {
                let bend = wrapAngle(dir - prevDir)
                dir = prevDir + max(-maxBend, min(maxBend, bend))
            }
            prevDir = dir
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

    // MARK: Plans

    private func planTarget(_ dt: Double) -> (CGPoint, CGFloat)? {
        plan.timeLeft -= dt
        plan.stageTime += dt
        switch plan.kind {
        case .curious: return curiousTarget()
        case .cruise, .deep, .surface, .rest, .summon:
            if plan.timeLeft <= 0 { return nil }
            guard !plan.waypoints.isEmpty else { return nil }
            let arrive = L * (plan.kind == .rest ? 0.2 : 0.4)
            if dist(plan.waypoints[0], head) < arrive {
                plan.waypoints.removeFirst()
                if plan.waypoints.isEmpty { return nil }
            }
            return (plan.waypoints[0], plan.speed)

        case .circle:
            let a = atan2(Double(head.y - plan.center.y), Double(head.x - plan.center.x))
            plan.swept += wrapAngle(a - plan.lastAngle)
            plan.lastAngle = a
            if abs(plan.swept) > Double(plan.maxPasses) * 2 * .pi || plan.timeLeft <= 0 { return nil }
            let lead = a + Double(plan.dir) * 0.65
            return (CGPoint(x: plan.center.x + plan.radius * CGFloat(cos(lead)),
                            y: plan.center.y + plan.radius * CGFloat(sin(lead))), plan.speed)

        case .flee:
            if plan.timeLeft <= 0 { return nil }
            let c = center
            var ax = c.x - plan.from.x, ay = c.y - plan.from.y
            let d = max(hypot(ax, ay), 1)
            ax /= d; ay /= d
            var t = CGPoint(x: head.x + ax * L * 1.6, y: head.y + ay * L * 1.6)
            if let r = screenFor(head) {
                let inner = r.insetBy(dx: L * 0.35, dy: L * 0.35)
                t.x = min(max(t.x, inner.minX), inner.maxX)
                t.y = min(max(t.y, inner.minY), inner.maxY)
            }
            let f = CGFloat(max(0, plan.timeLeft) / 1.5)
            return (t, 150 + 420 * f)

        case .hide: return hideTarget()
        case .skim: return skimTarget()
        }
    }

    private func hideTarget() -> (CGPoint, CGFloat)? {
        guard let w = window(plan.window)?.frame else { return nil }
        let inner = w.insetBy(dx: min(L * 0.3, w.width * 0.3), dy: min(L * 0.25, w.height * 0.3))
        func relPoint(_ r: CGPoint) -> CGPoint { CGPoint(x: inner.minX + inner.width * r.x, y: inner.minY + inner.height * r.y) }
        let normals = [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1)]
        func edgePoint() -> CGPoint {
            switch plan.edge {
            case 0: return CGPoint(x: w.maxX, y: w.minY + w.height * plan.along)
            case 1: return CGPoint(x: w.minX, y: w.minY + w.height * plan.along)
            case 2: return CGPoint(x: w.minX + w.width * plan.along, y: w.maxY)
            default: return CGPoint(x: w.minX + w.width * plan.along, y: w.minY)
            }
        }
        let n = normals[plan.edge]
        switch plan.stage {
        case 0:
            if inner.contains(center) { plan.stage = 1; plan.stageTime = 0 }
            if plan.timeLeft <= 0 { return nil }
            return (CGPoint(x: w.midX, y: w.midY), plan.speed)
        case 1:
            plan.wander = 0.6
            if dist(relPoint(plan.rel), head) < L * 0.3 {
                plan.rel = CGPoint(x: .random(in: 0...1), y: .random(in: 0...1))
            }
            if plan.stageTime > plan.hold {
                guard let e = peekEdge(for: w) else { return nil }
                plan.edge = e
                plan.along = .random(in: 0.25...0.75)
                plan.stage = 2
                plan.stageTime = 0
            }
            return (relPoint(plan.rel), 58)
        case 2:
            plan.wander = 0.2
            let ep = edgePoint()
            let p = CGPoint(x: ep.x - n.dx * L * 0.85, y: ep.y - n.dy * L * 0.85)
            if dist(p, head) < L * 0.3 || plan.stageTime > 8 { plan.stage = 3; plan.stageTime = 0 }
            return (p, 62)
        case 3:
            plan.wander = 0.05
            let ep = edgePoint()
            let out = (head.x - ep.x) * n.dx + (head.y - ep.y) * n.dy
            if out > L * 0.10 {
                plan.stage = 4; plan.stageTime = 0; plan.hold = .random(in: 0.9...1.8)
            } else if plan.stageTime > 7 {
                plan.stage = 5; plan.stageTime = 0
            }
            return (CGPoint(x: ep.x + n.dx * L * 0.7, y: ep.y + n.dy * L * 0.7), 40)
        case 4:
            let ep = edgePoint()
            if plan.stageTime > plan.hold { plan.stage = 5; plan.stageTime = 0; excitement = 0.7 }
            return (CGPoint(x: ep.x + n.dx * L * 0.7, y: ep.y + n.dy * L * 0.7), 12)
        default:
            plan.wander = 0.3
            let t = CGPoint(x: w.midX - n.dx * w.width * 0.15, y: w.midY - n.dy * w.height * 0.15)
            if dist(t, head) < L * 0.35 || plan.stageTime > 2.6 {
                if Double.random(in: 0...1) < 0.35 {
                    plan.stage = 1; plan.stageTime = 0; plan.hold = .random(in: 2...4)
                } else {
                    return nil
                }
            }
            return (t, 210)
        }
    }

    /// Comes up, sidles toward the resting cursor and peers at it; any movement sends her off.
    private func curiousTarget() -> (CGPoint, CGFloat)? {
        if plan.timeLeft <= 0 || !covers(mouse) { return nil }
        let c = center
        var ax = c.x - mouse.x, ay = c.y - mouse.y
        let d = max(hypot(ax, ay), 1)
        ax /= d; ay /= d
        switch plan.stage {
        case 0:
            // Approach to a spot beside the cursor.
            let spot = CGPoint(x: mouse.x + ax * L * 0.75, y: mouse.y + ay * L * 0.75)
            if dist(spot, head) < L * 0.3 || plan.stageTime > 9 {
                plan.stage = 1; plan.stageTime = 0; plan.hold = .random(in: 2.5...5)
            }
            return (spot, 85)
        default:
            // Nose toward the cursor, inching closer.
            if plan.stageTime > plan.hold { return nil }
            wiggle = max(wiggle, 0.25)
            return (mouse, 16)
        }
    }

    private func skimTarget() -> (CGPoint, CGFloat)? {
        guard let w = window(plan.window)?.frame else { return nil }
        // Segment along the chosen edge, the shark's midline right on the edge.
        let a: CGPoint, b: CGPoint, n: CGVector
        let inset = L * 0.5
        switch plan.edge {
        case 0: a = CGPoint(x: w.maxX, y: w.minY + inset); b = CGPoint(x: w.maxX, y: w.maxY - inset); n = CGVector(dx: 1, dy: 0)
        case 1: a = CGPoint(x: w.minX, y: w.minY + inset); b = CGPoint(x: w.minX, y: w.maxY - inset); n = CGVector(dx: -1, dy: 0)
        case 2: a = CGPoint(x: w.minX + inset, y: w.maxY); b = CGPoint(x: w.maxX - inset, y: w.maxY); n = CGVector(dx: 0, dy: 1)
        default: a = CGPoint(x: w.minX + inset, y: w.minY); b = CGPoint(x: w.maxX - inset, y: w.minY); n = CGVector(dx: 0, dy: -1)
        }
        let len = dist(a, b)
        guard len > L * 0.8 else { return nil }
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let (s, e) = plan.dir > 0 ? (a, b) : (b, a)
        let off = L * 0.02
        switch plan.stage {
        case 0:
            let p = CGPoint(x: s.x - n.dx * L * 0.55 - ux * plan.dir * L * 0.3, y: s.y - n.dy * L * 0.55 - uy * plan.dir * L * 0.3)
            if dist(p, head) < L * 0.35 || plan.stageTime > 10 { plan.stage = 1; plan.stageTime = 0 }
            if plan.timeLeft <= 0 { return nil }
            return (p, 95)
        case 1:
            plan.wander = 0.04
            let proj = (head.x - a.x) * ux + (head.y - a.y) * uy
            let progress = plan.dir > 0 ? proj : len - proj
            if progress > len - L * 0.1 || plan.stageTime > 30 {
                plan.passes += 1
                plan.stageTime = 0
                if plan.passes < plan.maxPasses { plan.dir = -plan.dir } else { plan.stage = 2 }
            }
            let ahead = min(max(proj + plan.dir * L, 0), len)
            _ = e
            return (CGPoint(x: a.x + ux * ahead + n.dx * off, y: a.y + uy * ahead + n.dy * off), 72)
        default:
            plan.wander = 0.4
            if plan.stageTime > 2.4 { return nil }
            return (CGPoint(x: w.midX, y: w.midY), 110)
        }
    }

    private func peekEdge(for w: CGRect) -> Int? {
        var options: [Int] = []
        let room = L * 0.45
        if covers(CGPoint(x: w.maxX + room, y: w.midY)) { options.append(0) }
        if covers(CGPoint(x: w.minX - room, y: w.midY)) { options.append(1) }
        if covers(CGPoint(x: w.midX, y: w.maxY + room)) && w.maxY + room < (screenFor(CGPoint(x: w.midX, y: w.maxY))?.maxY ?? 0) - 30 { options.append(2) }
        if covers(CGPoint(x: w.midX, y: w.minY - room)) { options.append(3) }
        return options.randomElement()
    }

    private func covers(_ p: CGPoint) -> Bool { screens.contains { $0.contains(p) } }

    private func screenFor(_ p: CGPoint) -> CGRect? {
        if let s = screens.first(where: { $0.contains(p) }) { return s }
        return screens.min { a, b in
            dist(p, CGPoint(x: a.midX, y: a.midY)) < dist(p, CGPoint(x: b.midX, y: b.midY))
        }
    }

    private func randomPoint(insetFactor: CGFloat = 0.45, awayFrom: CGPoint? = nil) -> CGPoint? {
        guard !screens.isEmpty else { return nil }
        let total = screens.reduce(0) { $0 + $1.width * $1.height }
        var best: CGPoint?
        for _ in 0..<8 {
            var pick = CGFloat.random(in: 0..<total)
            var scr = screens[0]
            for s in screens {
                pick -= s.width * s.height
                if pick <= 0 { scr = s; break }
            }
            let r = scr.insetBy(dx: min(L * insetFactor, scr.width * 0.4), dy: min(L * insetFactor * 0.8, scr.height * 0.4))
            let p = CGPoint(x: .random(in: r.minX...r.maxX), y: .random(in: r.minY...r.maxY))
            best = p
            if let a = awayFrom, dist(a, p) < L * 1.3 { continue }
            break
        }
        return best
    }

    private var hideCandidates: [TrackedWindow] {
        windows.filter { $0.frame.width > L * 1.15 && $0.frame.height > L * 0.5 && covers(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    private func skimOptions() -> [(TrackedWindow, Int)] {
        var out: [(TrackedWindow, Int)] = []
        for (i, w) in windows.enumerated() {
            let f = w.frame
            let front = windows[..<i]
            func clear(_ p: CGPoint) -> Bool { covers(p) && !front.contains { $0.frame.contains(p) } }
            let o = L * 0.12
            if f.width > L * 2.0 {
                if clear(CGPoint(x: f.midX, y: f.maxY + o)) && clear(CGPoint(x: f.minX + L, y: f.maxY + o)) { out.append((w, 2)) }
                if clear(CGPoint(x: f.midX, y: f.minY - o)) && clear(CGPoint(x: f.minX + L, y: f.minY - o)) { out.append((w, 3)) }
            }
            if f.height > L * 2.0 {
                if clear(CGPoint(x: f.maxX + o, y: f.midY)) { out.append((w, 0)) }
                if clear(CGPoint(x: f.minX - o, y: f.midY)) { out.append((w, 1)) }
            }
        }
        return out
    }

    private func nextPlan(preferred: Kind? = nil) {
        var options: [(Kind, Double)] = [(.cruise, 16), (.deep, 14), (.surface, 14), (.circle, 12), (.rest, 6 + 22 * (1 - energy))]
        let hides = hideCandidates
        let skims = skimOptions()
        if !hides.isEmpty { options.append((.hide, 16)) }
        if !skims.isEmpty { options.append((.skim, 13)) }
        options = options.map { $0.0 == lastKind ? ($0.0, $0.1 * 0.2) : $0 }
        // With windows around, swim over them most of the time (70%) and hide under them less (30%).
        let goAbove = windows.isEmpty ? Bool.random() : Double.random(in: 0...1) < 0.7
        if !windows.isEmpty {
            let above: Set<Kind> = [.surface, .cruise, .circle, .rest]
            let below: Set<Kind> = [.deep, .hide, .skim, .cruise, .circle]
            options = options.filter { (goAbove ? above : below).contains($0.0) }
        }
        if calm { options = [(.deep, 1), (.rest, 2)] }
        if !calm && mouseIdle > 2.0 && covers(mouse) && lastKind != .curious && Double.random(in: 0...1) < 0.45 {
            options = [(.curious, 1)]
        }
        var kind = preferred ?? .cruise
        if let f = ProcessInfo.processInfo.environment["BK_FORCE"] {
            let alt: Kind = lastKind == .surface ? .deep : .surface
            let map: [String: Kind] = ["alt": alt, "deep": .deep, "surface": .surface, "hide": .hide, "skim": .skim, "circle": .circle, "rest": .rest, "curious": .curious]
            if let k = map[f], preferred == nil || preferred == .deep { options = [(k, 1)]; kind = k }
        }
        if preferred == nil {
            var pick = Double.random(in: 0..<options.reduce(0) { $0 + $1.1 })
            for o in options {
                pick -= o.1
                if pick <= 0 { kind = o.0; break }
            }
        }
        lastKind = kind

        var p = Plan(kind: kind)
        func waypoints(_ n: Int) -> [CGPoint] {
            var out: [CGPoint] = []
            var from = head
            for _ in 0..<n {
                if let q = randomPoint(awayFrom: from) { out.append(q); from = q }
            }
            return out
        }
        switch kind {
        case .cruise:
            p.waypoints = waypoints(.random(in: 2...4))
            p.speed = .random(in: 85...120)
            if goAbove {
                requestLayer(.top, depth: 0.1)
            } else if let w = windows.filter({ $0.frame.width > L * 0.8 }).randomElement(), Bool.random() {
                requestLayer(.under(w.id), depth: 0.45)
            } else {
                requestLayer(.bottom, depth: 0.85)
            }
        case .deep:
            p.waypoints = waypoints(.random(in: 2...3))
            p.speed = .random(in: 60...85)
            requestLayer(.bottom, depth: 1)
        case .surface:
            p.waypoints = waypoints(.random(in: 2...3))
            p.speed = .random(in: 95...135)
            requestLayer(.top, depth: 0)
        case .circle:
            p.center = randomPoint(insetFactor: 1.3) ?? head
            p.radius = L * .random(in: 0.65...1.1)
            p.dir = Bool.random() ? 1 : -1
            p.maxPasses = Int.random(in: 1...3)
            p.speed = .random(in: 80...110)
            p.timeLeft = 60
            p.lastAngle = atan2(Double(head.y - p.center.y), Double(head.x - p.center.x))
            if goAbove {
                requestLayer(.top, depth: 0)
            } else if let w = windows.randomElement(), Bool.random() {
                requestLayer(.under(w.id), depth: 0.5)
            } else {
                requestLayer(.bottom, depth: 1)
            }
        case .rest:
            if calm { requestLayer(.bottom, depth: 1) } else if goAbove && !windows.isEmpty { requestLayer(.top, depth: 0.05) }
            p.waypoints = (0..<3).map { _ in
                CGPoint(x: head.x + .random(in: -0.6...0.6) * L, y: head.y + .random(in: -0.6...0.6) * L)
            }
            p.speed = .random(in: 16...28)
            p.timeLeft = .random(in: 8...16)
            p.wander = 1.4
        case .hide:
            let w = hides.randomElement()!
            p.window = w.id
            p.speed = 105
            p.hold = .random(in: 3.5...7)
            p.timeLeft = 30
            requestLayer(.under(w.id), depth: 0.5)
        case .skim:
            let (w, e) = skims.randomElement()!
            p.window = w.id
            p.edge = e
            p.dir = Bool.random() ? 1 : -1
            let edgeLen = (e >= 2 ? w.frame.width : w.frame.height) - L
            p.maxPasses = edgeLen > L * 2.2 && Bool.random() ? 2 : 1
            p.timeLeft = 30
            requestLayer(.under(w.id), depth: 0.3)
        case .curious:
            p.timeLeft = 16
            p.wander = 0.25
            requestLayer(.top, depth: 0.05)
        case .flee, .summon:
            break
        }
        plan = p
    }
}
