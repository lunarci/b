// SPDX-License-Identifier: GPL-3.0-only
// Exercise the actual production After() with real WARP resource descriptions.
// No game hook, NR inference, shader dispatch, or Radeon execution is performed.
#include "MatheusNR030.cpp"
#include <d3d12sdklayers.h>
#include <cstring>
#include <fstream>
#include <iostream>

namespace {
namespace ffx = nr030::ffx;
namespace cmp = matheus030::components;
using Microsoft::WRL::ComPtr;

void Require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
struct CallbackState {
    const ffx::UpscaleDispatch* expected = nullptr;
    void** context = nullptr;
    unsigned calls = 0;
    bool throwRequested = false;
};
CallbackState callback;
std::uint32_t __fastcall OriginalDispatch(void** context, const ffx::Header* header) {
    ++callback.calls;
    Require(context == callback.context, "Original context changed");
    Require(header && callback.expected &&
            std::memcmp(header, callback.expected, sizeof(ffx::UpscaleDispatch)) == 0,
            "Original 432-byte FFX descriptor changed");
    if (callback.throwRequested) throw std::runtime_error("intentional-original-dispatch-throw");
    return 0x25u;
}

class Warp {
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    bool debugEnabled = false;

    Warp() {
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
            debug->EnableDebugLayer();
            debugEnabled = true;
        }
        ComPtr<IDXGIFactory4> factory;
        nr030::gpu::Check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        nr030::gpu::Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Select WARP");
        DXGI_ADAPTER_DESC1 description{};
        nr030::gpu::Check(adapter->GetDesc1(&description), "Describe WARP");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected software WARP");
        nr030::gpu::Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
            IID_PPV_ARGS(&device)), "Create WARP device");
        nr030::gpu::Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&allocator)), "Create command allocator");
        nr030::gpu::Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
            allocator.Get(), nullptr, IID_PPV_ARGS(&commands)), "Create command list");
    }
    ~Warp() { if (commands) (void)commands->Close(); }

    ComPtr<ID3D12Resource> Texture(cmp::Extent2D extent) {
        const auto description = nr030::Adapter::TextureDescription(extent,
            DXGI_FORMAT_R16G16B16A16_FLOAT);
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        heap.CreationNodeMask = heap.VisibleNodeMask = 1;
        ComPtr<ID3D12Resource> result;
        nr030::gpu::Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE,
            &description, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr,
            IID_PPV_ARGS(&result)), "Create WARP color texture");
        return result;
    }
};

ffx::UpscaleDispatch FullDispatch(Warp& warp, ID3D12Resource* color) {
    ffx::UpscaleDispatch full;
    std::memset(&full, 0, sizeof(full));
    full.header.type = ffx::UpscaleType;
    full.commandList = warp.commands.Get();
    ffx::Resource* resources[] = {&full.color, &full.depth, &full.motionVectors, &full.exposure,
        &full.reactive, &full.transparencyAndComposition, &full.output};
    unsigned i = 0;
    for (auto* resource : resources) {
        // Distinct metadata on every field detects copying the low descriptor or
        // constructing only a subset of the original descriptor in After().
        resource->resource = color;
        resource->description = {2, 4 + i, 64 + i, 48 + i, 1, 1 + i, 0x10u + i, 0x20u + i};
        resource->state = 4 + i;
        ++i;
    }
    full.jitterOffset = {0.3125f, -0.4375f};
    full.motionVectorScale = {-64.0f, -48.0f};
    full.renderSize = {64, 48};
    full.upscaleSize = {128, 96};
    full.enableSharpening = true;
    full.sharpness = 0.375f;
    full.frameTimeDelta = 19.125f;
    full.preExposure = 1.75f;
    full.reset = true;
    full.cameraNear = 0.125f;
    full.cameraFar = 4000.0f;
    full.cameraFovAngleVertical = 1.125f;
    full.viewSpaceToMetersFactor = 1.25f;
    full.flags = 0x12345u;
    return full;
}

