import Foundation

// SPEC §6.2 — the render pipeline's single shader source, compiled at launch with
// `MTLDevice.makeLibrary(source:options:)` (no offline `metal` compiler on this machine, no `.metal` files).
//
// One vertex fn (unit quad expanded from `Uniforms.rectNDC`/`uvRect`, no vertex buffer) and one
// fragment fn switched on `Uniforms.mode`:
//   0 = flat colour
//   1 = 2-stop linear gradient (`color` → `color2`, `gradientAngle` radians)
//   2 = plain texture sample (wallpaper / image backgrounds)
//   3 = rounded-rect texture with soft shadow (the "screen" quad, RGB source) — analytic SDF, no
//       blur pass: `d = length(max(abs(p) - halfSize + r, 0)) - r`; fill alpha =
//       `1 - smoothstep(-1, 1, d)`; shadow alpha = `shadowAlpha * (1 - smoothstep(0, shadowBlur, d))`.
//   4 = same rounded-rect + shadow as mode 3, but the source is biplanar 4:2:0 YCbCr (real capture
//       output — `texture(0)` luma, `texture(1)` chroma) converted to RGB first (BT.709, video range).
// `Uniforms` below must stay byte-layout-identical to the `Uniforms` struct in Compositor.swift.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 rectNDC;        // left, top, right, bottom in clip space (mix handles either order)
    float4 uvRect;         // u0, v0, u1, v1 (may extrapolate outside 0…1 — see mode 3)
    float4 color;          // mode 0/1: fill / gradient stop 0
    float4 color2;         // mode 1: gradient stop 1
    float2 pixelSize;      // on-screen size of the quad, in pixels (for vertexMain's localPos)
    float2 contentSize;    // mode 3: the rounded content rect's size, in pixels (for the SDF)
    float2 contentOffset;  // mode 3: content rect centre, relative to the quad's centre, in pixels
    float radius;          // corner radius, pixels
    float shadowAlpha;
    float shadowBlur;      // pixels
    float gradientAngle;   // radians
    int mode;
    float _pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float2 localPos;   // position within the quad in pixels, centred at (0,0)
};

vertex VertexOut vertexMain(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    VertexOut out;
    out.position = float4(mix(u.rectNDC.x, u.rectNDC.z, c.x), mix(u.rectNDC.y, u.rectNDC.w, c.y), 0, 1);
    out.uv = float2(mix(u.uvRect.x, u.uvRect.z, c.x), mix(u.uvRect.y, u.uvRect.w, c.y));
    out.localPos = (c - 0.5) * u.pixelSize;
    return out;
}

// Mode 3/4 shared SDF: quad spans the whole output (not just the content rect) so the shadow can
// bleed into the padding; the SDF is evaluated against the content rect, offset from the quad centre.
float4 roundedRectShadow(float2 localPos, constant Uniforms &u, float4 texColor) {
    float2 halfSize = u.contentSize * 0.5;
    float2 p = localPos - u.contentOffset;
    float2 q = abs(p) - halfSize + u.radius;
    float d = length(max(q, 0.0)) - u.radius;
    float fillAlpha = 1.0 - smoothstep(-1.0, 1.0, d);
    float shadowAlpha = u.shadowAlpha * (1.0 - smoothstep(0.0, max(u.shadowBlur, 0.001), d));
    float4 shadowColor = float4(0.0, 0.0, 0.0, shadowAlpha);
    float4 result = mix(shadowColor, float4(texColor.rgb, 1.0), fillAlpha);
    result.a = max(fillAlpha, shadowAlpha);
    return result;
}

// BT.709, video range (luma 16…235, chroma 16…240 of 255) biplanar YCbCr → RGB.
float3 ycbcr709VideoToRGB(float y, float2 cbcr) {
    float yy = (y - 16.0 / 255.0) * (255.0 / 219.0);
    float cb = (cbcr.x - 128.0 / 255.0) * (255.0 / 224.0);
    float cr = (cbcr.y - 128.0 / 255.0) * (255.0 / 224.0);
    float r = yy + 1.5748 * cr;
    float g = yy - 0.1873 * cb - 0.4681 * cr;
    float b = yy + 1.8556 * cb;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]],
                              texture2d<float> texChroma [[texture(1)]],
                              sampler smp [[sampler(0)]]) {
    if (u.mode == 0) {
        return u.color;
    } else if (u.mode == 1) {
        float2 dir = float2(cos(u.gradientAngle), sin(u.gradientAngle));
        float t = clamp(dot(in.uv - 0.5, dir) + 0.5, 0.0, 1.0);
        return mix(u.color, u.color2, t);
    } else if (u.mode == 2) {
        return tex.sample(smp, in.uv);
    } else if (u.mode == 3) {
        return roundedRectShadow(in.localPos, u, tex.sample(smp, in.uv));
    } else {
        float y = tex.sample(smp, in.uv).r;
        float2 cbcr = texChroma.sample(smp, in.uv).rg;
        float3 rgb = ycbcr709VideoToRGB(y, cbcr);
        return roundedRectShadow(in.localPos, u, float4(rgb, 1.0));
    }
}
"""
