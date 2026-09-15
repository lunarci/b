# Matheus NR030 additive adapter — source status

This is an experimental adaptation of the Matheus PreSR downsample/residual
idea. It is not an upstream Matheus release, an official AMD/NVIDIA interface,
or a game-validated replacement runtime. The existing NR ASI, neural model,
OptiScaler and XeFG binaries remain separate. The complete installer preserves
OptiScaler/XeFG binaries and can replace incompatible NR/model files with verified
pinned versions after backup; the adapter does not patch their disk images.

## Exact admission contract

- Windows x64, Direct3D 12 direct command list.
- Loaded `dlssnr_on_amd.asi` must have the exact size, full SHA-256, full helper
  SHA-256 and pristine entry signature in `runtime_contract.h`.
- The helper must lie in a committed, readable executable image section;
  the read-only mode fields must belong to readable image memory.
- The base INI must have `Enabled=1`, `PreUpscale=1`, `Async=0`. Base mode is
  checked without writing any NR or OptiScaler settings.
- The initial experiment admits a single stable FFX context, device and render
  extent. Color, depth and motion active description and allocation extents
  must all equal the render extent. Each resource has one mip, one slice and
  one sample and is in FFX compute-read state.
- Formats: RGBA16F color, R32F depth, RG16F or RGBA16F motion; compatible typeless backing
  allocations are accepted. Display-resolution guide paths are not admitted.
- The descriptor extension chain must be empty. Other FFX calls pass through.

The fixed private helper receives `(original FFX dispatch, context, descriptor)`.
The adapter downsamples the three inputs on the existing command list, passes a
low-resolution descriptor to that helper, and substitutes a synchronous
callback for its original-dispatch argument. The callback uses the helper's
corrected low-resolution color only when it matches the audited contract. It
then records matched-residual reconstruction, restores the entire original FFX
descriptor, replaces only its color resource, and calls the real FFX dispatch
once. Motion conversion and pixel-space jitter each scale once for low NR;
the full-resolution FFX call receives the originals.

## Lifetime and failure behavior

Each lazy slot owns four textures and twenty descriptors. At most eight slots
exist, with a 512 MiB allocation ceiling. A complete slot is budget-checked and
constructed transactionally. A slot retains its command list and borrowed
resource references until a successful command-list Reset seals its recording
and every observed submission/replay has a completed fence from its actual
queue. There is no CPU wait before command-list submission and no frame-count
reuse heuristic. Unknown submission state freezes those resources and stops
new addon admission. Fences alone do not permit reuse.

Since 0.2.2, unsupported or busy admission dispatches the original full
input directly to FFX, omitting NR even before the first low-NR call. This prevents a fallback from
resizing the runtime back to a different extent while low-resolution work can
still be queued. A changed context or extent requires restarting the game to
re-admit this experiment. Scale 100 selected before launch uses original NR
throughout and allocates no addon textures.

Initialization failure stops addon admission permanently. A shader-recording
exception restores the affected addon texture to compute-read state and stops
admission; original game resources are never transitioned by these shaders.
The module, installed hooks and outstanding GPU objects remain pinned until
process exit. No live-unload or live-resolution-change guarantee is provided.

## Build and evidence limits

`NR030_ENABLE_EXPERIMENTAL_RUNTIME` defaults to **OFF**. An OFF build records a
disabled log and installs no hooks. The ON option is an experimental source
build choice; it is not evidence that GPU or game validation succeeded.
`RuntimeContract::StaticAbiVerified` is separate from
`RuntimeContract::RuntimeValidated`, which remains false.

MinHook is pinned to commit
`c3fcafdc10146beb5919319d0683e44e3c30d537`. The ASI embeds four production DXBC
resources (101–104) produced by the shared shader build. The WARP executable
tests the same shader files when run on a suitable Windows build machine.
The sole public export is `InitializeASI`; there is no `PatchResult` export.

The two install payload files are `MatheusNR030.asi` and `MatheusNR030.ini`.
A C++ link-check DLL without these shader resources is **not installable**.
Compilation/linking, static ABI analysis, WARP execution, and actual
RX 9070 XT / Cyberpunk execution are distinct validation stages. None should
be reported as another stage.

The 0.2.0 resolve also reads the already-retained native depth as t3. It adds no
texture or dispatch, and expands only this kernel's b0 from four to eight DWORDs.
ColourPreservationPercent, DepthProtection and EffectPercent are startup-only
settings. At scale 100 the original helper bypass also bypasses these controls.
The log records them in resolve_config; this alone is not execution evidence.

In 0.2.1 Maintain sweeps ALL safe uses before eligibility/context fallbacks.
Only Reusable's existing submitted/fence/Reset proof permits dropping a use.
An unreferenced scratch slot idle for two seconds may be trimmed above a floor
of two allocated slots. No timer retires a GPU recording. DXGI budget samples
are process-wide observations; historical fallback labels are not current state.

The log distinguishes command recording (`nr_recorded`, `resolved`) from
observed fence-and-Reset retirement of resolved slots (`gpu_completed`). Those
counters do not prove neural-model success, visual quality, performance gain,
or XeFG compatibility. `allocated_bytes` and `allocated_slots` expose actual
addon texture usage; the allocation ceiling is not a VRAM-saving promise.

In 0.2.2, RGBA16F motion inputs use their actual typed SRV and only XY is
written to the RG16F low-motion target. Input rejection diagnostics expose both
FFX and actual D3D12 formats. Default residual effect strength is 50 percent;
this reduces the final correction amount and does not reduce inference work.
The complete installer also applies the user-requested OptiScaler ratio 2.0,
backs up changed settings and supports disabling both NR layers together.

In 0.2.3 each low residual is clamped and checked against the current native RGB
before bilinear interpolation. This prevents a small-support finite HDR outlier
from saturating the full blended correction allowance. Depth weight applies once
after interpolation. No motion-reprojected history or temporal filter is added.
Compatible constant HDR fields retain the same effect strength; edge/detail
balance can change and must be compared in game.


0.2.4 uses the final reserved DWORD as a 0..100 same-frame luminance stability
control. The cbuffer remains 32 bytes and binding count stays unchanged. Fixed
low-tap cross statistics estimate added contrast relative to the baseline,
with colour and optional depth guidance, then only attenuate the existing
guarded residual. Zero taps cannot gain a neighbour's correction. This is not
a temporal filter or a material/lighting classifier; valid detail can weaken.
Opposite-sign taps can be attenuated differently, reducing their cancellation:
the per-tap budget is preserved, but final per-pixel correction need not shrink.
