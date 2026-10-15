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
        tracker.start()
        loadMonitor.onChange = { [weak self] busy in self?.setCalm(busy) }
        loadMonitor.start()
        start()
        if let force = ProcessInfo.processInfo.environment["BK_SUMMON"], !force.isEmpty { brain.summon() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
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
        restartDisplayLink()
    }

    private func stop() {
        running = false
        displayLink?.invalidate()
        displayLink = nil
        overlays.forEach { $0.hide() }
    }

    private func restartDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        guard running, let view = overlays.first?.displayView else { return }
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

    /// 60 fps only while she moves quickly; a slow glide looks just as smooth at 30.
    private var fastMode = true
    private func adaptFrameRate(_ link: CADisplayLink) {
        // Deep down she's blurred anyway, so judder can't be seen there.
        let sharp = brain.depth < 0.6
        let busy = brain.excitement > 0.05 || (sharp && (brain.speed > 70 || abs(brain.turnRate) > 0.7))
        let calm = brain.excitement == 0 && (!sharp || (brain.speed < 55 && abs(brain.turnRate) < 0.5))
        let want = brain.calm ? false : (fastMode ? !calm : busy)
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
        let depth = brain.depth
        let h = 1 - depth
        let L = Double(brain.L)
        shadowAmount += ((brain.layer == .top ? 1 : 0.6) - shadowAmount) * min(1, dt * 1.5)
        rig.apply(SharkPose(
            bones: brain.spine,
            angles: brain.spineAngles,
            roll: brain.roll,
            length: L,
            caustic: 0.14 + 0.32 * h,
            tint: 0.52 * pow(depth, 1.2),
            shadowOpacity: (0.30 - 0.10 * h + 0.10 * depth) * shadowAmount,
            shadowOffset: CGVector(dx: L * (0.025 + 0.075 * h), dy: -L * (0.035 + 0.10 * h)),
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
        let items = brain.windows.compactMap { w -> (CGRect, CGFloat)? in
            let a = occlusion[w.id] ?? 0
            return a > 0.01 && w.frame.intersects(region) ? (w.frame, a) : nil
        }
        let covered = brain.windows.contains { (occlusion[$0.id] ?? 0) > 0.99 && $0.frame.contains(region) }
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

    /// Like RunCat: the little shark in the menu bar swims faster the busier the Mac is.
    private func scheduleIconFrame() {
        let fps = 5 + 17 * min(1, loadMonitor.load * 1.3)
        let timer = Timer(timeInterval: 1 / fps, repeats: false) { [weak self] _ in
            guard let self else { return }
            iconFrame = (iconFrame + 1) % iconFrames.count
            statusItem.button?.image = iconFrames[iconFrame]
            scheduleIconFrame()
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
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
