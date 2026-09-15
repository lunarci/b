# Matheus NR030 additive adapter — source status

This is an experimental adaptation of the Matheus PreSR downsample/residual
idea. It is not an upstream Matheus release, an official AMD/NVIDIA interface,
or a game-validated replacement runtime. The existing NR ASI, neural model,
OptiScaler and XeFG binaries remain separate and are not modified on disk.

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
- Formats: RGBA16F color, R32F depth, RG16F motion; compatible typeless backing
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

Before the first low-NR call, unsupported inputs use the original NR helper.
After that call, an unsupported or busy frame dispatches the original full
input directly to FFX, temporarily omitting NR. This prevents a fallback from
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

The log distinguishes command recording (`nr_recorded`, `resolved`) from
observed fence-and-Reset retirement of resolved slots (`gpu_completed`). Those
counters do not prove neural-model success, visual quality, performance gain,
or XeFG compatibility. `allocated_bytes` and `allocated_slots` expose actual
addon texture usage; the allocation ceiling is not a VRAM-saving promise.
