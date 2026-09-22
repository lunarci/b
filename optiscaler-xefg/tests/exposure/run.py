#!/usr/bin/env python3
"""Exercise actual FFX input/crop/restore code with failing NGX and GPU-state mocks.

These tests check CPU contracts and recorded barrier ordering, not image quality
or real GPU execution. No duplicated implementation is substituted for the code.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def body(text, marker):
    start = text.index("{", text.index(marker))
    depth = 1
    pos = start + 1
    while depth:
        depth += (text[pos] == "{") - (text[pos] == "}")
        pos += 1
    return text[start + 1:pos - 1]


parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("--cxx")
args = parser.parse_args()
source = (args.source / "OptiScaler/upscalers/ffx/FFXFeature_Dx12.cpp").read_text(encoding="utf-8-sig")
header = (args.source / "OptiScaler/upscalers/ffx/FFXFeature_Dx12.h").read_text(encoding="utf-8-sig")
read_resource = body(source, "static ID3D12Resource* ReadFfxResource(")
evaluate = body(source, "bool FFXFeatureDx12::EvaluateInternal(")
preflight = evaluate[evaluate.index("    // Validate the complete required input set"):
                     evaluate.index("    // FSR4's padding workaround may replace paramColor")]
reset = evaluate[evaluate.index("    unsigned int reset = 0;"):
                 evaluate.index("    GetRenderResolution(")]
pre_exposure = evaluate[evaluate.index("    // FFX requires positive pre-exposure."):
                        evaluate.index("    if (Version() >= feature_version { 3, 1, 1 }")]
crop = body(evaluate, "                if (smallerColor[index])")
mask_transition = body(evaluate, "                if (Config::Instance()->MaskResourceBarrier.has_value())")
tail = evaluate[evaluate.index('    LOG_DEBUG("Dispatch!!");'):]
buffer_init = next(line.strip() for line in header.splitlines() if "ID3D12Resource* smallerColor[2]" in line)

prefix = r'''
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <vector>
#define LOG_DEBUG(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_WARN(...) ((void)0)
constexpr int NVSDK_NGX_Result_Success = 0, Failed = 1;
constexpr const char* NVSDK_NGX_Parameter_Color = "color";
constexpr const char* NVSDK_NGX_Parameter_MotionVectors = "mv";
constexpr const char* NVSDK_NGX_Parameter_Output = "output";
constexpr const char* NVSDK_NGX_Parameter_Depth = "depth";
constexpr const char* NVSDK_NGX_Parameter_ExposureTexture = "exposure";
constexpr const char* NVSDK_NGX_Parameter_DLSS_Pre_Exposure = "preExposure";
constexpr const char* NVSDK_NGX_Parameter_Reset = "reset";
enum D3D12_RESOURCE_STATES {
    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_SOURCE,
    D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_RENDER_TARGET,
    D3D12_RESOURCE_STATE_UNORDERED_ACCESS
};
struct ID3D12Resource { D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE; };
struct ResourceRead {
    int typedResult = Failed, voidResult = Failed;
    bool typedWrites = false, voidWrites = false;
    ID3D12Resource* typedValue = nullptr;
    ID3D12Resource* voidValue = nullptr;
};
struct NVSDK_NGX_Parameter {
    std::map<std::string, ResourceRead> resources;
    int typedCalls = 0, voidCalls = 0, floatResult = Failed, resetResult = Failed;
    float floatValue = 1.0f;
    unsigned int resetValue = 0;
    int Get(const char* name, ID3D12Resource** output) {
        ++typedCalls;
        auto r = resources[name];
        if (r.typedWrites) *output = r.typedValue;
        return r.typedResult;
    }
    int Get(const char* name, void** output) {
        ++voidCalls;
        auto r = resources[name];
        if (r.voidWrites) *output = r.voidValue;
        return r.voidResult;
    }
    int Get(const char*, float* output) { *output = floatValue; return floatResult; }
    int Get(const char*, unsigned int* output) {
        *output = resetValue; // Failure may still write; callers must check status.
        return resetResult;
    }
    void Supply(const char* name, ID3D12Resource* resource) {
        resources[name] = {NVSDK_NGX_Result_Success, Failed, true, false, resource, nullptr};
    }
};
static ID3D12Resource* ReadFfxResource(NVSDK_NGX_Parameter* parameters, const char* name) {
'''
middle = r'''
}
struct State {
    std::optional<bool> autoExposure;
    std::map<unsigned int, bool> changeBackend;
    static State& Instance() { static State state; return state; }
};
struct HandleType { unsigned int Id = 17; };
struct InputSubject {
    bool lowResMV = true, autoExposure = false, continued = false;
    HandleType handle;
    bool LowResMV() const { return lowResMV; }
    bool AutoExposure() const { return autoExposure; }
    HandleType* Handle() { return &handle; }
    bool Evaluate(NVSDK_NGX_Parameter* InParameters) {
'''
after_preflight = r'''
        continued = true;
        return true;
    }
};
static bool ReadReset(NVSDK_NGX_Parameter* InParameters) {
    struct { bool reset; } params {};
'''
after_reset = r'''
    return params.reset;
}
static float ReadPreExposure(NVSDK_NGX_Parameter* InParameters) {
    struct { float preExposure; } params {};
'''
after_exposure = r'''
    return params.preExposure;
}
struct Config {
    std::optional<D3D12_RESOURCE_STATES> ColorResourceBarrier, MVResourceBarrier,
        OutputResourceBarrier, DepthResourceBarrier, ExposureResourceBarrier, MaskResourceBarrier;
    static Config* Instance() { static Config config; return &config; }
};
struct D3D12_BOX { unsigned int left, top, right, bottom, front, back; };
constexpr int D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX = 0;
struct D3D12_TEXTURE_COPY_LOCATION { ID3D12Resource* pResource; int Type; unsigned int SubresourceIndex; };
static int copies = 0, barriers = 0, dispatches = 0, dispatchResult = 0;
constexpr int FFX_API_RETURN_OK = 0, FFX_API_RETURN_ERROR_RUNTIME_ERROR = 1, FFX_API_RETURN_ERROR = 2;
static ID3D12Resource* dispatchedColor = nullptr;
struct ID3D12GraphicsCommandList {
    void CopyTextureRegion(D3D12_TEXTURE_COPY_LOCATION* dst, unsigned int, unsigned int, unsigned int,
                           D3D12_TEXTURE_COPY_LOCATION* src, D3D12_BOX* box) {
        assert(src->pResource->state == D3D12_RESOURCE_STATE_COPY_SOURCE);
        assert(dst->pResource->state == D3D12_RESOURCE_STATE_COPY_DEST);
        assert(box->right == 1280 && box->bottom == 720 && box->back == 1);
        ++copies;
    }
};
struct FfxApiProxy {
    static int D3D12_Dispatch(void**, int*) {
        assert(dispatchedColor->state == D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        ++dispatches;
        return dispatchResult;
    }
};
struct CropSubject {
    HandleType handle;
    unsigned int _frameCount = 0;
    void* _context = nullptr;
    HandleType* Handle() { return &handle; }
    void ResourceBarrier(ID3D12GraphicsCommandList*, ID3D12Resource* resource,
                         D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
        assert(resource != nullptr && resource->state == before);
        resource->state = after;
        ++barriers;
    }
    bool Run(ID3D12Resource* originalColor, ID3D12Resource* cropBuffer, bool padded,
             ID3D12Resource* paramReactiveMask2) {
        ID3D12Resource* paramColor = originalColor;
        ID3D12Resource* smallerColor[2] = {cropBuffer, nullptr};
        const size_t index = 0;
        ID3D12GraphicsCommandList commands;
        auto* InCommandList = &commands;
        struct { int header; struct { unsigned int width, height; } renderSize; } params {0, {1280,720}};
        if (padded && smallerColor[index]) {
'''
after_crop = r'''
        }
        assert(originalColor->state == D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        dispatchedColor = paramColor;
        ID3D12Resource *paramVelocity = nullptr, *paramOutput = nullptr, *paramDepth = nullptr,
            *paramExp = nullptr;
        ID3D12Resource* transitionedMask = nullptr;
        if (paramReactiveMask2 && Config::Instance()->MaskResourceBarrier.has_value()) {
'''
after_mask = r'''
        }
'''
tests = r'''
    }
};
struct BufferInitSubject {
@BUFFER_INIT@
};
int main() {
    int cases = 0;
    ID3D12Resource resource;
    // Get may fail without touching output or may poison it despite failing.
    for (int typed : {Failed, NVSDK_NGX_Result_Success})
    for (int generic : {Failed, NVSDK_NGX_Result_Success})
    for (bool typedWrites : {false, true})
    for (bool voidWrites : {false, true}) {
        NVSDK_NGX_Parameter p;
        p.resources["r"] = {typed, generic, typedWrites, voidWrites, &resource, &resource};
        auto actual = ReadFfxResource(&p, "r");
        auto expected = typed == NVSDK_NGX_Result_Success ? (typedWrites ? &resource : nullptr)
            : (generic == NVSDK_NGX_Result_Success && voidWrites ? &resource : nullptr);
        assert(actual == expected);
        assert(p.voidCalls == (typed == NVSDK_NGX_Result_Success ? 0 : 1));
        ++cases;
    }
    // All combinations of missing required inputs and exposure. Only a complete
    // frame may request fallback; high-resolution MVs still permit missing depth.
    for (unsigned int mask = 0; mask < 32; ++mask)
    for (bool lowRes : {false, true})
    for (bool automatic : {false, true}) {
        NVSDK_NGX_Parameter p;
        const char* names[] = {"color", "mv", "output", "depth", "exposure"};
        for (unsigned int i = 0; i < 5; ++i)
            if (mask & (1U << i)) p.Supply(names[i], &resource);
        State::Instance() = {};
        InputSubject subject;
        subject.lowResMV = lowRes; subject.autoExposure = automatic;
        const bool complete = (mask & 7) == 7 && (!lowRes || (mask & 8));
        const bool fallback = complete && !automatic && !(mask & 16);
        assert(subject.Evaluate(&p) == complete);
        assert(subject.continued == (complete && !fallback));
        assert(State::Instance().autoExposure.has_value() == fallback);
        assert(State::Instance().changeBackend[17] == fallback);
        ++cases;
    }
    // Positive finite values pass through byte-for-byte; invalid/missing inputs
    // use the existing default 1. No valid exposure values are tuned.
    for (float value : {0.0f, -1.0f, 0.001f, 0.5f, 1.0f, 9.0f,
                       std::numeric_limits<float>::infinity(),
                       -std::numeric_limits<float>::infinity(),
                       std::numeric_limits<float>::quiet_NaN()})
    for (int result : {Failed, NVSDK_NGX_Result_Success}) {
        NVSDK_NGX_Parameter p;
        p.floatValue = value; p.floatResult = result;
        const float expected = result == NVSDK_NGX_Result_Success && std::isfinite(value) && value > 0.0f ? value : 1.0f;
        assert(ReadPreExposure(&p) == expected);
        ++cases;
    }
    for (unsigned int value : {0U, 1U, 2U})
    for (int result : {Failed, NVSDK_NGX_Result_Success}) {
        NVSDK_NGX_Parameter p;
        p.resetValue = value; p.resetResult = result;
        assert(ReadReset(&p) == (result == NVSDK_NGX_Result_Success && value == 1));
        ++cases;
    }
    // Original -> COPY_SOURCE -> copy -> read state -> configured state.
    // Neither ordinary nor runtime dispatch failure may skip the restoration.
    for (int cropMode : {0, 1, 2}) // none, crop, allocation unavailable
    for (bool configured : {false, true})
    for (bool maskConfigured : {false, true})
    for (bool maskSupplied : {false, true})
    for (int result : {FFX_API_RETURN_OK, FFX_API_RETURN_ERROR_RUNTIME_ERROR, FFX_API_RETURN_ERROR}) {
        State::Instance() = {};
        *Config::Instance() = {};
        if (configured) Config::Instance()->ColorResourceBarrier = D3D12_RESOURCE_STATE_RENDER_TARGET;
        if (maskConfigured) Config::Instance()->MaskResourceBarrier = D3D12_RESOURCE_STATE_RENDER_TARGET;
        ID3D12Resource original, cropResource, maskResource;
        if (maskConfigured) maskResource.state = D3D12_RESOURCE_STATE_RENDER_TARGET;
        const bool padded = cropMode == 1;
        copies = barriers = dispatches = 0; dispatchResult = result;
        CropSubject subject;
        assert(subject.Run(&original, cropMode == 2 ? nullptr : &cropResource, cropMode != 0,
                           maskSupplied ? &maskResource : nullptr) == (result == FFX_API_RETURN_OK));
        assert(original.state == (configured ? D3D12_RESOURCE_STATE_RENDER_TARGET
                                            : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE));
        assert(cropResource.state == D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        assert(maskResource.state == (maskConfigured ? D3D12_RESOURCE_STATE_RENDER_TARGET
                                                    : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE));
        assert(dispatchedColor == (padded ? &cropResource : &original));
        assert(copies == (padded ? 1 : 0));
        assert(barriers == (padded ? 4 : 0) + (configured ? 1 : 0) + (maskConfigured && maskSupplied ? 2 : 0));
        assert(dispatches == 1);
        assert(subject._frameCount == (result == FFX_API_RETURN_OK ? 1U : 0U));
        assert(State::Instance().changeBackend[17] == (result == FFX_API_RETURN_ERROR_RUNTIME_ERROR));
        ++cases;
    }
    BufferInitSubject buffers;
    assert(buffers.smallerColor[0] == nullptr && buffers.smallerColor[1] == nullptr);
    ++cases;
    std::cout << "PASS: " << cases << " FFX production-code resource/exposure/crop cases\n";
}
'''.replace("@BUFFER_INIT@", buffer_init)

program = (prefix + read_resource + middle + preflight + after_preflight + reset + after_reset +
           pre_exposure + after_exposure + crop + after_crop + mask_transition + after_mask + tail + tests)
with tempfile.TemporaryDirectory(prefix="ffx-input-") as tmp:
    directory = Path(tmp)
    cpp = directory / "ffx-input.cpp"
    cpp.write_text(program, encoding="utf-8")
    compiler = args.cxx or (shutil.which("cl") if os.name == "nt" else shutil.which("c++"))
    if not compiler:
        parser.error("C++ compiler required; run through tests/run.py for MSVC environment setup")
    executable = directory / ("ffx-input.exe" if os.name == "nt" else "ffx-input")
    if Path(compiler).name.lower() in ("cl", "cl.exe"):
        command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/WX", "/UNDEBUG",
                   str(cpp), "/Fe:" + str(executable), "/Fo:" + str(directory / "ffx-input.obj")]
    else:
        command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
                   str(cpp), "-o", str(executable)]
    subprocess.run(command, cwd=directory, check=True)
    subprocess.run([str(executable)], check=True)
