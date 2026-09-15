// SPDX-License-Identifier: GPL-3.0-only
// Derived from MatheusGViana AmdPreSr.cpp::ResolveShader. See NOTICE.
// Luminance transfer adapted from matiasLombo/neural-upstream RestoreRange;
// depth protection adapted from Yuri's ScaledDepthWeight. See NOTICE.
// All three inputs describe the SAME real frame, in the SAME colour encoding.
// src is native input; baseline is exactly the low-res image supplied to NR;
// edited is the NR result. No previous frame, fake NR or frame generation here.
Texture2D<float4> src : register(t0);
Texture2D<float4> baseline : register(t1);
Texture2D<float4> edited : register(t2);
Texture2D<float> depth : register(t3);
RWTexture2D<float4> dst : register(u0);
cbuffer Extent : register(b0) {
    uint w; uint h; uint lowW; uint lowH;
    float colourPreservation; uint depthProtection; float effectStrength; uint reserved;
};

float Luminance(float3 value) { return dot(value, float3(0.2126, 0.7152, 0.0722)); }

// Same-frame raw-depth heuristic, not temporal reprojection or linear depth.
// Keep Yuri's 25% floor at finite discontinuities. Invalid depth rejects the
// effect for this pixel. No additional texture allocation or dispatch is needed.
float DepthWeight(uint2 pixel) {
    if (depthProtection == 0) return 1.0;
    int2 p = int2(pixel), bound = int2(w - 1, h - 1);
    float center = depth.Load(int3(p, 0));
    if (!isfinite(center)) return 0.0;
    float lo = center, hi = center;
    const int2 offsets[4] = {int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1)};
    [unroll] for (int i = 0; i < 4; ++i) {
        float value = depth.Load(int3(clamp(p + offsets[i], int2(0, 0), bound), 0));
        if (!isfinite(value)) return 0.0;
        lo = min(lo, value); hi = max(hi, value);
    }
    float relativeRange = (hi - lo) / max(abs(center), 1e-6);
    return lerp(0.25, 1.0, saturate(1.0 - (relativeRange - 0.02) * 20.0));
}

// AMD's helper supplies already-restored colour, not neural-upstream's bounded
// sRGB proxy. Adapt the luminance-transfer principle in the SAME input encoding;
// do not import the encode/decode pair or guess exposure here.
float3 TransferColour(float3 original, float3 delta) {
    float3 legacy = clamp(original + delta, 0.0, 65504.0);
    if (colourPreservation <= 0.0) return legacy;
    float oy = Luminance(original);
    if (any(original < 0.0) || oy <= 1e-5) return original;
    float ny = Luminance(max(original + delta, 0.0));
    float gain = clamp(ny / oy, 0.125, 8.0);
    // One shared gain cap preserves RGB ratios at the FP16 ceiling too.
    gain = min(gain, 65504.0 / max(max(original.r, original.g), max(original.b, 1e-5)));
    if (colourPreservation >= 1.0) return original * gain;
    return lerp(legacy, original * gain, saturate(colourPreservation));
}

float FiniteOrZero(float value) { return isfinite(value) ? value : 0.0; }
float4 FiniteNative(float4 value) {
    return float4(FiniteOrZero(value.r), FiniteOrZero(value.g),
                  FiniteOrZero(value.b), FiniteOrZero(value.a));
}
bool LowTap(int2 p, out float3 b, out float3 d) {
    p = clamp(p, int2(0, 0), int2(lowW - 1, lowH - 1));
    b = baseline.Load(int3(p, 0)).rgb;
    float3 e = edited.Load(int3(p, 0)).rgb;
    d = e - b;
    return all(isfinite(b)) && all(isfinite(e)) && all(isfinite(d));
}

float3 GuardTap(float3 original, float3 base, float3 delta) {
    float3 magnitude = max(max(abs(original), abs(base)), 1e-5);
    float3 relative = abs(original - base) / magnitude;
    float mismatch = max(relative.r, max(relative.g, relative.b));
    float confidence = 1.0 - smoothstep(0.15, 0.75, mismatch);
    float3 limit = 0.5 * max(abs(base), abs(original));
    return clamp(delta, -limit, limit) * confidence;
}

[numthreads(8, 8, 1)]
void MainCS(uint3 p : SV_DispatchThreadID) {
    if (p.x >= w || p.y >= h) return;
    float4 c = src.Load(int3(p.xy, 0));
    if (!all(isfinite(c))) {
        // Only malformed input takes this path; do not amplify NaN/Inf.
        dst[p.xy] = FiniteNative(c);
        return;
    }
    if (effectStrength <= 0.0) { dst[p.xy] = c; return; }
    float2 q = (float2(p.xy) + 0.5) * float2(lowW, lowH) / float2(w, h) - 0.5;
    int2 a = int2(floor(q));
    float2 t = frac(q);
    float3 b00, b10, b01, b11, d00, d10, d01, d11;
    bool ok00 = LowTap(a, b00, d00);
    bool ok10 = LowTap(a + int2(1, 0), b10, d10);
    bool ok01 = LowTap(a + int2(0, 1), b01, d01);
    bool ok11 = LowTap(a + int2(1, 1), b11, d11);
    if (!(ok00 && ok10 && ok01 && ok11)) {
        dst[p.xy] = c;
        return;
    }
    // Limit each tap BEFORE reconstruction: a saturated HDR outlier with 2.5%
    // interpolation support must not spend the whole output pixel's edit budget.
    // Match each baseline separately too; averaging dissimilar taps can create
    // a false match. This is spatial protection, not temporal NR stabilization.
    d00 = GuardTap(c.rgb, b00, d00);
    d10 = GuardTap(c.rgb, b10, d10);
    d01 = GuardTap(c.rgb, b01, d01);
    d11 = GuardTap(c.rgb, b11, d11);
    float3 d = lerp(lerp(d00, d10, t.x), lerp(d01, d11, t.x), t.y);
    // Identity is exact for finite inputs, including negative scene-linear RGB.
    // The upstream unconditional final clamp did not preserve that case.
    if (all(d == 0.0)) {
        dst[p.xy] = c;
        return;
    }
    d *= DepthWeight(p.xy);
    if (all(d == 0.0)) {
        dst[p.xy] = c;
        return;
    }
    // Match upstream's finite FP16 output bound on an actual edited pixel.
    // Alpha always comes from the current native image, never from NR.
    float3 result = TransferColour(c.rgb, d);
    if (effectStrength < 1.0) result = lerp(c.rgb, result, saturate(effectStrength));
    dst[p.xy] = float4(result, c.a);
}
