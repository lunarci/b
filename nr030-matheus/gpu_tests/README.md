# Production compute checks on D3D12 WARP

This directory builds a shared Direct3D 12 shader executor and a Windows test
program. It uses only the Windows SDK, MSVC, CMake and Microsoft's WARP software
adapter. No game, Radeon driver, DLSS-NR model, HIP library, fake inference engine
or external test framework is loaded.

Run on Windows (including a Windows Server 2022 GitHub Actions runner):

```powershell
.\gpu_tests\Build-And-Test.ps1
```

Or integrate with the add-on build:

```cmake
add_subdirectory(gpu_tests)
target_link_libraries(YOUR_ADDON PRIVATE nr030_shader_executor)
add_dependencies(YOUR_ADDON nr030_shader_blobs)
# Embed the four .cso files under ${NR030_SHADER_BIN_DIR} as RCDATA.
```

The shared blobs are compiled from the real component HLSL using
D3DCompileFromFile, MainCS/cs_5_0, strict/IEEE and warnings-as-errors. WARP checks
also compile the source and validate its reflected bindings, then execute the
same build-generated .cso bytes consumed by the add-on's embedded-resource path.
InitializeBytecode is common to both paths. A root-signature or PSO mismatch fails
before any test dispatch.

`nr030_warp_checks <shader-source-dir> <shared-cso-dir> [results.json]`

The runner uploads actual 2D textures, calls the production ShaderExecutor,
submits real D3D12 command lists, waits for a submitted fence, and reads back
pixels. Available D3D12 debug-layer error/corruption messages fail the test.
Tests cover finite identity, 75%/85% noninteger grids, fractional area/edge
averages, depth and motion nearest sampling, matching-delta identity and alpha,
residual guard/clamp, HDR bounds, malformed inputs, actual RGBA16F storage,
and a two-dispatch area-to-residual chain with separate descriptor ranges.

Test fixtures called baseline/edited are mathematical input images used to
exercise the residual formula. They are not labelled as neural output and do not
prove inference correctness, game hook compatibility, AMD speed, XeFG pacing,
hardware residency, crash freedom or visual quality. Those require separate
real-runtime and game checks.

## Executor lifetime contract

- Kernel order for embedded bytecode: Color, Depth, Motion, Residual.
- Resolve b0 contains eight DWORDs; other kernels contain four. Resolve reads
  colour t0..t2 and native depth t3. t0..t3 and u0 use five descriptors per dispatch.
- The caller reserves a distinct five-descriptor range for each outstanding dispatch.
- Record owns no queue submission, fence, allocator or input/output resource lifetime.
- The caller tracks and restores resource states; Transition/UavBarrier only emit explicit barriers.
- Descriptor ranges, command allocators and resources cannot be reused before their GPU uses retire.
- Record changes the command list's descriptor heap, compute root signature and PSO.
  The caller must honor the surrounding engine's state contract.
- Source compilation is for checks/development. Packaged add-ons can initialize only from embedded bytes.

The files here are GPL-3.0-only to match the components they execute; retain the
component NOTICE and LICENSE when distributing them.
