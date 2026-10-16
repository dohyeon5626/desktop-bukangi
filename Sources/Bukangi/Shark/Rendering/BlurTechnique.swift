import Metal
import SceneKit

/// GPU depth blur for when Bukangi swims deep: a separable Gaussian inside SceneKit's own render
/// pass (no Core Image round-trips). Targets are full resolution: with a custom viewport SceneKit
/// doesn't scale DRAW_SCENE into smaller targets, which cropped and enlarged her.
enum BlurTechnique {
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BKIn { float4 position [[attribute(0)]]; };
    struct BKOut { float4 position [[position]]; float2 uv; };

    vertex BKOut bk_quad(BKIn in [[stage_in]]) {
        BKOut o;
        o.position = in.position;
        o.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
        return o;
    }

    static half4 bk_blur(texture2d<half, access::sample> tex, float2 uv, float2 dir, float radius) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
        float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
        float r = max(radius, 0.01);
        float sigma = r * 0.5;
        half4 acc = half4(0.0);
        float wsum = 0.0;
        for (int i = -8; i <= 8; i++) {
            float x = float(i) * r / 8.0;
            float w = exp(-0.5 * x * x / (sigma * sigma));
            acc += tex.sample(s, uv + dir * texel * x) * half(w);
            wsum += w;
        }
        return acc / half(wsum);
    }

    // The final target is sRGB, which gamma-encodes each colour channel of premultiplied
    // pixels on its own and lifts soft, semi-transparent edges into a bright halo. Pre-correct
    // so the stored value is the colour encoded first and premultiplied after.
    static half4 bk_store_srgb(half4 p) {
        float a = float(p.a);
        if (a <= 0.0001) { return half4(0.0); }
        float3 c = clamp(float3(p.rgb) / a, 0.0, 1.0);
        float3 enc = select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
        float3 o = enc * a;
        float3 lin = select(pow((o + 0.055) / 1.055, 2.4), o / 12.92, o <= 0.04045);
        return half4(half3(lin), half(a));
    }

    BK_LEVEL_FUNCTIONS
    """

    /// Blur radii (in pixels) for each level.
    static let levels: [Double] = [2.0, 3.2, 4.6, 6.0, 7.6, 9.2, 11.0, 13.0, 15.2]

    private static var library: MTLLibrary? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        var fns = ""
        for (i, r) in levels.enumerated() {
            fns += """
            fragment half4 bk_blur_h_\(i)(BKOut in [[stage_in]], texture2d<half, access::sample> colorSampler [[texture(0)]]) {
                return bk_blur(colorSampler, in.uv, float2(1.0, 0.0), \(r));
            }
            fragment half4 bk_blur_v_\(i)(BKOut in [[stage_in]], texture2d<half, access::sample> colorSampler [[texture(0)]]) {
                return bk_store_srgb(bk_blur(colorSampler, in.uv, float2(0.0, 1.0), \(r)));
            }

            """
        }
        do { return try device.makeLibrary(source: source.replacingOccurrences(of: "BK_LEVEL_FUNCTIONS", with: fns), options: nil) } catch {
            NSLog("Bukangi blur shader: \(error)")
            return nil
        }
    }()

    /// Level for a blur radius in full-resolution pixels, or nil when no blur is needed.
    static func level(forPixels px: Double) -> Int? {
        if px < levels[0] * 0.8 { return nil }
        var best = 0
        for (i, r) in levels.enumerated() where abs(r - px) < abs(levels[best] - px) { best = i }
        return best
    }

    static func make(level: Int) -> SCNTechnique? {
        guard let lib = library else { return nil }
        let desc: [String: Any] = [
            "passes": [
                "bkScene": [
                    "draw": "DRAW_SCENE",
                    "outputs": ["color": "bkSmall"],
                    "colorStates": ["clear": true, "clearColor": "0 0 0 0"],
                    "depthStates": ["clear": true],
                ],
                "bkBlurH": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "bk_quad",
                    "metalFragmentShader": "bk_blur_h_\(level)",
                    "inputs": ["colorSampler": "bkSmall"],
                    "outputs": ["color": "bkTmp"],
                ],
                "bkBlurV": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "bk_quad",
                    "metalFragmentShader": "bk_blur_v_\(level)",
                    "inputs": ["colorSampler": "bkTmp"],
                    "outputs": ["color": "COLOR"],
                ],
            ],
            "sequence": ["bkScene", "bkBlurH", "bkBlurV"],
            "targets": [
                "bkSmall": ["type": "color"],
                "bkTmp": ["type": "color"],
            ],
        ]
        guard let t = SCNTechnique(dictionary: desc) else { return nil }
        t.library = lib
        return t
    }
}
