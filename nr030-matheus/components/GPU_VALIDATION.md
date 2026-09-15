# Native GPU validation requirements

The portable checks prove only host math. Native tests must compile the exact
shaders in this directory, dispatch them on D3D12 and compare fence-completed
readback. They must never substitute a mock NR implementation and report it as
a successful network evaluation.

## Compiler and device gates

- Compile MainCS in all four files with the Windows D3D compiler, cs_5_0,
  strictness, IEEE strictness and warnings-as-errors.
- D3D12 debug layer plus GPU validation where available; reject warning/error
  messages about descriptor, state, format or lifetime violations.
- First run on WARP to validate actual bytecode/dispatch/readback semantics.
  WARP success does not establish AMD driver or HIP interoperability.
- Repeat essential tests on the physical RX9070XT, using actual RGBA16F/R32F/
  RG16F views and noninteger dimensions.
- Track submission fences before readback, resource release and descriptor reuse.

## Required numerical cases

| Case | GPU input and expected result |
|---|---|
| Identity 1.0 | area source/destination same odd extent. Exact finite RGBA, including negative RGB and alpha, retained after identical-format roundtrip |
| 75% dimensions | host input 2560x1440 ->1920x1080; 1921x1081 ->1441x811. The component does not silently round to even dimensions |
| 85% dimensions | 2560x1440 ->2176x1224; 1921x1081 ->1633x919 |
| Fractional footprint | small odd rectangles e.g. 9x7->7x5 and 17x11->13x8. Compare analytical overlap integral, especially last row/column |
| Narrow emissive line | one bright right-edge or bottom-edge pixel line. Weighted total energy retained; a bilinear-centre-only implementation must fail this case |
| Constant HDR | uniform finite RGBA at ordinary and >1 luminance values remains uniform; no tonemapping is introduced |
| Zero residual | low edited==low baseline; spatially varying native texture must survive exactly, not blur. Include negative RGB and changing alpha |
| Nonzero residual | constant compatible native/baseline with known low edit; expected native plus edit, capped by upstream residual limit |
| Confidence rejection | strong source/baseline discrepancy suppresses edit; zero accepted edit returns native, including negative RGB |
| HDR clamp | accepted positive edit near FP16 max clamps to65504; negative accepted RGB clips0; alpha unchanged. Test against identity exception |
| Invalid low result | NaN/+Inf/-Inf in any contributing low RGB tap returns finite current native pixel; no nonfinite output propagates |
| Invalid native | only malformed nonfinite native components become0; finite components remain. This is a fallback test, not valid runtime behaviour |
| Depth convention | nearest-centre sampling preserves supplied forward and reversed depth exactly; no averaging and no unrequested inversion |
| Motion raw values | position sampling changes, raw signed RG vectors do not. Check 75/85% odd extents and border sampling |
| Motion invocation factor | stored pixel and normalized-UV contracts produce expected neural-pixel displacement after one multiplier; double scaling must fail |
| Extent guards | dispatch ceil dimensions must not write outside logical output. Use nonmultiples of8 and readback sentinels/debug validation |

RGBA32F scalar-comparison tolerance should account for IEEE float rounding.
RGBA16F checks must compare against an FP16-rounded reference, not an impossible
full-float exact result. Identity and alpha equality should be exact for finite
values already representable in the chosen texture format.

## Runtime and game gates outside this component

Before enabling this on a real game, prove the Daniel0.3 adapter supplies actual
NR output and the correct input colour, depth, motion, subrect and exposure
contracts. No static shader test proves these facts.

Perform same-scene comparisons with fixed game render resolution and FSR mode:

- Scale1.0 with the new component bypassed must match the current NR0.3 path.
- Compare .85/.75 while game resolution, HDR, NR controls and XeFG4X remain fixed.
- Capture actual rendered frame time, generated display rate, NR GPU/compute
  timing and VRAM separately. Do not treat displayed FPS divided by4 as a proven
  real-frame measurement when pacing/drops are present.
- Inspect camera pans, thin neon lines, wire fences, vehicle silhouettes, hair,
  transparencies, character motion and newly uncovered surfaces.
- Exercise map/menu transitions, alt-tab and resolution change; reset or pause
  NR correctly and never resolve a previous frame after timeout.
- A GPU stall, failed evaluate, nonfinite output, descriptor validation error,
  new temporal trail or sustained VRAM growth fails acceptance.

Earlier1440p45ms and1080p26ms logs are separate sessions and are not an A/B
benchmark for this component. Game1440p+NR1080p may recover game detail relative
to game1080p+NR1080p, but is not an automatic speed improvement over that current
1080p baseline.