void VerifyHandoff(Warp& warp, bool throwOriginal, bool rejectNrOutput) {
    nr030::Adapter adapter;
    adapter.device = warp.device;
    adapter.effectPercent = 0;
    const auto plan = cmp::make_scale_plan({64, 48}, cmp::FixedScale::Percent85);
    const auto originalColor = warp.Texture(plan.input);
    auto correctedColor = warp.Texture(plan.neural);
    nr030::Slot slot;
    slot.baseline = warp.Texture(plan.neural);
    slot.use = std::make_shared<nr030::RecordingUse>();
    // Deliberately omit fullResolved, shader bytecode and descriptor heap.
    // A successful passthrough must not depend on recording a resolve.
    const auto full = FullDispatch(warp, originalColor.Get());
    void* contextValue = &adapter;
    nr030::Frame frame{&slot, &OriginalDispatch, &contextValue, full, plan};
    auto corrected = full;
    corrected.color = nr030::AdaptResource(full.color,
        rejectNrOutput ? slot.baseline.Get() : correctedColor.Get(),
        plan.neural, ffx::FormatRgba16Float);
    corrected.renderSize = {plan.neural.width, plan.neural.height};
    corrected.jitterOffset = {0.125f, -0.25f};
    corrected.motionVectorScale = {-54.0f, -41.0f};
    callback = {&frame.full, frame.context, 0, throwOriginal};
    bool caught = false;
    try {
        const auto result = adapter.After(frame, frame.context, &corrected.header);
        Require(result == 0x25u && frame.result == 0x25u, "Original return value changed");
    } catch (const std::runtime_error& error) {
        if (std::string(error.what()) != "intentional-original-dispatch-throw") throw;
        caught = true;
    }
    Require(caught == throwOriginal, "Original exception was swallowed or newly introduced");
    Require(callback.calls == 1 && frame.called, "Original callback was not called exactly once");
    Require(!adapter.failed.load(), "Passthrough unexpectedly disabled the adapter");
    Require(adapter.resolved.load() == 0 && !slot.resolved,
        "Original passthrough was incorrectly counted as a resolve");
    const UINT64 accepted = rejectNrOutput ? 0u : 1u;
    Require(adapter.nrRecorded.load() == accepted && adapter.originalColorPassthrough.load() == accepted,
        "NR/passthrough counters do not distinguish accepted NR output");
    Require(adapter.fallback.load() == (rejectNrOutput ? 1u : 0u), "Unexpected fallback count");
    Require(slot.use->borrowed.size() == static_cast<std::size_t>(accepted),
        "Corrected NR output reference retention changed");
    if (!rejectNrOutput) {
        auto* raw = correctedColor.Get();
        correctedColor.Reset();
        Require(slot.use->borrowed.front().Get() == raw && raw->GetDesc().Width == plan.neural.width,
            "Corrected NR output was released while its recorded use still exists");
    }
    // A repeated entry after either return OR throw must never dispatch again.
    (void)adapter.After(frame, frame.context, &corrected.header);
    Require(callback.calls == 1 && adapter.failed.load(), "Repeated callback dispatched FSR twice");
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    unsigned passed = 0;
    bool debugEnabled = false;
    std::string failure;
    try {
        Require(argc == 2, "Usage: nr030_handoff_checks <evidence JSON path>");
        Warp warp;
        debugEnabled = warp.debugEnabled;
        VerifyHandoff(warp, false, false); ++passed;
        VerifyHandoff(warp, true, false); ++passed;
        VerifyHandoff(warp, false, true); ++passed;
        std::cout << "PASS: actual After() preserves all 432 original descriptor bytes; callback return/throw "
                     "is forwarded once; duplicate callback blocked; NR output retained; resolve counter stays zero; "
                     "unavailable NR output retains existing fallback behavior.\n";
    } catch (const std::exception& error) {
        failure = error.what();
        std::cerr << "FAIL: " << failure << '\n';
    }
    if (argc == 2) {
        std::ofstream report(std::filesystem::path(argv[1]), std::ios::binary);
        report << "{\n  \"scope\": \"production Adapter::After + real D3D12 WARP descriptions; no inference or gameplay\",\n"
                  "  \"amdGpuGameTested\": false,\n  \"debugLayerEnabled\": "
               << (debugEnabled ? "true" : "false") << ",\n  \"passedCount\": " << passed
               << ",\n  \"success\": " << (failure.empty() ? "true" : "false") << "\n}\n";
        if (!report) return 2;
    }
    return failure.empty() ? 0 : 1;
}
