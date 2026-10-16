import AppKit
import SceneKit

/// `Bukangi --snapshot <dir>` renders a few poses to PNG for visual checks.
enum SnapshotTool {
    static func pose(head: CGPoint, heading: Double, curvature: Double, phase: Double, amp: Double,
                     length: Double) -> ([CGPoint], [Double]) {
        let n = SharkMesh.boneCount
        let seg = length / Double(n - 1)
        var base: [CGPoint] = [], tang: [Double] = []
        var p = head, a = heading
        for i in 0..<n {
            base.append(p); tang.append(a)
            if i < n - 1 {
                p = CGPoint(x: p.x - cos(a) * seg, y: p.y - sin(a) * seg)
                a -= curvature * seg / length
            }
        }
        var pts: [CGPoint] = []
        for i in 0..<n {
            let s = Double(i) / Double(n - 1)
            let lat = length * amp * (0.08 + 0.92 * pow(s, 2.2)) * sin(phase - 2 * .pi * 0.85 * s)
            pts.append(CGPoint(x: base[i].x - sin(tang[i]) * lat, y: base[i].y + cos(tang[i]) * lat))
        }
        var angles: [Double] = []
        for i in 0..<n {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, n - 1)]
            angles.append(atan2(a.y - b.y, a.x - b.x))
        }
        return (pts, angles)
    }

    static func run(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let rig = SharkRig()
        rig.scene.background.contents = ProcessInfo.processInfo.environment["BK_CLEAR"] != nil ? NSColor.clear : NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.43, alpha: 1)
        let frame = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let cam = SharkRig.camera(for: frame)
        rig.scene.rootNode.addChildNode(cam)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = rig.scene
        renderer.pointOfView = cam

        struct Shot { var roll = 0.0; var name: String; var curvature: Double; var phase: Double; var amp: Double; var depth: Double; var heading: Double }
        let shots = [
            Shot(name: "straight", curvature: 0, phase: 0.6, amp: 0.05, depth: 0, heading: 0.15),
            Shot(name: "turn", curvature: 2.4, phase: 2.0, amp: 0.05, depth: 0, heading: 1.2),
            Shot(roll: 1.45, name: "rolled", curvature: 0, phase: 0.6, amp: 0.02, depth: 0, heading: 0.0),
            Shot(name: "deep", curvature: 0.6, phase: 4.0, amp: 0.05, depth: 1, heading: -2.6),
        ]
        for s in shots {
            let L = 620.0 * (1 - 0.24 * s.depth)
            let head = CGPoint(x: 700 + cos(s.heading) * L * 0.5, y: 400 + sin(s.heading) * L * 0.5)
            let (pts, angles) = pose(head: head, heading: s.heading, curvature: s.curvature, phase: s.phase, amp: s.amp, length: L)
            let h = 1 - s.depth
            rig.apply(SharkPose(bones: pts, angles: angles, roll: s.roll, length: L,
                                caustic: 0.55 * h, tint: 0.5 * s.depth,
                                shadowOpacity: 0.32 * max(0, 1 - s.depth / 0.6), shadowOffset: CGVector(dx: L * (0.02 + 0.08 * h), dy: -L * (0.03 + 0.11 * h)),
                                shadowSoftness: h, cute: h))
            // Same blur the app uses: a touch at the surface, much more when deep.
            renderer.technique = BlurTechnique.make(level: s.depth > 0.5 ? 7 : 0)
            let img = renderer.snapshot(atTime: 1.0, with: frame.size, antialiasingMode: .multisampling4X)
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(s.name).png"))
        }
        let tex = NSBitmapImageRep(cgImage: SharkTextures.body())
        try? tex.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/body_tex.png"))
        // Menu bar logo previews: every swim frame, large (light) and at real size @2x (dark).
        for (name, scale, dark) in [("icon_large", 10.0, false), ("icon_dark", 2.0, true)] {
            let w = Int(StatusIcon.size.width * scale), h = Int(StatusIcon.size.height * scale)
            let n = StatusIcon.frameCount
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h * n, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: w, height: h * n).fill()
            for k in 0..<n {
                // Draw each frame on its own transparent layer first, as the menu bar does.
                let phase = Double(k) / Double(n) * 2 * .pi
                let icon = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                    StatusIcon.draw(in: r, phase: phase, color: dark ? .white : .black)
                    return true
                }
                icon.draw(in: NSRect(x: 0, y: h * (n - 1 - k), width: w, height: h))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        }
        print("wrote snapshots to \(outDir)")
    }
}
