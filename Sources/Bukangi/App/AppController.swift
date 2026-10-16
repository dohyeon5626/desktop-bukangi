import AppKit
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate {
    private let rig = SharkRig()
    private let brain = SharkBrain()
    private let tracker = WindowTracker()
    private let loadMonitor = SystemLoadMonitor()
    private lazy var sharkRenderer = SharkRenderer(scene: rig.scene)
    private var overlays: [Overlay] = []
    private var occlusion: [CGWindowID: CGFloat] = [:]
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var shadowAmount = 0.0
    private var backing: CGFloat = 2
    private var running = false
    private var statusItem: NSStatusItem!

    /// Body length as a fraction of the main display's width.
    private let sizeFraction: CGFloat = 0.17

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildOverlays()
        applySize()
        tracker.refreshNow()
        brain.windows = tracker.windows
        brain.reset()
        loadMonitor.onChange = { [weak self] busy in self?.setCalm(busy) }
        loadMonitor.start()
        start()
        if let force = ProcessInfo.processInfo.environment["BK_SUMMON"], !force.isEmpty { brain.summon() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observeScreenVisibility()
    }

    private func buildOverlays() {
        overlays.forEach { $0.hide() }
        overlays = NSScreen.screens.map { Overlay(screen: $0, device: sharkRenderer.device) }
        backing = NSScreen.screens.first?.backingScaleFactor ?? 2
        let frames = overlays.map(\.frame)
        tracker.configure(primaryHeight: NSScreen.screens.first?.frame.height ?? 0, screens: frames)
        brain.screens = frames
        if running { overlays.forEach { $0.show() } }
        restartDisplayLink()
    }

    @objc private func screensChanged() {
        if NSScreen.screens.map(\.frame) != overlays.map(\.frame) {
            buildOverlays()
            applySize()
        } else if running {
            overlays.forEach { $0.show() }
        }
    }

    @objc private func spaceChanged() {
        // Re-assert ordering so we also float over full-screen apps in their own Space.
        if running { overlays.forEach { $0.show() } }
        tracker.refreshNow()
    }

    private func applySize() {
        let main = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        brain.length = max(180, min(main.width, main.height * 1.6) * sizeFraction)
    }

    private func start() {
        running = true
        lastTimestamp = 0
        overlays.forEach { $0.show() }
        if !isSuspended { tracker.start() }
        restartDisplayLink()
    }

    private func stop() {
        running = false
        displayLink?.invalidate()
        displayLink = nil
        tracker.stop()
        overlays.forEach { $0.hide() }
    }

    // MARK: Display sleep & lock

    /// Why nobody can see the desktop right now (display asleep, locked, screensaver, other user).
    /// While any reason holds, rendering, window polling and the menu bar animation all stop.
    private var unseenReasons = Set<String>()
    private var isSuspended: Bool { !unseenReasons.isEmpty }

    private func observeScreenVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, String, String, String)] = [
            (workspace, NSWorkspace.screensDidSleepNotification.rawValue, NSWorkspace.screensDidWakeNotification.rawValue, "display"),
            (workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue, NSWorkspace.sessionDidBecomeActiveNotification.rawValue, "session"),
            (distributed, "com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "lock"),
            (distributed, "com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "screensaver"),
        ]
        for (center, off, on, reason) in pairs {
            center.addObserver(forName: Notification.Name(off), object: nil, queue: .main) { [weak self] _ in
                self?.setUnseen(reason, true)
            }
            center.addObserver(forName: Notification.Name(on), object: nil, queue: .main) { [weak self] _ in
                self?.setUnseen(reason, false)
            }
        }
    }

    private func setUnseen(_ reason: String, _ unseen: Bool) {
        let wasSuspended = isSuspended
        if unseen { unseenReasons.insert(reason) } else { unseenReasons.remove(reason) }
        guard wasSuspended != isSuspended else { return }
        if isSuspended {
            displayLink?.invalidate()
            displayLink = nil
            tracker.stop()
            loadMonitor.stop()
            iconTimer?.invalidate()
            iconTimer = nil
        } else {
            if running { tracker.start() }
            loadMonitor.start()
            lastTimestamp = 0
            restartDisplayLink()
            scheduleIconFrame()
        }
    }

    private func restartDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        guard running, !isSuspended, let view = overlays.first?.displayView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        let fps: Float = brain.calm ? 30 : 60
        fastMode = !brain.calm
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        lastTimestamp = now
        dt = min(max(dt, 1.0 / 240), 1.0 / 20)

        brain.windows = tracker.windows
        brain.updateMouse(NSEvent.mouseLocation, dt: dt)
        brain.step(dt)
        adaptFrameRate(link)
        updateOcclusion(dt)
        applyPose(dt)
        present(time: now)
        emitEffects()
    }

    /// 60 fps whenever she can be seen, since even a slow glide steps visibly at 30. Drop to 30
    /// only when she's hidden under a window, very deep and blurred, or the Mac is busy.
    private var fastMode = true
    private func adaptFrameRate(_ link: CADisplayLink) {
        let want = !brain.calm && !hiddenUnderWindow && (brain.depth < 0.8 || brain.excitement > 0.05)
        guard want != fastMode else { return }
        fastMode = want
        let fps: Float = want ? 60 : 30
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
    }

    private func updateOcclusion(_ dt: Double) {
        // She only changes layers while clear of the window involved, so occlusion can switch instantly.
        let front = Set(brain.frontWindows.map(\.id))
        var next: [CGWindowID: CGFloat] = [:]
        for w in brain.windows { next[w.id] = front.contains(w.id) ? 1 : 0 }
        occlusion = next
    }

    private func applyPose(_ dt: Double) {
        let depths = brain.spineDepths
        let depth = depths.reduce(0, +) / Double(max(depths.count, 1))
        let h = 1 - depth
        let L = Double(brain.L)
        shadowAmount += ((brain.layer == .top ? 1 : 0.6) - shadowAmount) * min(1, dt * 1.5)
        rig.apply(SharkPose(
            bones: brain.spine,
            angles: brain.spineAngles,
            roll: brain.roll,
            scales: brain.spineScales,
            pitches: brain.spinePitches,
            finAngles: brain.finAngles,
            finSweeps: brain.finSweeps,
            caustic: 0.14 + 0.32 * h,
            tintHead: 0.52 * pow(depths.first ?? depth, 1.2),
            tintTail: 0.52 * pow(depths.last ?? depth, 1.2),
            // The shadow fades out as she dives; deep down it would only smudge the blur.
            shadowOpacity: (0.30 - 0.10 * h + 0.10 * depth) * shadowAmount * max(0, 1 - depth / 0.6),
            shadowOffset: CGVector(dx: L * (0.03 + 0.11 * h), dy: -L * (0.04 + 0.15 * h)),
            shadowSoftness: 0.25 + 0.75 * h,
            cute: brain.cute))
        sharkRenderer.setBlur(BlurTechnique.level(forPixels: max(2.0, 7.0 * pow(depth, 1.4) * Double(backing))))
    }

    /// A fixed-size square around the shark and her shadow, snapped to the pixel grid. The size
    /// must stay constant: SceneKit sizes the blur pass's buffers once, so a changing viewport
    /// would stretch and crop her.
    private func renderRegion() -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -minX, minY = minX, maxY = -minX
        for p in brain.spine { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let L = brain.L
        let h = CGFloat(1 - brain.depth)
        let cx = (minX + maxX) / 2 + L * (0.0125 + 0.0375 * h)
        let cy = (minY + maxY) / 2 - L * (0.0175 + 0.05 * h)
        let side = (brain.length * 1.6).rounded()
        if side != regionSide {
            regionSide = side
            sharkRenderer.resetTechniques()
        }
        let snap = { (v: CGFloat) in (v * self.backing).rounded() / self.backing }
        return CGRect(x: snap(cx - side / 2), y: snap(cy - side / 2), width: side, height: side)
    }

    private var regionSide: CGFloat = 0
    private var hiddenUnderWindow = false

    private func present(time: CFTimeInterval) {
        let region = renderRegion()
        let items = brain.windows.compactMap { w -> (CGRect, CGFloat, [CGRect])? in
            let a = occlusion[w.id] ?? 0
            return a > 0.01 && w.frame.intersects(region) ? (w.frame, a, w.hiddenBy) : nil
        }
        let covered = brain.windows.contains { w in
            (occlusion[w.id] ?? 0) > 0.99 && w.frame.contains(region) && !w.hiddenBy.contains { $0.intersects(region) }
        }
        if covered {
            if !hiddenUnderWindow {
                hiddenUnderWindow = true
                CATransaction.begin(); CATransaction.setDisableActions(true)
                overlays.forEach { $0.metalLayer.isHidden = true; _ = $0.place(region: .zero) }
                CATransaction.commit()
            }
            return
        }
        hiddenUnderWindow = false
        let alpha = CGFloat(1 - 0.36 * brain.depth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for o in overlays where o.place(region: region) {
            o.updateMask(items)
            o.setAlpha(alpha)
            sharkRenderer.render(region: region, into: o.metalLayer, time: time)
        }
        CATransaction.commit()
    }

    private func emitEffects() {
        let L = brain.L
        if brain.surfacedEvent {
            brain.surfacedEvent = false
            let c = brain.center
            overlays.first { $0.frame.contains(c) }?.ripple(at: c, size: L * 0.9)
        }
        for p in brain.wakePoints { overlays.first { $0.frame.contains(p) }?.wake(at: p, size: L) }
        brain.wakePoints.removeAll()
    }

    /// When the Mac is working hard, Bukangi sinks deep, slows down and renders at 30 fps.
    private func setCalm(_ calm: Bool) {
        guard calm != brain.calm else { return }
        brain.calm = calm
        if calm { brain.calmDown() }
        restartDisplayLink()
    }

    // MARK: Menu

    private let iconFrames = (0..<StatusIcon.frameCount).map(StatusIcon.frame)
    private var iconFrame = 0
    private var iconTimer: Timer?

    /// Like RunCat: the little shark in the menu bar swims faster the busier the Mac is.
    private func scheduleIconFrame() {
        iconTimer?.invalidate()
        iconTimer = nil
        guard !isSuspended else { return }
        let fps = 5 + 17 * min(1, loadMonitor.load * 1.3)
        let timer = Timer(timeInterval: 1 / fps, repeats: false) { [weak self] _ in
            guard let self else { return }
            iconFrame = (iconFrame + 1) % iconFrames.count
            statusItem.button?.image = iconFrames[iconFrame]
            scheduleIconFrame()
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = iconFrames[0]
        scheduleIconFrame()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "부캉이", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "숨기기", action: #selector(toggleVisible(_:)), keyEquivalent: "h")
        toggle.target = self
        menu.addItem(toggle)
        let call = NSMenuItem(title: "수면으로 부르기", action: #selector(summon), keyEquivalent: "s")
        call.target = self
        menu.addItem(call)

        let login = NSMenuItem(title: "로그인 시 실행", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleVisible(_ sender: NSMenuItem) {
        if running { stop(); sender.title = "보이기" } else { start(); sender.title = "숨기기" }
    }

    @objc private func summon() {
        if !running { start() }
        brain.summon()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Bukangi login item: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
