# Third-party attribution

The project combines GPL-3.0-only Matheus-derived shader adaptations with the following independently licensed interfaces and hook dependency. Their original notices are preserved in this directory.

## AMD FidelityFX interface declarations

- Upstream: GPUOpen-LibrariesAndSDKs/FidelityFX-SDK
- Commit: 60f4ea81909200d8542eca14dccb2628b763a9a3 (FidelityFX upscaler API 4.1.1)
- Source: https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/60f4ea81909200d8542eca14dccb2628b763a9a3/Kits/FidelityFX/api/include/ffx_api_types.h
- Source: https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/60f4ea81909200d8542eca14dccb2628b763a9a3/Kits/FidelityFX/upscalers/include/ffx_upscale.h
- Local adaptation: addon/ffx_contract.h uses a narrow namespaced subset of the public data layout. Exact C7 binary offsets are separately verified; they are not an AMD compatibility guarantee.
- License: MIT; the original commented notice is preserved verbatim in AMD_FidelityFX_LICENSE.txt.
- Copyright: (C) 2026 Advanced Micro Devices, Inc.

## MinHook and included HDE components

- Upstream: TsudaKageyu/minhook
- Version: v1.3.4
- Commit: c3fcafdc10146beb5919319d0683e44e3c30d537
- Source: https://github.com/TsudaKageyu/minhook/blob/c3fcafdc10146beb5919319d0683e44e3c30d537/LICENSE.txt
- License: the full upstream LICENSE.txt (including bundled-component notices) is reproduced verbatim in MinHook_LICENSE.txt.
- License Git blob: 74dea27229c05b53b095aa22b9ee7ee9f549e414.

## Matheus PreSR shader adaptations

The source commit, modifications and complete GPL text are documented in ../components/NOTICE and ../components/LICENSE. Distribute those documents and the corresponding source with any addon binary derived from these components.

