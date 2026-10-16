import AppKit

/// Moving through the window stack as if the windows were terrain.
extension SharkBrain {
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
        frontWindows.contains { $0.shows(p) }
    }

    func window(_ id: CGWindowID?) -> TrackedWindow? {
        guard let id else { return nil }
        return windows.first { $0.id == id }
    }

    /// Ask to move to another layer. Windows are treated like terrain: she only changes her
    /// relation to a window while she isn't overlapping it, one window at a time, so she
    /// slips under (or glides over) each window right at its edge as she swims past.
    func requestLayer(_ l: SharkLayer, depth d: Double) {
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
    func level(of l: SharkLayer) -> Int {
        switch l {
        case .top: return 0
        case .bottom: return windows.count
        case .under(let id): return (windows.firstIndex { $0.id == id }).map { $0 + 1 } ?? windows.count
        }
    }

    func layer(atLevel k: Int) -> SharkLayer {
        if k <= 0 { return .top }
        if k >= windows.count { return .bottom }
        return .under(windows[k - 1].id)
    }

    func front(_ l: SharkLayer) -> ArraySlice<TrackedWindow> {
        switch l {
        case .top: return []
        case .bottom: return windows[...]
        case .under(let id):
            if let i = windows.firstIndex(where: { $0.id == id }) { return windows[...i] }
            return windows[...]
        }
    }

    func resolveLayer() {
        let goal = level(of: wantedLayer)
        var current = level(of: layer)
        let margin = L * 0.2
        func overlaps(_ w: TrackedWindow) -> Bool {
            let f = w.frame.insetBy(dx: -margin, dy: -margin)
            return spine.contains { p in f.contains(p) && !w.hiddenBy.contains { $0.contains(p) } }
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

        guard let b = blocker, time - pendingSince > 2 else {
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
}
