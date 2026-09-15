// SPDX-License-Identifier: GPL-3.0-only
// Derived from MatheusGViana AmdPreSr.cpp::MotionShader. See NOTICE.
// Only grid positions change. Raw vector values are preserved.
// Convert units once at NR invocation with component_contract.h; no double scale.
Texture2D<float2> src : register(t0);
RWTexture2D<float2> dst : register(u0);
cbuffer Extent : register(b0) { uint w; uint h; uint sourceW; uint sourceH; };
[numthreads(8, 8, 1)]
void MainCS(uint3 p : SV_DispatchThreadID) {
    if (p.x >= w || p.y >= h) return;
    uint2 q = min(uint2((float2(p.xy) + 0.5) * float2(sourceW, sourceH) / float2(w, h)),
                  uint2(sourceW - 1, sourceH - 1));
    dst[p.xy] = src.Load(int3(q, 0));
}

