import AppKit
import Metal

/// One transparent, click-through overlay per display. The shark is drawn into a small
/// CAMetalLayer that follows her around, instead of a full-screen view, so the GPU and the
/// window server only ever touch the few hundred points she occupies.
final class Overlay {
    let screen: NSScreen
    let frame: CGRect
    let window: OverlayWindow
    let metalLayer = CAMetalLayer()
    private let container: NSView
    private let rippleView: NSView
    private let maskLayer = CALayer()
    private var maskShapes: [CAShapeLayer] = []
    private var lastMask: [(CGRect, CGFloat)] = []
    private var visibleNow = false

    init(screen: NSScreen, device: MTLDevice) {
        self.screen = screen
        frame = screen.frame
        window = OverlayWindow(screen: screen)
        let bounds = CGRect(origin: .zero, size: frame.size)

        let root = NSView(frame: bounds)
        root.wantsLayer = true
        container = NSView(frame: bounds)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.presentsWithTransaction = true
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "mask": NSNull()]
        metalLayer.isHidden = true
        container.layer?.addSublayer(metalLayer)
        maskLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]

        rippleView = NSView(frame: bounds)
        rippleView.wantsLayer = true
        rippleView.autoresizingMask = [.width, .height]

        root.addSubview(container)
        root.addSubview(rippleView)
        window.contentView = root
    }

    var displayView: NSView? { window.contentView }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }

    /// Place the render layer over `region` (global points). Returns false when it's off this display.
    func place(region: CGRect) -> Bool {
        let local = region.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let onScreen = !region.isEmpty && local.intersects(CGRect(origin: .zero, size: frame.size))
        if onScreen != visibleNow {
            visibleNow = onScreen
            metalLayer.isHidden = !onScreen
        }
        guard onScreen else { return false }
        metalLayer.frame = local
        let px = CGSize(width: (local.width * metalLayer.contentsScale).rounded(),
                        height: (local.height * metalLayer.contentsScale).rounded())
        if metalLayer.drawableSize != px { metalLayer.drawableSize = px }
        return true
    }

    /// `items`: windows that should hide the shark, with how strongly (0...1), in global points.
    /// The mask lives on the small shark layer only (and is dropped when nothing covers her),
    /// so the window server never has to composite a full-screen offscreen pass.
    func updateMask(_ items: [(CGRect, CGFloat)]) {
        let region = metalLayer.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        let local: [(CGRect, CGFloat)] = items.compactMap { r, a in
            guard a > 0.01, r.intersects(region) else { return nil }
            return (r.offsetBy(dx: -region.minX, dy: -region.minY), a)
        }
        if local.isEmpty {
            if metalLayer.mask != nil { metalLayer.mask = nil }
            lastMask = []
            return
        }
        if metalLayer.mask == nil { metalLayer.mask = maskLayer }
        maskLayer.frame = metalLayer.bounds
        if local.count == lastMask.count && zip(local, lastMask).allSatisfy({ $0.0 == $1.0 && abs($0.1 - $1.1) < 0.002 }) { return }
        lastMask = local

        let bounds = metalLayer.bounds
        let paths = local.map { (CGPath(roundedRect: $0.0, cornerWidth: 12, cornerHeight: 12, transform: nil), $0.1) }
        var shapes: [(CGPath, Float)] = []
        let all = CGMutablePath()
        for (p, _) in paths { all.addPath(p) }
        shapes.append((CGPath(rect: bounds, transform: nil).subtracting(all), 1))
        for (i, (p, a)) in paths.enumerated() where a < 0.99 {
            let others = CGMutablePath()
            for (j, (q, _)) in paths.enumerated() where j != i { others.addPath(q) }
            shapes.append((others.isEmpty ? p : p.subtracting(others), Float(1 - a)))
        }
        while maskShapes.count < shapes.count {
            let s = CAShapeLayer()
            s.fillColor = NSColor.black.cgColor
            s.actions = ["path": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
            maskLayer.addSublayer(s)
            maskShapes.append(s)
        }
        for (i, layer) in maskShapes.enumerated() {
            if i < shapes.count {
                layer.path = shapes[i].0
                layer.opacity = shapes[i].1
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
    }

    func setAlpha(_ a: CGFloat) {
        let f = Float(a)
        if abs(metalLayer.opacity - f) > 0.002 { metalLayer.opacity = f }
    }

    /// A single small ring left behind as she swims along the surface.
    func wake(at p: CGPoint, size: CGFloat) {
        guard let host = rippleView.layer else { return }
        let ring = CAShapeLayer()
        let r = size * 0.045
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        ring.fillColor = nil
        ring.strokeColor = NSColor(calibratedRed: 0.88, green: 0.98, blue: 1.0, alpha: 1).cgColor
        ring.lineWidth = 0.8
        ring.opacity = 0
        host.addSublayer(ring)
        let dur = 1.6
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 2.2
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.16, 0]
        fade.keyTimes = [0, 0.2, 1]
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = dur
        ring.add(g, forKey: "wake")
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { ring.removeFromSuperlayer() }
    }

    /// Concentric rings on the water surface when Bukangi comes up.
    func ripple(at p: CGPoint, size: CGFloat) {
        guard let host = rippleView.layer else { return }
        let c = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        for k in 0..<3 {
            let ring = CAShapeLayer()
            let r = size * 0.5
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            ring.position = c
            ring.fillColor = nil
            ring.strokeColor = NSColor(calibratedRed: 0.85, green: 0.97, blue: 1.0, alpha: 1).cgColor
            ring.lineWidth = 1.6
            ring.opacity = 0
            ring.shadowColor = NSColor.white.cgColor
            ring.shadowRadius = 3
            ring.shadowOpacity = 0.6
            ring.shadowOffset = .zero
            host.addSublayer(ring)

            let dur = 1.9
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.5
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.55, 0]
            fade.keyTimes = [0, 0.18, 1]
            let width = CABasicAnimation(keyPath: "lineWidth")
            width.fromValue = 2.4
            width.toValue = 0.4
            let g = CAAnimationGroup()
            g.animations = [scale, fade, width]
            g.duration = dur
            g.beginTime = CACurrentMediaTime() + Double(k) * 0.22
            g.fillMode = .backwards
            ring.add(g, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + dur + Double(k) * 0.22 + 0.1) { ring.removeFromSuperlayer() }
        }
    }
}
