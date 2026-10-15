import AppKit

/// Behaviour plans: where to swim next and how fast.
extension SharkBrain {
    func planTarget(_ dt: Double) -> (CGPoint, CGFloat)? {
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

    func hideTarget() -> (CGPoint, CGFloat)? {
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
    func curiousTarget() -> (CGPoint, CGFloat)? {
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

    func skimTarget() -> (CGPoint, CGFloat)? {
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

    func peekEdge(for w: CGRect) -> Int? {
        var options: [Int] = []
        let room = L * 0.45
        if covers(CGPoint(x: w.maxX + room, y: w.midY)) { options.append(0) }
        if covers(CGPoint(x: w.minX - room, y: w.midY)) { options.append(1) }
        if covers(CGPoint(x: w.midX, y: w.maxY + room)) && w.maxY + room < (screenFor(CGPoint(x: w.midX, y: w.maxY))?.maxY ?? 0) - 30 { options.append(2) }
        if covers(CGPoint(x: w.midX, y: w.minY - room)) { options.append(3) }
        return options.randomElement()
    }

    func covers(_ p: CGPoint) -> Bool { screens.contains { $0.contains(p) } }

    func screenFor(_ p: CGPoint) -> CGRect? {
        if let s = screens.first(where: { $0.contains(p) }) { return s }
        return screens.min { a, b in
            dist(p, CGPoint(x: a.midX, y: a.midY)) < dist(p, CGPoint(x: b.midX, y: b.midY))
        }
    }

    func randomPoint(insetFactor: CGFloat = 0.45, awayFrom: CGPoint? = nil) -> CGPoint? {
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

    var hideCandidates: [TrackedWindow] {
        windows.filter { $0.frame.width > L * 1.15 && $0.frame.height > L * 0.5 && covers(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    func skimOptions() -> [(TrackedWindow, Int)] {
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

    func nextPlan(preferred: Kind? = nil) {
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
