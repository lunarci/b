// SPDX-License-Identifier: GPL-3.0-only
// Derived from MatheusGViana AmdPreSr.cpp::ResolveShader. See NOTICE.
// All three inputs describe the SAME real frame, in the SAME colour encoding.
// src is native input; baseline is exactly the low-res image supplied to NR;
// edited is the NR result. No previous frame, fake NR or frame generation here.
Texture2D<float4> src : register(t0);
Texture2D<float4> baseline : register(t1);
Texture2D<float4> edited : register(t2);
RWTexture2D<float4> dst : register(u0);
cbuffer Extent : register(b0) { uint w; uint h; uint lowW; uint lowH; };

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

[numthreads(8, 8, 1)]
void MainCS(uint3 p : SV_DispatchThreadID) {
    if (p.x >= w || p.y >= h) return;
    float4 c = src.Load(int3(p.xy, 0));
    if (!all(isfinite(c))) {
        // Only malformed input takes this path; do not amplify NaN/Inf.
        dst[p.xy] = FiniteNative(c);
        return;
    }
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
    float3 d = lerp(lerp(d00, d10, t.x), lerp(d01, d11, t.x), t.y);
    float3 b = lerp(lerp(b00, b10, t.x), lerp(b01, b11, t.x), t.y);
    // Identity is exact for finite inputs, including negative scene-linear RGB.
    // The upstream unconditional final clamp did not preserve that case.
    if (all(d == 0.0)) {
        dst[p.xy] = c;
        return;
    }
    float3 magnitude = max(max(abs(c.rgb), abs(b)), 1e-5);
    float3 relative = abs(c.rgb - b) / magnitude;
    float mismatch = max(relative.r, max(relative.g, relative.b));
    float confidence = 1.0 - smoothstep(0.15, 0.75, mismatch);
    float3 limit = 0.5 * max(abs(b), abs(c.rgb));
    d = clamp(d, -limit, limit) * confidence;
    if (all(d == 0.0)) {
        dst[p.xy] = c;
        return;
    }
    // Match upstream's finite FP16 output bound on an actual edited pixel.
    // Alpha always comes from the current native image, never from NR.
    dst[p.xy] = float4(clamp(c.rgb + d, 0.0, 65504.0), c.a);
}

