import AppKit

/// Menu bar logo: a bold little shark silhouette that swims, RunCat-style. Frames are template
/// images so macOS tints them for light and dark menu bars; the eye is cut out.
enum StatusIcon {
    static let frameCount = 8
    static let size = NSSize(width: 26, height: 18)

    /// One frame of the swim cycle.
    static func frame(_ index: Int) -> NSImage {
        let phase = Double(index) / Double(frameCount) * 2 * .pi
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, phase: phase, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "부캉이"
        return image
    }

    static func draw(in rect: NSRect, phase: Double, color: NSColor) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: rect.minX, yBy: rect.minY)
        t.scale(by: rect.height / size.height)
        t.concat()

        color.setFill()
        body(phase: phase).fill()
        ctx.compositingOperation = .destinationOut
        let eye = bend(NSPoint(x: 20.4, y: 8.6), phase: phase)
        NSBezierPath(ovalIn: NSRect(x: eye.x - 0.95, y: eye.y - 0.95, width: 1.9, height: 1.9)).fill()
        ctx.restoreGraphicsState()
    }

    /// Body wave: nothing at the snout, growing toward the tail.
    private static func bend(_ p: NSPoint, phase: Double) -> NSPoint {
        let s = max(0, min(1, (24.0 - Double(p.x)) / 24.0))    // 0 at the snout, 1 at the tail tip
        let dy = 2.0 * pow(s, 2.2) * sin(phase - 4.0 * s)
        return NSPoint(x: p.x, y: p.y + CGFloat(dy))
    }

    /// Shark facing right on a 26×18 grid (y up), bent by the swim phase.
    static func body(phase: Double) -> NSBezierPath {
        let b = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { bend(NSPoint(x: x, y: y), phase: phase) }
        func c(_ to: NSPoint, _ c1: NSPoint, _ c2: NSPoint) { b.curve(to: to, controlPoint1: c1, controlPoint2: c2) }
        b.move(to: p(24.6, 8.2))                                                   // snout
        c(p(16.2, 11.6), p(24.3, 10.6), p(20.4, 11.8))                             // head
        c(p(13.4, 16.0), p(15.4, 12.9), p(13.6, 15.2))                             // dorsal fin
        c(p(12.4, 15.8), p(13.2, 16.5), p(12.6, 16.3))
        c(p(10.6, 11.0), p(12.2, 14.2), p(11.6, 11.8))
        c(p(5.0, 9.0), p(8.8, 10.5), p(6.6, 9.6))                                 // back
        c(p(1.2, 13.6), p(3.8, 10.3), p(2.0, 12.8))                               // tail, upper lobe
        c(p(3.4, 8.5), p(0.5, 13.1), p(2.2, 9.4))
        c(p(1.5, 4.6), p(2.2, 7.5), p(1.3, 5.5))                                  // tail, lower lobe
        c(p(5.2, 7.5), p(2.3, 4.2), p(3.9, 6.6))
        c(p(13.2, 6.0), p(7.4, 6.6), p(10.4, 6.0))                                // belly
        c(p(12.0, 3.0), p(13.0, 4.9), p(12.0, 3.8))                               // pectoral fin
        c(p(16.4, 5.8), p(12.6, 2.3), p(15.6, 4.6))
        c(p(23.4, 6.5), p(18.8, 5.7), p(22.2, 5.9))                               // chin
        c(p(24.6, 8.2), p(24.2, 6.9), p(24.6, 7.6))
        b.close()
        return b
    }
}
