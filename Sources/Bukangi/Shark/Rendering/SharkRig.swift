import AppKit
import SceneKit
import simd

/// Everything the renderer needs for one frame.
struct SharkPose {
    /// Bone positions in global screen points, snout first.
    var bones: [CGPoint]
    /// Heading of each bone in radians (screen space, CCW from +x).
    var angles: [Double]
    var roll: Double
    /// Current rendered body length in points.
    var length: Double
    var caustic: Double
    var tint: Double
    var shadowOpacity: Double
    var shadowOffset: CGVector
    /// 0 = crisp contact shadow, 1 = very diffuse.
    var shadowSoftness: Double
    /// 0...1, how "surfaced and cute" she looks (bigger eyes, rounder head).
    var cute: Double = 0
}

final class SharkRig {
    let scene = SCNScene()
    private let container = SCNNode()
    private let shadowContainer = SCNNode()
    private var bones: [SCNNode] = []
    private var shadowBones: [SCNNode] = []
    private var skinMaterials: [SCNMaterial] = []

    /// Model space has +y dorsal; we look straight down, so dorsal must face the camera (+z).
    private static let faceUp = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))

    init() {
        scene.lightingEnvironment.contents = Self.environmentCube()
        scene.lightingEnvironment.intensity = 0.95

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 1550
        sun.light!.color = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.93, alpha: 1)
        // Pointing into the screen, coming slightly from the upper left.
        sun.simdOrientation = simd_quatf(angle: -0.38, axis: simd_normalize(SIMD3(1, 1, 0)))
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 260
        fill.light!.color = NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.85, alpha: 1)
        fill.simdOrientation = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3(-1, -0.4, 0)))
        scene.rootNode.addChildNode(fill)

        build()
    }

    // MARK: Build

    private func build() {
        let mesh = SkinnedShark.build()
        let (geometry, weights, indices) = mesh.geometry()

        let bodyTex = SharkTextures.body()
        let finTex = SharkTextures.fin(lightUnderside: false)
        let pectTex = SharkTextures.fin(lightUnderside: true)
        let mats = [bodyTex, finTex, pectTex].map { tex -> SCNMaterial in
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = tex
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .repeat
            m.diffuse.mipFilter = .linear
            m.roughness.contents = 0.52
            m.metalness.contents = 0.0
            m.isDoubleSided = true
            m.shaderModifiers = Shaders.skin
            m.setValue(NSNumber(value: 0.0), forKey: "causticStrength")
            m.setValue(NSNumber(value: 0.0), forKey: "depthTint")
            return m
        }
        for m in mats { m.roughness.contents = 0.88 }
        geometry.materials = mats
        skinMaterials = mats

        container.simdOrientation = Self.faceUp
        scene.rootNode.addChildNode(container)
        bones = makeBones(in: container)
        let skinned = SCNNode(geometry: geometry)
        container.addChildNode(skinned)
        skinned.skinner = makeSkinner(geometry, bones: bones, weights: weights, indices: indices)

        let eyeMat = SCNMaterial()
        eyeMat.lightingModel = .physicallyBased
        eyeMat.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1)
        eyeMat.roughness.contents = 0.12
        eyeMat.metalness.contents = 0.0
        eyeMat.shaderModifiers = Shaders.skin
        skinMaterials.append(eyeMat)
        let glint = SCNMaterial()
        glint.lightingModel = .constant
        glint.diffuse.contents = NSColor(calibratedWhite: 1, alpha: 1)
        glint.shaderModifiers = [.fragment: Shaders.skin[.fragment]!]
        skinMaterials.append(glint)
        for (k, p) in SharkMesh.eyePositions().enumerated() {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.0084))
            eye.geometry!.materials = [eyeMat]
            eye.simdPosition = p - SIMD3(SharkMesh.boneX(1), 0, 0)
            let spark = SCNNode(geometry: SCNSphere(radius: 0.0021))
            spark.geometry!.materials = [glint]
            spark.simdPosition = SIMD3(0.0028, 0.0066, k == 0 ? 0.0018 : -0.0018)
            eye.addChildNode(spark)
            bones[1].addChildNode(eye)
            eyes.append(eye)
        }


        // Shadow: same skin driven by a duplicate skeleton, with soft edges from a shader.
        let shadowGeo = geometry.copy() as! SCNGeometry
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = NSColor.black
        sm.isDoubleSided = true
        sm.writesToDepthBuffer = false
        sm.readsFromDepthBuffer = false
        // Body and fins are separate pieces that overlap; max blending keeps the darkest coverage
        // instead of stacking it, so the overlaps don't show as darker bands. The shadow draws
        // first onto a clear target, so max works like normal coverage there.
        sm.blendMode = .max
        sm.shaderModifiers = [.fragment: Shaders.shadow]
        sm.setValue(NSNumber(value: 0.0), forKey: "shadowAlpha")
        sm.setValue(NSNumber(value: 0.5), forKey: "shadowSoft")
        shadowMaterial = sm
        shadowGeo.materials = [sm, sm, sm]
        shadowContainer.simdOrientation = Self.faceUp
        shadowContainer.renderingOrder = -10
        scene.rootNode.addChildNode(shadowContainer)
        shadowBones = makeBones(in: shadowContainer)
        let shadowSkinned = SCNNode(geometry: shadowGeo)
        shadowSkinned.renderingOrder = -10
        shadowContainer.addChildNode(shadowSkinned)
        shadowSkinned.skinner = makeSkinner(shadowGeo, bones: shadowBones, weights: weights, indices: indices)

    }

    private var shadowMaterial: SCNMaterial!
    private var eyes: [SCNNode] = []

    private func makeBones(in parent: SCNNode) -> [SCNNode] {
        (0..<SharkMesh.boneCount).map { i in
            let b = SCNNode()
            b.name = "bone\(i)"
            b.simdPosition = SIMD3(SharkMesh.boneX(i), 0, 0)
            parent.addChildNode(b)
            return b
        }
    }

    private func makeSkinner(_ g: SCNGeometry, bones: [SCNNode], weights: SCNGeometrySource,
                             indices: SCNGeometrySource) -> SCNSkinner {
        let inv = (0..<SharkMesh.boneCount).map { i -> NSValue in
            NSValue(scnMatrix4: SCNMatrix4MakeTranslation(CGFloat(-SharkMesh.boneX(i)), 0, 0))
        }
        let s = SCNSkinner(baseGeometry: g, bones: bones, boneInverseBindTransforms: inv,
                           boneWeights: weights, boneIndices: indices)
        s.skeleton = bones.first?.parent
        return s
    }

    // MARK: Per-frame

    func apply(_ p: SharkPose) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true

        let scale = SIMD3<Float>(repeating: Float(p.length))
        let rollQ = simd_quatf(angle: Float(p.roll), axis: SIMD3(1, 0, 0))
        for i in 0..<bones.count {
            let pt = p.bones[i]
            // Model space: x = screen x, z = -screen y, y = height toward the camera.
            let pos = SIMD3<Float>(Float(pt.x), 0, Float(-pt.y))
            let q = simd_quatf(angle: Float(p.angles[i]), axis: SIMD3(0, 1, 0)) * rollQ
            bones[i].simdPosition = pos
            bones[i].simdOrientation = q
            let swell: [Float] = [1.0, 0.9, 0.6, 0.25]
            let cuteScale = i < swell.count ? scale * (1 + 0.09 * Float(p.cute) * swell[i]) : scale
            bones[i].simdScale = cuteScale
            shadowBones[i].simdPosition = pos
            shadowBones[i].simdOrientation = q
            shadowBones[i].simdScale = scale
        }

        for m in skinMaterials {
            m.setValue(NSNumber(value: p.caustic), forKey: "causticStrength")
            m.setValue(NSNumber(value: p.tint), forKey: "depthTint")
        }

        let eyeScale = Float(1 + 0.14 * p.cute)
        for e in eyes { e.simdScale = SIMD3(repeating: eyeScale) }

        shadowContainer.simdPosition = SIMD3(Float(p.shadowOffset.dx), Float(p.shadowOffset.dy), -400)
        shadowContainer.isHidden = p.shadowOpacity < 0.005
        shadowMaterial.setValue(NSNumber(value: p.shadowOpacity), forKey: "shadowAlpha")
        shadowMaterial.setValue(NSNumber(value: p.shadowSoftness), forKey: "shadowSoft")

        SCNTransaction.commit()
    }

    // MARK: Helpers

    static func camera(for frame: CGRect) -> SCNNode {
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = Double(frame.height / 2)
        cam.zNear = 1
        cam.zFar = 6000
        let node = SCNNode()
        node.camera = cam
        node.simdPosition = SIMD3(Float(frame.midX), Float(frame.midY), 3000)
        return node
    }

    /// Cube map: +z (toward the viewer / water surface) bright, -z (the deep) dark.
    private static func environmentCube() -> [NSImage] {
        func face(_ top: NSColor, _ bottom: NSColor) -> NSImage {
            let size = NSSize(width: 64, height: 64)
            let img = NSImage(size: size)
            img.lockFocus()
            NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(origin: .zero, size: size), angle: 270)
            img.unlockFocus()
            return img
        }
        let surface = NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.95, alpha: 1)
        let mid = NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.53, alpha: 1)
        let deep = NSColor(calibratedRed: 0.05, green: 0.13, blue: 0.16, alpha: 1)
        // Order: +x, -x, +y, -y, +z, -z
        return [face(mid, mid), face(mid, mid), face(mid, mid), face(mid, mid),
                face(surface, surface), face(deep, deep)]
    }
}
