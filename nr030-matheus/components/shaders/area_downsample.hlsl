// SPDX-License-Identifier: GPL-3.0-only
// Derived from MatheusGViana AmdPreSr.cpp::CopyShader. See NOTICE.
// Source and destination must be distinct views; active origin is (0,0).
Texture2D<float4> src : register(t0);
RWTexture2D<float4> dst : register(u0);
cbuffer Extent : register(b0) { uint w; uint h; uint sourceW; uint sourceH; };

[numthreads(8, 8, 1)]
void MainCS(uint3 p : SV_DispatchThreadID) {
    if (p.x >= w || p.y >= h) return;
    if (w == sourceW && h == sourceH) {
        dst[p.xy] = src.Load(int3(p.xy, 0));
        return;
    }
    float2 lo = float2(p.xy) * float2(sourceW, sourceH) / float2(w, h);
    float2 hi = float2(p.xy + 1) * float2(sourceW, sourceH) / float2(w, h);
    int2 first = int2(floor(lo));
    float4 sum = 0.0;
    float total = 0.0;
    [loop] for (int y = first.y; y < int(ceil(hi.y)); ++y) {
        [loop] for (int x = first.x; x < int(ceil(hi.x)); ++x) {
            float2 coverage = max(0.0, min(hi, float2(x + 1, y + 1)) -
                                       max(lo, float2(x, y)));
            float weight = coverage.x * coverage.y;
            int2 q = clamp(int2(x, y), int2(0, 0), int2(sourceW - 1, sourceH - 1));
            sum += src.Load(int3(q, 0)) * weight;
            total += weight;
        }
    }
    // Finite RGBA16F input yields a finite convex average, including alpha.
    dst[p.xy] = sum / max(total, 1e-6);
}

