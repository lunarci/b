# Matheus-style NR scaling adapter for the exact NR 0.3.0 C7 build

**Experimental adapter, version 0.2.2 Complete. Install only a successfully built installation package. Actual AMD/Cyberpunk execution remains unverified.**

0.2.2 fixes a confirmed admission mismatch: the earlier user log contains
RGBA16F motion vectors, while 0.2.1 only admitted RG16F. Both formats now use
their matching SRV and retain XY motion. Rejected 75/85-percent work goes
directly to FFX without running full-size NR. The explicit 100-percent mode
still exercises original NR. Default effect strength is now 50 percent for
visual comparison; this is not a measured quality improvement. The complete
installer downloads missing pinned NR/model files, preserves the working
OptiScaler/XeFG setup, and provides a separate disable-NR recovery action.
See package/README_KO.md. Branch: `nr030-complete-install`.

InstallFix1 makes the legacy base-installation JSON optional. The installed C7
NR hash and existing INI settings remain mandatory compatibility checks; an
existing legacy record is validated and preserved. The add-on's own ownership
record is still required to update/remove existing add-on files. This was the
installer-only revision on `nr030-install-record-fix`.

0.2.1 sweeps all proven-complete recording uses before admission/fallback, trims
extra scratch slots idle for two seconds (two retained), and records read-only
DXGI process memory observations. See MAP_RECOVERY_KO.md. This corrects a retained
resource path; it does not establish actual recovery of game FPS after the map.

This revision adds original-colour luminance transfer adapted from matiasLombo
and a spatial depth-edge guard adapted from Yuri in the existing Matheus resolve
pass. Both can be disabled independently. See `COMPARISON_KO.md` for the pinned
source comparison, limitations and A/B controls. The comparison branch is
`nr030-combined-color`; the original 0.1.0 branch is retained.

This additive adapter is intended for an existing AMD NR 0.3.0 + OptiScaler FSR + Intel XeFG 4X configuration. It derives area downsampling and matched residual reconstruction from MatheusGViana's AMD PreSR source. Existing engine, model and frame-generation binaries/settings are preserved by the installer.

The prototype uses a hash-locked internal FFX helper in the exact C7 NR binary. It downsamples color/depth/motion inputs for NR, reconstructs NR's change at the original game input size, and calls the existing FFX upscaler. It does not introduce NVIDIA DLSS 5 support or replace the AMD inference backend. See `runtime_static_evidence.md` and `runtime_contract.h` for the limited static ABI evidence.

The CMake option defaults to `NR030_ENABLE_EXPERIMENTAL_RUNTIME=OFF`; the experimental packaging workflow explicitly builds it ON. Enabling the INI cannot override that compile-time setting. Four production DXBC shaders must be compiled on Windows and embedded as RCDATA resources 101–104. The shader test target and addon use the same generated files.

## Current validation

- Portable C++ component/math tests pass.
- Windows x64 cross-compilation and link checks are possible locally; see the distributed kit's exact evidence for the checked source snapshot.
- The initial 21 installer fixtures passed on Windows PowerShell 5.1; subsequent metadata checks are included in the same gate for final packaging. Exact counts are in package evidence.
- Initial Windows CI run 34928657594 passed MSVC build, Microsoft shader compilation, shared-production WARP tests and Windows PowerShell 5.1 fixtures. The enabled installation package adds an actual-ASl loader/resource smoke gate; its immutable build evidence is included with the package.
- No AMD GPU inference, Cyberpunk gameplay, image quality or FPS validation has completed.
- Public GitHub publication and Actions were explicitly approved by the user. The separate branch is `nr030-matheus-presr`; the existing ArchiveXL main branch is unchanged.

## Build

On Windows with Visual Studio 2022 C++ x64 tools, CMake and Git, run `tools/Build-Local.ps1`. This builds the disabled developer adapter and runs CTest/WARP plus Windows PowerShell 5.1 package fixtures. It creates no game installation. The separate `tools/Build-Package.ps1` refuses packaging unless explicit experimental review, enabled-build metadata and Windows validation evidence are supplied.

Only `nr030-matheus/**` and `.github/workflows/build-matheus-nr030.yml` are new repository paths. Keep ArchiveXL files and its existing workflow unchanged.

## Limitations that must remain visible

The initial adapter admits one context/device/extent, direct command lists, RGBA16F color and render-sized depth/motion guides. Resource slots require both observed queue fences and successful Reset before reuse. Since 0.2.2, unsupported/busy admission bypasses NR from the first call and call the original FFX dispatch directly to avoid reshaping in-flight NR resources. Such frames must not be counted as successful NR acceleration. The pool holds at most eight slots under a 512 MiB texture-allocation budget; this is additional GPU memory, independent of the base runtime.

`nr_recorded` and `resolved` mean command recording. `gpu_completed` means resource-slot retirement after observed GPU completion and Reset. None proves inference correctness, visual quality, or speedup. See the package README for restart-only 75/85/100 scale changes and removal ownership.

## Source and licenses

See `components/NOTICE` for pinned Matheus source attribution and GPL-3.0-only terms. See `third_party/NOTICE.md` for exact AMD FidelityFX MIT and MinHook/HDE notices. The original NR runtime and model are not redistributed.

The complete installer explicitly applies the requested global OptiScaler upscale
ratio 2.0 and disables per-preset ratio override, backing up both ARK and existing
overwrite settings. The NR-off comparison keeps that ratio. Base restoration
removes the addon and restores the recorded NR/model/settings changes; it does
not automatically reinstall a previous addon version.
