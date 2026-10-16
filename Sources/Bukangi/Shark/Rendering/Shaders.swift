import SceneKit

/// Shader modifiers for the shark materials and her shadow.
enum Shaders {
    static let shadow = """
    #pragma arguments
    float shadowAlpha;
    float shadowSoft;
    #pragma transparent
    #pragma body
    float nz = abs(_surface.normal.z);
    float a = pow(smoothstep(0.0, mix(0.3, 1.0, shadowSoft), nz), 1.0 + shadowSoft) * shadowAlpha;
    _output.color = float4(0.0, 0.0, 0.0, a);
    """

    static let skin: [SCNShaderModifierEntryPoint: String] = [
        .surface: """
        #pragma arguments
        float causticStrength;
        #pragma body
        float2 p = fmod(_surface.position.xy * 0.026, 6.2831853) - 250.0;
        float tm = scn_frame.time * 0.42 + 23.0;
        float2 i = p;
        float c = 1.0;
        float inten = 0.005;
        for (int n = 0; n < 5; n++) {
            float t = tm * (1.0 - (3.5 / float(n + 1)));
            i = p + float2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
            c += 1.0 / length(float2(p.x / (sin(i.x + t) / inten), p.y / (cos(i.y + t) / inten)));
        }
        c /= 5.0;
        c = 1.17 - pow(c, 1.4);
        float craw = pow(abs(c), 8.0);
        float caustic = clamp((craw - 0.25) / 0.25, 0.0, 1.0);
        caustic = caustic * caustic * (3.0 - 2.0 * caustic) * 0.14;
        float facing = clamp(_surface.normal.z, 0.0, 1.0);
        _surface.diffuse.rgb += caustic * causticStrength * facing * float3(0.70, 0.88, 0.90);
        """,
        .fragment: """
        #pragma arguments
        float tintHead;
        float tintTail;
        float4 tintAxis;
        #pragma body
        // A light illustrated look: soft tonal bands.
        float3 ilCol = _output.color.rgb;
        float ilA = _output.color.a;
        float ilLum = dot(ilCol, float3(0.299, 0.587, 0.114));
        float ilX = ilLum * 4.0;
        float ilQ = (floor(ilX) + smoothstep(0.3, 0.7, fract(ilX))) / 4.0;
        float ilS = mix(ilLum, ilQ, 0.35);
        ilCol *= (ilS + 0.03) / (ilLum + 0.03);
        float ilNz = abs(_surface.normal.z);
        // Velvety glow toward the edges, with only a faint soft outline right at the silhouette.
        float ilSheen = 1.0 - smoothstep(0.15, 0.75, ilNz);
        ilCol = mix(ilCol, float3(0.86, 0.90, 0.98) * ilA, ilSheen * 0.22);
        float ilRim = 1.0 - smoothstep(0.04, 0.22, ilNz);
        ilCol = mix(ilCol, float3(0.20, 0.25, 0.38) * ilA, ilRim * 0.35);
        float3 ilWater = float3(0.13, 0.33, 0.36);
        // tintAxis = head.xy, tail.xy in screen points.
        float2 ilWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xy;
        float2 ilBody = tintAxis.zw - tintAxis.xy;
        float ilT = clamp(dot(ilWorld - tintAxis.xy, ilBody) / max(dot(ilBody, ilBody), 1.0), 0.0, 1.0);
        _output.color.rgb = mix(ilCol, ilWater * ilA, mix(tintHead, tintTail, ilT));
        """,
    ]
}
