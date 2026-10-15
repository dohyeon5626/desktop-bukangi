import AppKit
import Metal
import QuartzCore
import SceneKit

/// Renders the shark scene for one square region of the desktop into a CAMetalLayer.
final class SharkRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SCNRenderer
    private let camera = SCNNode()
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var techniques: [Int: SCNTechnique] = [:]
    private var blurLevel: Int?
    private let sampleCount: Int

    init(scene: SCNScene) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.zNear = 1
        cam.zFar = 6000
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
    }

    /// Drop cached blur techniques so their buffers are recreated for a new region size.
    func resetTechniques() {
        techniques.removeAll()
        let level = blurLevel
        blurLevel = nil
        renderer.technique = nil
        setBlur(level)
    }

    func setBlur(_ level: Int?) {
        guard level != blurLevel else { return }
        blurLevel = level
        if let level {
            if techniques[level] == nil { techniques[level] = BlurTechnique.make(level: level) }
            renderer.technique = techniques[level]
        } else {
            renderer.technique = nil
        }
    }

    /// Draw `region` (global points) into `layer` and present it inside the current CATransaction.
    func render(region: CGRect, into layer: CAMetalLayer, time: CFTimeInterval) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.simdPosition = SIMD3(Float(region.midX), Float(region.midY), 3000)
        camera.camera!.orthographicScale = Double(region.height / 2)
        SCNTransaction.commit()

        guard let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1 {
            ensureTargets(width: w, height: h)
            pass.colorAttachments[0].texture = msaaColor
            pass.colorAttachments[0].resolveTexture = drawable.texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            ensureTargets(width: w, height: h)
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        renderer.sceneTime = time
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cb, passDescriptor: pass)
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
    }

    private func ensureTargets(width: Int, height: Int) {
        if let t = msaaDepth, t.width == width, t.height == height { return }
        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            d.sampleCount = sampleCount
            d.usage = .renderTarget
            d.storageMode = .memoryless
            return device.makeTexture(descriptor: d)
        }
        msaaColor = sampleCount > 1 ? make(.bgra8Unorm_srgb) : nil
        msaaDepth = make(.depth32Float)
    }
}
