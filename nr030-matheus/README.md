# Matheus-style NR scaling adapter for the exact NR 0.3.0 C7 build

**Source review kit, version 0.1.0. Not an installable or game-validated release.**

This additive adapter is intended for an existing AMD NR 0.3.0 + OptiScaler FSR + Intel XeFG 4X configuration. It derives area downsampling and matched residual reconstruction from MatheusGViana's AMD PreSR source. Existing engine, model and frame-generation binaries/settings are preserved by the installer.

The prototype uses a hash-locked internal FFX helper in the exact C7 NR binary. It downsamples color/depth/motion inputs for NR, reconstructs NR's change at the original game input size, and calls the existing FFX upscaler. It does not introduce NVIDIA DLSS 5 support or replace the AMD inference backend. See `runtime_static_evidence.md` and `runtime_contract.h` for the limited static ABI evidence.

The Windows runtime integration defaults to `NR030_ENABLE_EXPERIMENTAL_RUNTIME=OFF`. Enabling the INI cannot override that compile-time setting. Four production DXBC shaders must be compiled on Windows and embedded as RCDATA resources 101–104. The shader test target and addon use the same generated files.

## Current validation

- Portable C++ component/math tests pass.
- Windows x64 cross-compilation and link checks are possible locally; see the distributed kit's exact evidence for the checked source snapshot.
- Installer synthetic tests: 21 pass on PowerShell 7.6.6/Linux. This is not Windows PowerShell 5.1 validation.
- No Windows MSVC build, Microsoft shader compilation, Windows WARP execution, AMD GPU inference, Cyberpunk gameplay, image quality or FPS validation has completed.
- Public GitHub publication/Actions is blocked pending explicit destination/publication approval. The existing ArchiveXL main branch is unchanged.

## Build

On Windows with Visual Studio 2022 C++ x64 tools, CMake and Git, run `tools/Build-Local.ps1`. This builds the disabled developer adapter and runs CTest/WARP plus Windows PowerShell 5.1 package fixtures. It creates no game installation. The separate `tools/Build-Package.ps1` refuses packaging unless explicit experimental review, enabled-build metadata and Windows validation evidence are supplied.

Only `nr030-matheus/**` and `.github/workflows/build-matheus-nr030.yml` are new repository paths. Keep ArchiveXL files and its existing workflow unchanged.

## Limitations that must remain visible

The initial adapter admits one context/device/extent, direct command lists, RGBA16F color and render-sized depth/motion guides. Resource slots require both observed queue fences and successful Reset before reuse. After scaled NR begins, unsupported/busy frames bypass NR and call the original FFX dispatch directly to avoid reshaping in-flight NR resources. Such frames must not be counted as successful NR acceleration. The pool holds at most eight slots under a 512 MiB texture-allocation budget; this is additional GPU memory, independent of the base runtime.

`nr_recorded` and `resolved` mean command recording. `gpu_completed` means resource-slot retirement after observed GPU completion and Reset. None proves inference correctness, visual quality, or speedup. See the package README for restart-only 75/85/100 scale changes and removal ownership.

## Source and licenses

See `components/NOTICE` for pinned Matheus source attribution and GPL-3.0-only terms. See `third_party/NOTICE.md` for exact AMD FidelityFX MIT and MinHook/HDE notices. The original NR runtime and model are not redistributed.
