#!/usr/bin/env python3
"""Execute production XeFG SetResource against lifetime-checking CPU fakes.

No shader/driver behavior is simulated. The actual entire SetResource body is
compiled, so copy selection, aliasing, rejection and failed-copy control flow
are exercised together. Optional local revision modes demonstrate the original
R2/R3 difference; CI executes the current source and all R4 checks.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def extract_function(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for end in range(opening, len(text)):
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
            if not depth:
                return text[start:end + 1]
    raise ValueError("Unclosed production function: " + signature)


def compile_and_run(source, cpp_text, title, expected_exit=0, expected_output=None):
    compiler = os.environ.get("CXX") or (shutil.which("cl") if os.name == "nt" else shutil.which("c++"))
    if not compiler:
        raise RuntimeError("Run tests/run.py to initialize the MSVC compiler environment")
    with tempfile.TemporaryDirectory(prefix="r4-resource-") as temporary:
        directory = Path(temporary)
        cpp = directory / "test.cpp"
        executable = directory / ("test.exe" if os.name == "nt" else "test")
        cpp.write_text(cpp_text, encoding="utf-8")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/Od", "/UNDEBUG",
                       "/I" + str(source / "OptiScaler"), str(cpp), "/Fe:" + str(executable)]
        else:
            command = [compiler, "-std=c++20", "-O0", "-UNDEBUG", "-pthread",
                       "-I", str(source / "OptiScaler"), str(cpp), "-o", str(executable)]
        subprocess.run(command, cwd=directory, check=True)
        result = subprocess.run([str(executable)], cwd=directory, timeout=30,
                                capture_output=expected_exit != 0, text=True)
        if result.returncode != expected_exit:
            raise RuntimeError(f"{title}: expected exit {expected_exit}, got {result.returncode}; {result.stdout or ''}{result.stderr or ''}")
        if expected_output and expected_output not in (result.stdout or "") + (result.stderr or ""):
            raise AssertionError(f"Negative control failed for an unexpected reason: {result.stdout}{result.stderr}")
    print("PASS: " + title, flush=True)


HARNESS = r'''
#include <cassert>
#include <cstdint>
#include <format>
#include <iostream>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>
#if __has_include("framegen/FGWorkGate.h")
#include "framegen/FGWorkGate.h"
#else
// Historical R2/R3 local audits contain no admission calls.
struct FGWorkGate { struct Scope { explicit operator bool() const { return true; } }; Scope TryEnter() { return {}; } };
#endif
#if __has_include("misc/XeFGResourceDiagnostics.h")
#define TEST_HAS_DIAGNOSTICS 1
#include "misc/XeFGResourceDiagnostics.h"
#endif
#define LOG_ERROR(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
using UINT = unsigned; using UINT64 = uint64_t;
constexpr int BUFFER_COUNT = 4;
enum D3D12_RESOURCE_STATES { D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE,
    D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS };
using DXGI_FORMAT = int;
constexpr DXGI_FORMAT DXGI_FORMAT_UNKNOWN = 0;
enum class FG_ResourceType { UIColor, Depth, Velocity, HudlessColor, Distortion };
enum class FG_ResourceValidity { ValidNow, UntilPresent, UntilPresentFromDispatch, ValidButMakeCopy, JustTrackCmdlist };
enum class FGInput { Upscaler, Other };
struct feature_version {
    int major, minor, patch;
    bool operator<(const feature_version& rhs) const {
        return std::tie(major, minor, patch) < std::tie(rhs.major, rhs.minor, rhs.patch);
    }
};
struct ID3D12GraphicsCommandList {};
struct Desc { int Format = 28; };
struct ID3D12Device {
    struct AllocationInfo { uint64_t SizeInBytes = 8192; };
    AllocationInfo GetResourceAllocationInfo(unsigned, unsigned, const Desc*) { return {}; }
};
struct ID3D12Resource {
    bool live = true; unsigned descCalls = 0;
    D3D12_RESOURCE_STATES actualState = D3D12_RESOURCE_STATE_COMMON;
    Desc GetDesc() { assert(live && "accessed expired borrowed resource"); ++descCalls; return {}; }
    void SetName(const wchar_t*) {}
};
struct Dx12Resource {
    FG_ResourceType type = FG_ResourceType::HudlessColor;
    ID3D12Resource* resource = nullptr;
    UINT top = 0, left = 0; UINT64 width = 2560; UINT height = 1440;
    ID3D12GraphicsCommandList* cmdList = nullptr;
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
    FG_ResourceValidity validity = FG_ResourceValidity::UntilPresent;
    ID3D12Resource* copy = nullptr; int frameIndex = -1; bool waitingExecution = false;
    ID3D12Resource* GetResource() { return copy ? copy : resource; }
};
struct Flag { bool value = false; bool value_or_default() const { return value; } };
struct Config {
    Flag FGDisableHudless, FGOnlyAcceptFirstHudless, FGDisableUI, FGDrawUIOverFG,
         FGResourceFlip, FGXeFGDepthInverted;
    static Config* Instance() { static Config instance; return &instance; }
};
struct State {
    bool fgHudlessCompare = false, fgChanged = false;
    FGInput activeFgInput = FGInput::Other;
    static State& Instance() { static State instance; return instance; }
};
struct DI_Dx12 {
    DI_Dx12(const char*, ID3D12Device*) {}
    bool IsInit() const { return false; }
    bool CreateBufferResource(ID3D12Device*, ID3D12Resource*, UINT64, UINT, D3D12_RESOURCE_STATES) { return false; }
    ID3D12Resource* Buffer() const { return nullptr; }
    void SetBufferState(ID3D12GraphicsCommandList*, D3D12_RESOURCE_STATES) {}
    bool Dispatch(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*) { return false; }
};
struct RF_Dx12 {
    RF_Dx12(const char*, ID3D12Device*) {}
    bool IsInit() const { return true; }
    bool Dispatch(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*, UINT64, UINT, bool) { return true; }
};
enum xefg_swapchain_result_t { XEFG_SWAPCHAIN_RESULT_SUCCESS, XEFG_SWAPCHAIN_RESULT_ERROR };
constexpr int XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT = 1;
struct xefg_swapchain_d3d12_resource_data_t {
    ID3D12Resource* resource = nullptr;
    D3D12_RESOURCE_STATES incomingState = D3D12_RESOURCE_STATE_COMMON;
    int validity = XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT;
};
struct XeFGProxy {
    inline static ID3D12Resource* lastTagged = nullptr;
    inline static unsigned tagCalls = 0;
    static void* SetUiCompositionState() { return reinterpret_cast<void*>(1); }
    static xefg_swapchain_result_t Tag(void*, ID3D12GraphicsCommandList*, uint32_t,
                                      xefg_swapchain_d3d12_resource_data_t* data) {
        assert(data->resource && data->resource->live);
        assert(data->resource->actualState == data->incomingState);
        lastTagged = data->resource; ++tagCalls;
        return XEFG_SWAPCHAIN_RESULT_SUCCESS;
    }
    static auto D3D12TagFrameResource() { return &Tag; }
};
struct XeFG_Dx12 {
    FGWorkGate _workGate;
    auto AcquireWork() { return _workGate.TryEnter(); }
#if TEST_HAS_DIAGNOSTICS
    XeFGDiagnostics::Context _resourceDiagnostics;
    struct CopyAllocationInfo { uint64_t bytes = 0; bool known = false; };
    std::unordered_map<FG_ResourceType, CopyAllocationInfo> _copyAllocationInfo[BUFFER_COUNT];
#endif
    bool _lifecycleFailed = false, active = true, paused = false, failCopy = false;
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, Dx12Resource> _frameResources[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, ID3D12Resource*> _resourceCopy[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, bool> _resourceReady[BUFFER_COUNT];
    bool _noHudless[BUFFER_COUNT] {true,true,true,true};
    bool _noUi[BUFFER_COUNT] {true,true,true,true};
    bool _noDistortionField[BUFFER_COUNT] {true,true,true,true};
    ID3D12Device* _device = nullptr;
    std::unique_ptr<DI_Dx12> _depthInvert;
    std::unique_ptr<RF_Dx12> _depthFlip, _mvFlip;
    uint64_t _frameCount = 8;
    void* _swapChainContext = reinterpret_cast<void*>(1);
    ID3D12Resource freshCopy;
    ID3D12Resource* nextFlipOutput = &freshCopy;
    unsigned copyCalls = 0, readinessCalls = 0;
    unsigned pendingCalls = 0;
    bool pendingOk = true;
    bool TrackPendingCommandList(ID3D12GraphicsCommandList*) { ++pendingCalls; return pendingOk; }
    bool IsActive() const { return active; }
    bool IsPaused() const { return paused; }
    int GetIndex() const { return 0; }
    static feature_version Version() { return {1,3,1}; }
#if R4_SOURCE
    void FlipResource(Dx12Resource*);
    void RecordCopyAllocation(int, FG_ResourceType, ID3D12Resource*);
    // ACTUAL_INLINE_FAILURE_HANDLER
#else
    void FlipResource(Dx12Resource*) { assert(false && "unexpected test branch"); }
#endif
    bool CreateBufferResource(ID3D12Device*, ID3D12Resource*, D3D12_RESOURCE_STATES state,
                              ID3D12Resource** output, bool, bool) {
        if (failCopy) return false;
        *output = nextFlipOutput; (*output)->actualState = state; return true;
    }
    ID3D12GraphicsCommandList* GetUICommandList(int) { return nullptr; }
    bool CopyResource(ID3D12GraphicsCommandList*, ID3D12Resource* src, ID3D12Resource** out, D3D12_RESOURCE_STATES) {
        assert(src && src->live); ++copyCalls;
        if (failCopy) return false;
        freshCopy.actualState = D3D12_RESOURCE_STATE_COPY_DEST;
        *out = &freshCopy; return true;
    }
    xefg_swapchain_d3d12_resource_data_t GetResourceData(FG_ResourceType type, int slot) {
        auto& entry = _frameResources[slot].at(type);
        return {entry.GetResource(), entry.state};
    }
    void ResourceBarrier(ID3D12GraphicsCommandList*, ID3D12Resource*, D3D12_RESOURCE_STATES, D3D12_RESOURCE_STATES) {}
    void UpdateTarget() {}
    void Deactivate() { active = false; }
    void SetResourceReady(FG_ResourceType type, int slot) { _resourceReady[slot][type] = true; ++readinessCalls; }
    bool SetResource(Dx12Resource* inputResource);
};
// This alias keeps the extracted base-class function body and signature intact
// while the CPU harness supplies the virtual/backend boundary in one fake class.
using IFGFeature_Dx12 = XeFG_Dx12;
'''

TESTS = r'''
static void resetGlobals() {
    *Config::Instance() = Config{}; State::Instance() = State{};
    XeFGProxy::lastTagged = nullptr; XeFGProxy::tagCalls = 0;
}
static void selfAlias(bool expectedLost) {
    resetGlobals(); XeFG_Dx12 subject; ID3D12Resource original, copy;
    copy.actualState = D3D12_RESOURCE_STATE_COPY_DEST;
    Dx12Resource cached; cached.resource = &original; cached.copy = &copy; cached.frameIndex = 0;
    cached.state = D3D12_RESOURCE_STATE_COPY_DEST;
    cached.validity = FG_ResourceValidity::UntilPresentFromDispatch;
    subject._frameResources[0][FG_ResourceType::HudlessColor] = cached;
    subject._resourceCopy[0][FG_ResourceType::HudlessColor] = &copy;
    subject._noHudless[0] = false;
    if (expectedLost) original.actualState = D3D12_RESOURCE_STATE_COPY_DEST;
    else original.live = false; // Its ValidNow lifetime ended; only the copy is legal now.
    auto* alias = &subject._frameResources[0][FG_ResourceType::HudlessColor];
    assert(subject.SetResource(alias));
    assert(XeFGProxy::lastTagged == (expectedLost ? &original : &copy));
    assert(alias->copy == (expectedLost ? nullptr : &copy));
    assert(subject.copyCalls == 0);
    assert(original.descCalls == (expectedLost ? 1u : 0u));
#if R4_SOURCE
    assert(subject._resourceDiagnostics.Read().counters.aliasPreserved == 1);
#endif
}
static void freshInput() {
    resetGlobals(); XeFG_Dx12 subject; ID3D12Resource oldOriginal, staleCopy, fresh;
    staleCopy.live = false;
    Dx12Resource old; old.resource = &oldOriginal; old.copy = &staleCopy;
    subject._frameResources[0][FG_ResourceType::HudlessColor] = old;
    subject._noHudless[0] = false;
    Dx12Resource input; input.resource = &fresh; input.validity = FG_ResourceValidity::UntilPresentFromDispatch;
    assert(subject.SetResource(&input));
    assert(XeFGProxy::lastTagged == &fresh && subject.copyCalls == 0);
    assert(subject._frameResources[0].at(FG_ResourceType::HudlessColor).copy == nullptr);
    assert(staleCopy.descCalls == 0);
}
static void copyFailureAndRetry() {
    resetGlobals(); XeFG_Dx12 subject; ID3D12Resource fresh, priorCopy;
    ID3D12Device device; subject._device = &device;
    ID3D12GraphicsCommandList commands;
    subject._resourceCopy[0][FG_ResourceType::HudlessColor] = &priorCopy;
#if R4_SOURCE
    subject._resourceDiagnostics.BeginContext();
    subject._resourceDiagnostics.OnAllocate(8192);
    subject._copyAllocationInfo[0][FG_ResourceType::HudlessColor] = {8192, true};
#endif
    Dx12Resource input; input.resource = &fresh; input.cmdList = &commands;
    input.validity = FG_ResourceValidity::ValidButMakeCopy;
    subject.failCopy = true;
    assert(!subject.SetResource(&input));
    assert(!subject._frameResources[0].contains(FG_ResourceType::HudlessColor));
    assert(subject._resourceCopy[0].at(FG_ResourceType::HudlessColor) == &priorCopy);
    assert(subject.readinessCalls == 0 && XeFGProxy::tagCalls == 0);
#if R4_SOURCE
    auto accounting = subject._resourceDiagnostics.Read().counters;
    assert(accounting.allocationFailures == 1 && accounting.liveCopies == 1);
    assert(accounting.allocations == 1 && accounting.releases == 0 && accounting.liveBytes == 8192);
#endif
    subject.failCopy = false;
    assert(subject.SetResource(&input));
    assert(subject.copyCalls == 2);
    auto* cached = &subject._frameResources[0].at(FG_ResourceType::HudlessColor);
    assert(cached->copy == &subject.freshCopy);
    fresh.live = false;
    cached->validity = FG_ResourceValidity::UntilPresentFromDispatch;
    cached->frameIndex = 0;
    assert(subject.SetResource(cached));
    assert(XeFGProxy::lastTagged == &subject.freshCopy);
#if R4_SOURCE
    accounting = subject._resourceDiagnostics.Read().counters;
    assert(accounting.allocations == 2 && accounting.releases == 1 && accounting.peakCopies == 2);
    assert(accounting.liveCopies == 1 && accounting.liveBytes == 8192);
    assert(accounting.allocationFailures == 1 && accounting.aliasPreserved == 1 && accounting.accountingErrors == 0);
#endif
}
#if R4_SOURCE
static void flipOwnershipAccounting() {
    for (auto type : {FG_ResourceType::Depth, FG_ResourceType::Velocity}) {
        resetGlobals(); XeFG_Dx12 subject; ID3D12Device device;
        ID3D12Resource source, replacement; ID3D12GraphicsCommandList commands;
        subject._device = &device; subject._resourceDiagnostics.BeginContext();
        Dx12Resource input; input.type = type; input.resource = &source; input.cmdList = &commands;
        subject.failCopy = true;
        subject.FlipResource(&input);
        auto counters = subject._resourceDiagnostics.Read().counters;
        assert(counters.allocationFailures == 1 && counters.liveCopies == 0);
        assert(subject._resourceCopy[0][type] == nullptr && input.copy == nullptr);

        subject.failCopy = false;
        subject.FlipResource(&input); // First call also constructs the shader helper.
        counters = subject._resourceDiagnostics.Read().counters;
        assert(counters.allocations == 1 && counters.liveCopies == 1 && counters.liveBytes == 8192);
        subject.FlipResource(&input); // Existing allocation must not be counted twice.
        counters = subject._resourceDiagnostics.Read().counters;
        assert(counters.allocations == 1 && counters.releases == 0 && input.copy == &subject.freshCopy);

        subject.failCopy = true;
        subject.FlipResource(&input);
        counters = subject._resourceDiagnostics.Read().counters;
        assert(counters.allocationFailures == 2 && counters.liveCopies == 1 && counters.releases == 0);
        assert(subject._resourceCopy[0][type] == &subject.freshCopy);

        subject.failCopy = false; subject.nextFlipOutput = &replacement;
        subject.FlipResource(&input);
        counters = subject._resourceDiagnostics.Read().counters;
        assert(counters.allocations == 2 && counters.releases == 1 && counters.peakCopies == 2);
        assert(counters.liveCopies == 1 && counters.liveBytes == 8192 && counters.accountingErrors == 0);
        assert(input.copy == &replacement && subject._resourceCopy[0][type] == &replacement);
    }
}
#endif
#if R5_SOURCE
static void observerFailureRejectsBeforeGpuWork() {
    for(auto type:{FG_ResourceType::UIColor,FG_ResourceType::HudlessColor,FG_ResourceType::Depth,FG_ResourceType::Velocity}) {
        resetGlobals(); XeFG_Dx12 subject; ID3D12Resource original,oldCopy; ID3D12GraphicsCommandList list;
        Dx12Resource input; input.resource=&original;input.cmdList=&list;input.frameIndex=0;input.type=type;
        input.validity=FG_ResourceValidity::ValidButMakeCopy;
        subject.pendingOk=false; subject._resourceCopy[0][type]=&oldCopy;
        assert(!subject.SetResource(&input));
        assert(subject.pendingCalls==1 && subject.copyCalls==0 && XeFGProxy::tagCalls==0 && subject.readinessCalls==0);
        assert(!subject._frameResources[0].contains(type) && !subject._resourceReady[0].contains(type));
        assert(subject._resourceCopy[0][type]==&oldCopy && oldCopy.live);
        if(type==FG_ResourceType::UIColor) assert(subject._noUi[0]);
        if(type==FG_ResourceType::HudlessColor) assert(subject._noHudless[0]);
        subject.pendingOk=true; assert(subject.SetResource(&input));
        assert(subject.copyCalls==1 && subject._resourceCopy[0][type]==&subject.freshCopy);
    }
}
#endif
int main() {
#if R5_SOURCE
    if (!ALIAS_ONLY) observerFailureRejectsBeforeGpuWork();
#endif
    selfAlias(EXPECT_ALIAS_LOST);
    if (!ALIAS_ONLY) { freshInput(); copyFailureAndRetry(); }
#if R4_SOURCE
    if (!ALIAS_ONLY) flipOwnershipAccounting();
#endif
    std::cout << (ALIAS_ONLY ? "Production SetResource alias-only audit passed\n" :
                              "Production SetResource alias, fresh-input and copy-failure checks passed\n");
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--revision", help="Local audit only: read SetResource from this git revision")
    parser.add_argument("--alias-only", action="store_true")
    parser.add_argument("--expect-alias-lost", action="store_true", help="Confirm the R3 regression, never used by CI")
    args = parser.parse_args()
    source = args.source.resolve()
    path = "OptiScaler/framegen/xefg/XeFG_Dx12.cpp"
    if args.revision:
        text = subprocess.check_output(["git", "-C", str(source), "show", args.revision + ":" + path], text=True)
    else:
        text = (source / path).read_text(encoding="utf-8-sig")
    actual = extract_function(text, "bool XeFG_Dx12::SetResource(Dx12Resource* inputResource)")
    harness = HARNESS
    if "RecordCopyAllocation(" in actual:
        actual += "\n" + extract_function(text, "void XeFG_Dx12::RecordCopyAllocation(")
        base = (source / "OptiScaler/framegen/IFGFeature_Dx12.cpp").read_text(encoding="utf-8-sig")
        actual += "\n" + extract_function(base, "void IFGFeature_Dx12::FlipResource(")
        header = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.h").read_text(encoding="utf-8-sig")
        inline_failure = extract_function(header, "void RecordCopyAllocationFailure()")
        # The fake flattens inheritance; only declaration specifiers are adapted.
        inline_failure = inline_failure.replace(" override final", "")
        harness = harness.replace("// ACTUAL_INLINE_FAILURE_HANDLER", inline_failure)
    definitions = "#define ALIAS_ONLY " + str(int(args.alias_only)) + "\n"
    definitions += "#define EXPECT_ALIAS_LOST " + str(int(args.expect_alias_lost)) + "\n"
    definitions += "#define R5_SOURCE " + str(int("!TrackPendingCommandList(" in actual)) + "\n"
    definitions += "#define R4_SOURCE " + str(int("_resourceDiagnostics" in actual)) + "\n"
    compile_and_run(source, definitions + harness + "\n" + actual + "\n" + TESTS,
                    "actual XeFG SetResource/FlipResource lifetime selection and allocation accounting")
    if not args.alias_only:
        diagnostics = Path(__file__).with_name("diagnostics_test.cpp").read_text(encoding="utf-8")
        compile_and_run(source, diagnostics, "actual XeFG diagnostics accounting and bounded logging")
        lifecycle = Path(__file__).with_name("lifecycle_test.py")
        if not lifecycle.is_file():
            raise RuntimeError("Required R4 concurrent lifecycle suite is missing")
        subprocess.run([sys.executable, str(lifecycle), str(source)], check=True)


if __name__ == "__main__":
    main()
