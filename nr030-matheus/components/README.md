# Matheus pre-SR GPU components

These are extracted image-processing components. They are **not an NR plugin,
a Daniel 0.3.0 adapter, an OptiScaler replacement or a frame-generation change**.

The exact upstream revision and GPLv3 attribution are in NOTICE and LICENSE.
Only CopyShader, ResolveShader, DepthShader and MotionShader are included.
No inference implementation or runtime-memory patching is present.

## Public interface

- component_contract.h: portable C++17 scale/guide contracts.
- shaders/area_downsample.hlsl: exact source-pixel footprint integration.
- shaders/matched_residual_resolve.hlsl: native + bounded low-resolution edit.
- shaders/depth_nearest.hlsl: nearest-centre depth sampling.
- shaders/motion_nearest.hlsl: nearest-centre raw motion sampling.
- Every shader: MainCS, cs_5_0, 8 x 8 threads.
- CMake targets: matheus030_component_contract (INTERFACE),
  nr_component_math_checks, and on Windows compile_nr_components /
  nr_component_shaders.

| Pass | t0 | t1 | t2 | t3 | u0 | b0 |
|---|---|---|---|---|---|---|
| Area copy | source colour float4 | unused | unused | unused | low colour float4 | low W,H, source W,H |
| Resolve | native colour float4 | exact NR low input float4 | low NR output float4 | native depth float | native-size colour float4 | native W,H, low W,H, colour float, depth uint, effect float, padding uint |
| Depth | source depth float | unused | unused | unused | low depth float | low W,H, active depth W,H |
| Motion | source motion float2 | unused | unused | unused | low raw motion float2 | low W,H, active motion W,H |

Resolve b0 is 32 bytes; the other three are 16. Default controls enable original
RGB ratio preservation and Yuri's spatial depth guard. See COMPARISON_KO.md in
the enclosing project for scope and A/B settings. No second colour codec is used.

Use typed views: RGBA16F for real colour textures, R32_FLOAT for prepared depth,
RG16_FLOAT or RG32_FLOAT for prepared motion. RGBA32_FLOAT is acceptable for
isolated numerical testing but is not an assertion that the NR backend accepts
it. Always validate format support and active extents before recording commands.

## Host contract

1. Capture one REAL game frame before its FSR upscale. This component does not
   decide which call represents a real frame and must not process generated
   frames. Preserve the original game input separately.
2. Choose one fixed scale (100%, 85%, 75%). make_scale_plan follows Matheus'
   positive rounding and minimum dimension. It is a texture plan, **not a model
   shape validator**. A particular runtime may require alignment/other limits.
3. At 100%, bypass the new scale/resolve components and use the existing NR path.
   This means unchanged existing NR behaviour, not disabling NR.
4. When scaled, area-copy the colour, preserve that exact low input as baseline,
   and prepare guides on the SAME neural grid. The NR input and output must
   have matching dimensions and correspond to the SAME current frame.
5. Run the existing NR backend once through its independently verified adapter.
   Resolve only after confirmed completion/resource ordering. A timeout or
   failed evaluation must use the current original input, never a stale result.
6. Native, low baseline and low edited input to resolve must share a colour
   encoding, exposure and alpha convention. These shaders neither tonemap nor
   convert HDR10 PQ/scRGB. If an adapter changes colour encoding, normalize
   it BEFORE this resolve; do not subtract incompatible encodings.
7. Return a native-input-sized result to the ORIGINAL FSR evaluation. Do not
   replace game render dimensions, change the FG multiplier or reconfigure XeFG.
8. Inputs and UAV output must be separate resources/subresources. The area pass
   and neighbourhood-based resolve are not safe in-place. Transition all
   resources and order UAV writes before SRV reads.
9. All texture lifetimes and descriptors are owned by the caller until every
   submitting GPU queue has completed. There is no fixed-frame retirement rule
   and no hidden CPU wait in this component.
10. Every view addresses an active rectangle beginning at (0,0). If the game
    supplies nonzero subrect origins, crop/prep the active view explicitly first.
    Do not silently treat full allocation dimensions as active dimensions.
11. Finite RGBA16F colour is the normal input contract. A zero edit preserves
    native RGBA exactly, including negative finite RGB. With a nonzero accepted
    edit, RGB follows upstream clamp [0,65504]; alpha remains the native alpha.
    Invalid low RGB falls back per-pixel to the finite native pixel. Invalid
    native components fall back to zero individually. The host should detect
    gross malformed inputs and bypass the whole effect, rather than use this
    local last-resort guard as normal processing.
12. Depth uses nearest sampling, preserving forward/reversed-Z values; it is not
    an averaged surface or a nearest-depth dilation. Invalid/non-finite guide
    values must be rejected/prepared according to the adapter's documented
    convention. No guessed far-plane value is invented here.

## Motion contract: scaling exactly once

The motion shader changes SAMPLE POSITIONS, not stored vector values.

neural_motion_multiplier takes the active source guide dimensions and an
explicit stored-vector-to-source-guide-pixels multiplier. It returns that
multiplier times neural/source size per axis. Apply it **once at the NR call**.

Examples for a 2560 x 1440 motion grid and 1920 x 1080 neural grid:

- Stored vector is source-grid pixels: input factors (1,1), resulting factors
  (0.75,0.75). Stored motion (16,-8) becomes neural motion (12,-6).
- Stored vector is normalized UV: input factors (2560,1440), resulting factors
  (1920,1080). Stored (0.01,0.01) becomes (19.2,10.8) neural pixels.
- Sign/direction, jitter inclusion/removal and display-pixel versus render-pixel
  units belong to the host API contract. Do not guess these from texture size.
  Do not treat an arbitrary FFX/NGX motionVectorScale field as our explicit
  source-pixel conversion without verifying that API's semantics.
- If a prep shader already scales the stored values, do not apply this helper
  as well. That would scale twice and create temporal misalignment.

## Validation status

Portable math checks validate fixed dimensions, rejected configurations, motion
unit conversion and fractional area coverage/conservation. They do not invoke
the shader or any neural network. A passing build is not Radeon or game proof.

On Windows, CMake builds compile_nr_components, which uses D3DCompileFromFile
with strict IEEE behaviour and warnings-as-errors to compile all four shaders.
The separate native GPU executor owned by the integration team must execute
actual compute dispatches and inspect readback (see GPU_VALIDATION.md).

Example portable build inside this directory:

    g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I. tests/math_checks.cpp -o build/math_checks
    build/math_checks

Example Windows CMake:

    cmake -S . -B build
    cmake --build build --config Release
    ctest --test-dir build -C Release --output-on-failure

Do not present this package as a working in-game 0.3.0 integration until the
actual wrapper, native GPU tests and RX9070XT in-game gates have passed.
