# HUD resource selection patch review

Base: OptiScaler commit 7daf5d042d32412da407838cd59e0869ecaaa55e (2026-09-09).
File: OptiScaler/framegen/ffx/FSRFG_Dx12.cpp.
Upstream Git blob: cefed546895d9e19a5899914c39f78e50e143be8.
The base file's local Git blob was verified to match upstream.

Scope: correct the HUD resource and D3D12 state selected for HudCopy/HudlessCompare inside FSRFG_Dx12::DispatchCallback. No upscaler, FG input/output selection, reset policy, or HUD cutoff setting is changed.

The original callback first consults the reusable _resourceCopy cache. That cache persists across NewFrame(), which clears _frameResources. Consequently a cached resource can be selected despite a different current frame resource or no current frame resource. The callback also assumes COPY_DEST for a selected copy, whereas HudlessFormatTransfer explicitly records its resulting copy in UNORDERED_ACCESS state. Those are sequentially reproducible selection/state defects.

The patch uses GetResource() to read the current frame record, retains its selected resource with ComPtr, and uses the state from that same record. It keeps the shared registry lock only through acquisition of the strong reference, then releases it before command-list hooks or FFX code can run. A copy or UntilPresent record remains eligible; an uncopied ValidNow record does not become eligible.

Independent review by cet_key_audit confirmed the state contract, eligibility condition, and short lock scope.

Validation:
- tests/hudless_selector_test.cpp includes the original and patched selector blocks.
- Three original failures are reproduced: stale cache overrides current direct resource; format-transfer copy is assigned COPY_DEST instead of its recorded UAV state; a cleared frame uses a prior cached resource.
- Patched selector passes those cases and preserves the normal copied-resource path.
- Additional cases verify no map insertion, rejection of uncopied transient input, strong-reference retention through CPU recording, and release of the registry lock before reentrant resource tracking.
- Compilation and execution:
  g++ -std=c++20 -Wall -Wextra -Werror -O1 -g -pthread -fsanitize=address,undefined tests/hudless_selector_test.cpp -o tests/hudless_selector_test
  ASAN_OPTIONS=detect_leaks=0 tests/hudless_selector_test
- PASS. LeakSanitizer cannot run in this container's ptrace environment; address and undefined-behavior sanitizers were retained.

Limits:
- The harness substitutes portable COM and resource-registry types. It does not compile the Windows DLL, run D3D12/AMD drivers, or reproduce the user's game.
- The snapshot retains the resource during custom CPU command recording. It is not a GPU completion fence and does not establish all asynchronous resource lifetime guarantees.
- The patch does not prove or promise a fix for the observed amdxc64 crashes or saved CET key changes.
- The user's exact installed 0.10 preview revision remains unknown.
- The older supplied 6dedfde8 device-init patch is a distinct source revision and does not contain this correction.

Deliverable inputs for the parent agent:
- hudless-current-frame.patch
- base/OptiScaler/framegen/ffx/FSRFG_Dx12.cpp
- patched/OptiScaler/framegen/ffx/FSRFG_Dx12.cpp
- tests/hudless_selector_test.cpp
- SOURCE.json

