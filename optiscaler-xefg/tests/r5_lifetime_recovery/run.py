#!/usr/bin/env python3
"""R5 regressions compile production install/recovery/release paths unchanged.

External COM, detours and provider boundaries are deterministic CPU fakes.
--revision is a local negative-control aid; CI tests the current source.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import hashlib
import json

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("resource_test_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
BASELINE_HASH = "8d8a59d77b3c942b4499e03b0efe66efc0238d96539d702a36cf6c12b9704420"
NEGATIVE_ASSERT = r'''
#include <cstdlib>
#undef assert
#define assert(condition) do { if (!(condition)) { std::cerr << "R4 invariant failure: " << #condition << "\n"; std::exit(42); } } while (false)
'''


def baseline_fixture():
    # Git may check JSON out with CRLF on Windows; source identity uses LF.
    data = (HERE / "r4_baseline.json").read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(data).hexdigest() != BASELINE_HASH:
        raise AssertionError("Verified R4 fixture identity changed")
    return json.loads(data)["files"]


def negative_release_controls(source):
    fixture = baseline_fixture()
    release = fixture["OptiScaler/hooks/FG_Hooks.cpp"]["functions"]["ULONG FGHooks::hkFGRelease(IUnknown* This)"]
    wrapper = fixture["OptiScaler/wrapped/wrapped_swapchain.cpp"]["functions"]["ULONG STDMETHODCALLTYPE WrappedIDXGISwapChain4::Release()"]
    harness = (HERE / "release_harness.cpp").read_text(encoding="utf-8")
    harness = harness.replace("// ACTUAL_RELEASE_FUNCTION", release).replace("// ACTUAL_WRAPPER_RELEASE_FUNCTION", wrapper)
    harness = harness.replace("// NEGATIVE_ASSERT_SHIM", NEGATIVE_ASSERT)
    cases = [(1,0,0,"state.currentFGSwapchain == &chain"),
             (0,1,0,"chain.buffers[0].refs == 4 && chain.buffers[1].refs == 4"),
             (0,0,1,"wrapper->Release() == 1")]
    for propagation, references, wrapper_case, expected in cases:
        definitions = f"#define CHECK_RELEASE_FAILURE {propagation}\n#define CHECK_REFERENCE_OWNERSHIP {references}\n#define CHECK_WRAPPER_RELEASE {wrapper_case}\n"
        helpers.compile_and_run(source, definitions + harness, "verified R4 negative control: " + expected,
                                expected_exit=42, expected_output=expected)


def observer_integration(source, baseline=False, recovery=False):
    tracker = (source / "OptiScaler/resource_tracking/ResTrack_dx12.cpp").read_text(encoding="utf-8-sig")
    xefg = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8-sig")
    header = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.h").read_text(encoding="utf-8-sig")
    hooks = (source / "OptiScaler/hooks/D3D12_Hooks.cpp").read_text(encoding="utf-8-sig")
    tracker_signatures = ["template <typename T> static T* LifetimeRealObject(T* object)",
        "static HRESULT STDMETHODCALLTYPE hkResetCommandList(",
        "void ResTrack_Dx12::hkExecuteCommandLists(",
        "ULONG ResTrack_Dx12::ReleaseTrackedResource(", "ULONG ResTrack_Dx12::hkRelease(",
        "ULONG ResTrack_Dx12::hkCommandListRelease(", "void ResTrack_Dx12::HookResource(",
        "bool ResTrack_Dx12::LifetimeObserversReady(", "bool ResTrack_Dx12::HookLifetimeObservers(",
        "void ResTrack_Dx12::ReleaseDeviceHooks()"]
    methods = ["bool XeFG_Dx12::TrackPendingCommandList(", "void XeFG_Dx12::BeforeCommandSubmission(",
        "void XeFG_Dx12::AfterCommandSubmission(", "void XeFG_Dx12::DiscardPendingCommandList(",
        "void XeFG_Dx12::TrackLifetimeQueue(", "uint64_t XeFG_Dx12::CapturePendingCommandListGeneration(",
        "void XeFG_Dx12::RetirePendingCommandList(", "void XeFG_Dx12::PublishPendingLocked("]
    functions = [helpers.extract_function(tracker, sig) for sig in tracker_signatures]
    if baseline:
        # Preserve the exact pinned R4 methods. Only the newer caller ABI is
        # adapted; the old observer/lifetime algorithms remain unmodified.
        functions = [function.replace("->BeforeCommandSubmission(", "->BeforeForHook(")
                     .replace("->AfterCommandSubmission(", "->AfterForHook(") for function in functions]
        fixture = baseline_fixture()
        old_methods = fixture["OptiScaler/framegen/xefg/XeFG_Dx12.cpp"]["functions"]
        functions += [next(value for key, value in old_methods.items() if key.startswith(sig.replace("bool XeFG_Dx12::Track", "void XeFG_Dx12::Track"))) for sig in methods[:5]]
        functions += [old_methods["bool XeFG_Dx12::QuiesceWork()"]]
        functions += ["uint64_t XeFG_Dx12::CapturePendingCommandListGeneration(const void*) { return 0; }",
                      "void XeFG_Dx12::RetirePendingCommandList(const void*, uint64_t) {}"]
        functions += [next(iter(fixture["OptiScaler/hooks/D3D12_Hooks.cpp"]["functions"].values()))]
        fields = "static constexpr size_t MaxPendingCommandLists=256; ID3D12CommandList* _pendingCommandLists[MaxPendingCommandLists]{}; size_t _pendingCommandListCount=0; bool _pendingTrackingComplete=true; std::condition_variable _pendingCommandsSubmitted;"
    else:
        functions += [helpers.extract_function(xefg, sig.replace("void XeFG_Dx12::BeforeCommandSubmission(", "uint64_t XeFG_Dx12::BeforeCommandSubmission(")) for sig in methods + [
            "bool XeFG_Dx12::TryCloseCpuAdmission()", "void XeFG_Dx12::RestoreCpuAdmission()", "bool XeFG_Dx12::QuiesceWork()"]]
        functions += [helpers.extract_function(hooks, "static void HookToDevice(ID3D12Device* InDevice)\n{")]
        start = header.index("    static constexpr size_t MaxPendingCommandLists")
        fields = header[start:header.index("    bool QuiesceWork();",start)]
    harness = (HERE / "observer_harness.cpp").read_text(encoding="utf-8")
    harness = harness.replace("// ACTUAL_FUNCTIONS", "\n\n".join(functions)).replace("// ACTUAL_PENDING_FIELDS", fields)
    definitions = "#define BASELINE_RECOVERY " + str(int(recovery)) + "\n#define R4_BASELINE " + str(int(baseline)) + "\n#define TRACK_RETURN " + ("void" if baseline else "bool") + "\n"
    if baseline:
        harness = harness.replace("// NEGATIVE_ASSERT_SHIM", NEGATIVE_ASSERT)
        helpers.compile_and_run(source, definitions + harness, ("verified R4 failed cleanup leaves work admission closed" if recovery else "verified R4 missing observer install leaves 51 completed recordings pending"), expected_exit=42, expected_output="!fg._workGate.IsClosed()" if recovery else "fg._pendingCommandListCount==0")
    else:
        helpers.compile_and_run(source, definitions + harness, "actual DLSSG lifetime installation and routed completion callbacks")


def read_source(root, relative, revision):
    if revision:
        return subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + relative], text=True)
    return (root / relative).read_text(encoding="utf-8-sig")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--revision", help="Compile the selected revision to demonstrate the regression")
    parser.add_argument("--case", choices=("all", "release_failure", "reference_ownership", "wrapper_release"), default="all")
    args = parser.parse_args()
    source = args.source.resolve()
    hook_source = read_source(source, "OptiScaler/hooks/FG_Hooks.cpp", args.revision)
    release = helpers.extract_function(hook_source, "ULONG FGHooks::hkFGRelease(IUnknown* This)")
    wrapper_source = read_source(source, "OptiScaler/wrapped/wrapped_swapchain.cpp", args.revision)
    wrapper_release = helpers.extract_function(wrapper_source, "ULONG STDMETHODCALLTYPE WrappedIDXGISwapChain4::Release()")
    harness = (HERE / "release_harness.cpp").read_text(encoding="utf-8")
    definitions = "#define CHECK_RELEASE_FAILURE " + str(int(args.case in ("all", "release_failure"))) + "\n"
    definitions += "#define CHECK_REFERENCE_OWNERSHIP " + str(int(args.case in ("all", "reference_ownership"))) + "\n"
    definitions += "#define CHECK_WRAPPER_RELEASE " + str(int(args.case in ("all", "wrapper_release"))) + "\n"
    harness = harness.replace("// ACTUAL_RELEASE_FUNCTION", release)
    harness = harness.replace("// ACTUAL_WRAPPER_RELEASE_FUNCTION", wrapper_release)
    helpers.compile_and_run(source, definitions + harness,
                            "actual release caller preserves live references on failed teardown")
    if not args.revision and args.case == "all":
        observer_integration(source)
        observer_integration(source, baseline=True)
        observer_integration(source, baseline=True, recovery=True)
        negative_release_controls(source)
        helpers.compile_and_run(source, (HERE / "diagnostics.cpp").read_text(encoding="utf-8"),
                                "production observer, pending, recovery and timing diagnostics")


if __name__ == "__main__":
    main()
