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
    float colourPreservation; uint depthProtection; float effectStrength; uint lumaStabilityPercent;
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

// Statistics stay on the low grid and never depend on the reconstructed native
// pixel. Clamp the center first, so repeated border taps use the same cross.
// Only attenuate the existing guarded edit: do not move a neighbor's residual
// into a zero tap or enlarge any tap's interpolation-support budget.
float BaselineWeight(float3 center, float3 neighbor) {
    float3 magnitude = max(max(abs(center), abs(neighbor)), 1e-5);
    float3 relative = abs(center - neighbor) / magnitude;
    return 1.0 - smoothstep(0.15, 0.75, max(relative.r, max(relative.g, relative.b)));
}

float LowDepth(int2 pixel) {
    // Integer nearest-center mapping avoids fractional boundary rounding.
    uint2 full = (uint2(pixel) * 2u + 1u) * uint2(w, h) / (uint2(lowW, lowH) * 2u);
    return depth.Load(int3(min(full, uint2(w - 1, h - 1)), 0));
}

float LumaStabilityWeight(int2 pixel, float3 base, float3 delta) {
    if (any(base < 0.0)) return 1.0;
    pixel = clamp(pixel, int2(0, 0), int2(lowW - 1, lowH - 1));
    float centerB = Luminance(base);
    float centerD = Luminance(clamp(delta, -0.5 * base, 0.5 * base));
    if (!all(isfinite(float2(centerB, centerD)))) return 1.0;
    float centerDepth = 0.0;
    if (depthProtection != 0) {
        centerDepth = LowDepth(pixel);
        if (!isfinite(centerDepth)) return 1.0;
    }
    float sumB = 0.0, sumD = 0.0, sumWeight = 0.0;
    const int2 offsets[4] = {int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1)};
    [unroll] for (int i = 0; i < 4; ++i) {
        int2 neighbor = pixel + offsets[i];
        if (any(neighbor < int2(0, 0)) || any(neighbor >= int2(lowW, lowH))) continue;
        float3 neighborB, neighborD;
        // A malformed extra neighbor cannot invalidate the original four taps.
        if (!LowTap(neighbor, neighborB, neighborD) || any(neighborB < 0.0)) continue;
        float weight = BaselineWeight(base, neighborB);
        if (weight <= 0.0) continue;
        if (depthProtection != 0) {
            float neighborDepth = LowDepth(neighbor);
            if (!isfinite(neighborDepth)) continue;
            float relativeDepth = abs(centerDepth - neighborDepth) /
                max(max(abs(centerDepth), abs(neighborDepth)), 1e-6);
            weight *= 1.0 - smoothstep(0.01, 0.05, relativeDepth);
        }
        if (weight <= 0.0) continue;
        float neighborY = Luminance(neighborB);
        float neighborDY = Luminance(clamp(neighborD, -0.5 * neighborB, 0.5 * neighborB));
        if (!all(isfinite(float2(neighborY, neighborDY)))) continue;
        sumB += weight * neighborY;
        sumD += weight * neighborDY;
        sumWeight += weight;
    }
    if (sumWeight <= 1e-5 || !all(isfinite(float2(sumB, sumD)))) return 1.0;
    float meanB = sumB / sumWeight, meanD = sumD / sumWeight;
    float baselineDetail = centerB - meanB;
    float editedDetail = baselineDetail + (centerD - meanD);
    if (!all(isfinite(float2(baselineDetail, editedDetail)))) return 1.0;
    // Constant edits and edits that cancel baseline detail are retained. Only
    // additional local luminance contrast attenuates the existing correction.
    // This same-frame test cannot stabilize coherent temporal flicker.
    float excess = max(0.0, abs(editedDetail) - abs(baselineDetail)) /
        max(max(abs(centerB), abs(meanB)), 1e-5);
    // Normalized moments alone can give almost-rejected neighbors full power,
    // then abruptly remove that power at the no-support fallback above. Fade
    // rejection with aggregate guide support; one full unit retains the old
    // behavior. This only weakens rejection; the final factor still stays in
    // [0,1] relative to each existing unfiltered guarded edit.
    float guideConfidence = smoothstep(0.0, 1.0, sumWeight);
    return 1.0 - saturate(float(lumaStabilityPercent) * 0.01) *
        guideConfidence * smoothstep(0.02, 0.10, excess);
}

float3 StableGuardTap(int2 pixel, float3 original, float3 base, float3 delta) {
    float3 guarded = GuardTap(original, base, delta);
    if (lumaStabilityPercent == 0 || all(guarded == 0.0)) return guarded;
    return guarded * LumaStabilityWeight(pixel, base, delta);
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
    d00 = StableGuardTap(a, c.rgb, b00, d00);
    d10 = StableGuardTap(a + int2(1, 0), c.rgb, b10, d10);
    d01 = StableGuardTap(a + int2(0, 1), c.rgb, b01, d01);
    d11 = StableGuardTap(a + int2(1, 1), c.rgb, b11, d11);
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
