# Exact C7 static ABI evidence — 2026-09-15

This contract applies only to the already installed XeFG-compatible NR 0.3.0 binary with SHA256 `c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de`, 7,290,880 bytes. The original runtime is not redistributed or modified by this addon.

The PE/disassembly analysis located three FFX leaf thunks at RVAs `0x11dc0`, `0x11de0`, and `0x11e00`, loading original dispatch callbacks from `0x97d00`/`0x97d08`/`0x97d10` and reaching helper `0x1c430`. The Windows x64 helper accepts `(original_callback, context, dispatch)` and returns a 32-bit FFX status. Its normal paths call the supplied callback once synchronously. The dispatch header uses a 64-bit type and the cloned upscale descriptor is 432 bytes.

The existing helper records NR capture/wait/residual work into the supplied command list. A corrected-color callback is evidence that commands were recorded, not evidence that inference completed successfully. The runtime's existing ExecuteCommandLists hook publishes capture work after submission. Waiting on the CPU before game submission can deadlock and is forbidden in this adapter.

No base relocation is present in the helper's `0x1c430..0x1c9bc` body. The runtime gate checks the complete file hash, image bounds, executable helper region, and pristine helper bytes. A different runtime or another patch of this function must be refused. `tools/verify_runtime_contract.py` reproduces the read-only PE/hash portion of this audit.

The adapter uses GPU queue completion and successful command-list Reset before reusing shader resource slots. Since 0.2.2, a busy/unsupported admission bypasses NR even before the first scaled call and calls the existing FFX callback directly; returning automatically to native NR could reshape the global NR context while work is still pending. Such skips must be reported and cannot count as successful NR acceleration.

## Scope and remaining validation

Static ABI analysis does not verify live callbacks, model support for 85%/75% dimensions, reset/replay behavior in Cyberpunk, queue wrapping by other mods, visual quality, GPU memory headroom, or performance. No AMD GPU/game test has been performed. No claim of NVIDIA DLSS5-equivalent output or increased FPS is made.
