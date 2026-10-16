import AppKit

struct TrackedWindow {
    let id: CGWindowID
    /// Cocoa global coordinates (origin bottom-left of the primary screen).
    let frame: CGRect
    /// Seabed windows stacked in front of this one; the parts they cover can't hide the shark.
    var hiddenBy: [CGRect] = []

    func shows(_ p: CGPoint) -> Bool {
        frame.contains(p) && !hiddenBy.contains { $0.contains(p) }
    }
}

/// Reads the on-screen window stack (front to back) on a background queue, without needing
/// Screen Recording permission. Windows covering most of a display (full-screen or maximized apps)
/// are treated as the seabed: Bukangi swims over them instead of hiding under them.
final class WindowTracker {
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "bukangi.windows", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var _windows: [TrackedWindow] = []
    private var primaryHeight: CGFloat = 0
    private var screens: [CGRect] = []

    var windows: [TrackedWindow] {
        lock.lock(); defer { lock.unlock() }
        return _windows
    }

    func configure(primaryHeight: CGFloat, screens: [CGRect]) {
        lock.lock()
        self.primaryHeight = primaryHeight
        self.screens = screens
        lock.unlock()
    }

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refreshNow() { queue.sync { poll() } }

    private func poll() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        lock.lock()
        let ph = primaryHeight, scr = screens
        lock.unlock()
        struct Raw { let id: CGWindowID; let pid: Int32; let frame: CGRect }
        var raws: [Raw] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let owner = w[kCGWindowOwnerPID as String] as? Int32 ?? -1
            if owner == pid { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  let num = w[kCGWindowNumber as String] as? Int else { continue }
            if r.width < 80 || r.height < 50 { continue }
            raws.append(Raw(id: CGWindowID(num), pid: owner,
                            frame: CGRect(x: r.minX, y: ph - r.maxY, width: r.width, height: r.height)))
        }
        // Full-screen and maximized windows are the seabed; so are their own panels and sheets.
        var seabed: [(pid: Int32, screen: CGRect)] = []
        var seabedFrames = Set<CGWindowID>()
        for r in raws {
            if let s = scr.first(where: { s in
                let i = s.intersection(r.frame)
                return !i.isNull && i.width * i.height >= s.width * s.height * 0.80
            }) {
                seabed.append((r.pid, s))
                seabedFrames.insert(r.id)
            }
        }
        var out: [TrackedWindow] = []
        var seabedInFront: [CGRect] = []
        for r in raws {
            if seabedFrames.contains(r.id) { seabedInFront.append(r.frame); continue }
            if seabed.contains(where: { $0.pid == r.pid && $0.screen.intersects(r.frame) }) { continue }
            let hidden = seabedInFront.filter { $0.intersects(r.frame) }
            if hidden.contains(where: { $0.contains(r.frame) }) { continue }
            out.append(TrackedWindow(id: r.id, frame: r.frame, hiddenBy: hidden))
        }
        lock.lock()
        _windows = out
        lock.unlock()
    }
}
