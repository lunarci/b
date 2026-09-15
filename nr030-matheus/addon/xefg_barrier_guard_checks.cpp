// SPDX-License-Identifier: GPL-3.0-only
// Independent production-filter checks and real WARP copy/readback proofs.
// Synthetic call sites/providers only: no OptiScaler DLL, NR, or game executes.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "xefg_barrier_guard.h"
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
namespace guard = nr030::xefg;
constexpr std::uintptr_t SyntheticReturn = 0x12345678u;
constexpr UINT64 Sentinel = 0x123456789abcdef0ull;

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void Check(HRESULT result, const char* message) {
    if (FAILED(result)) throw std::runtime_error(std::string(message) + ": " +
        std::to_string(static_cast<unsigned long>(result)));
}
std::string JsonString(const std::string& value) {
    std::string result = "\"";
    for (const unsigned char ch : value) {
        if (ch == '\\' || ch == '"') { result += '\\'; result += static_cast<char>(ch); }
        else if (ch == '\n') result += "\\n";
        else if (ch == '\r') result += "\\r";
        else if (ch == '\t') result += "\\t";
        else if (ch >= 32) result += static_cast<char>(ch);
    }
    return result + '"';
}
struct TestResult { std::string name; bool passed; std::string error; };
std::vector<TestResult> results;
void Run(const char* name, const std::function<void()>& body) {
    try { body(); results.push_back({name, true, {}}); std::cout << "PASS " << name << '\n'; }
    catch (const std::exception& error) {
        results.push_back({name, false, error.what()});
        std::cerr << "FAIL " << name << ": " << error.what() << '\n';
    }
}

struct CapturedCall {
    ID3D12GraphicsCommandList* list = nullptr;
    UINT count = 0;
    const D3D12_RESOURCE_BARRIER* barriers = nullptr;
    unsigned calls = 0;
};
CapturedCall captured;
void STDMETHODCALLTYPE CaptureBarrier(ID3D12GraphicsCommandList* list, UINT count,
                                       const D3D12_RESOURCE_BARRIER* barriers) {
    captured = {list, count, barriers, captured.calls + 1};
}
void STDMETHODCALLTYPE RealBarrier(ID3D12GraphicsCommandList* list, UINT count,
                                    const D3D12_RESOURCE_BARRIER* barriers) {
    list->ResourceBarrier(count, barriers);
}
D3D12_RESOURCE_BARRIER Transition(ID3D12Resource* resource,
    D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    return barrier;
}
guard::Policy ModernPolicy() { return {true, SyntheticReturn, {1, 3, 1}}; }

class Warp {
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12GraphicsCommandList> commands;
    bool debugEnabled = false;

    Warp() {
        // Enable once before the first device. Re-enabling after a device exists
        // is outside the D3D12 setup contract, including these independent cases.
        static bool layerEnabled = false;
        if (!layerEnabled) {
            ComPtr<ID3D12Debug> debug;
            Check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)), "Debug layer is required for the negative control");
            debug->EnableDebugLayer(); layerEnabled = true;
        }
        debugEnabled = layerEnabled;
        ComPtr<IDXGIFactory4> factory;
        Check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Select WARP");
        DXGI_ADAPTER_DESC1 description{};
        Check(adapter->GetDesc1(&description), "Describe WARP");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected the software WARP adapter");
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)), "Create WARP device");
        Check(device.As(&messages_), "D3D12 debug info queue is required");
        D3D12_COMMAND_QUEUE_DESC queueDescription{};
        queueDescription.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        Check(device->CreateCommandQueue(&queueDescription, IID_PPV_ARGS(&queue_)), "Create direct queue");
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator_)), "Create allocator");
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator_.Get(), nullptr,
            IID_PPV_ARGS(&commands)), "Create direct list");
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence_)), "Create completion fence");
        event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        Require(event_ != nullptr, "Create completion event");
        messages_->ClearStoredMessages();
    }
    ~Warp() { if (open_) (void)commands->Close(); if (event_) CloseHandle(event_); }
    ComPtr<ID3D12Resource> Buffer(D3D12_HEAP_TYPE type, D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES heap{}; heap.Type = type;
        D3D12_RESOURCE_DESC description{};
        description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        description.Width = sizeof(UINT64); description.Height = 1;
        description.DepthOrArraySize = 1; description.MipLevels = 1;
        description.SampleDesc.Count = 1; description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> buffer;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description, state,
            nullptr, IID_PPV_ARGS(&buffer)), "Create test buffer");
        return buffer;
    }
    ComPtr<ID3D12Resource> Upload(UINT64 value) {
        auto resource = Buffer(D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        void* data = nullptr; const D3D12_RANGE empty{0, 0};
        Check(resource->Map(0, &empty, &data), "Map upload");
        std::memcpy(data, &value, sizeof(value)); resource->Unmap(0, nullptr);
        return resource;
    }
    void AssertNoErrors() {
        VisitMessages([](const D3D12_MESSAGE& message) {
            if (message.Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                message.Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)
                throw std::runtime_error(std::string("D3D12 debug validation: ") + message.pDescription);
        });
        messages_->ClearStoredMessages();
    }
    void RequireBeforeAfterMismatch() {
        // Closing validates the recorded state sequence. This malformed list is
        // deliberately never submitted to a GPU queue.
        const HRESULT closeResult = commands->Close(); open_ = false;
        bool found = false;
        VisitMessages([&found](const D3D12_MESSAGE& message) {
            if (message.ID == D3D12_MESSAGE_ID_RESOURCE_BARRIER_BEFORE_AFTER_MISMATCH &&
                (message.Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                 message.Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)) found = true;
        });
        Require(found, "Negative control did not produce the expected resource-state mismatch diagnostic");
        std::cout << "Negative-control debug state mismatch observed; Close HRESULT="
                  << static_cast<unsigned long>(closeResult) << "; malformed list was not submitted.\n";
    }
    UINT64 Readback(ID3D12Resource* source) {
        auto readback = Buffer(D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
        commands->CopyBufferRegion(readback.Get(), 0, source, 0, sizeof(UINT64));
        Check(commands->Close(), "Close valid copy sequence"); open_ = false;
        ID3D12CommandList* lists[]{commands.Get()};
        queue_->ExecuteCommandLists(1, lists);
        Check(queue_->Signal(fence_.Get(), 1), "Signal copy completion");
        if (fence_->GetCompletedValue() < 1) {
            Check(fence_->SetEventOnCompletion(1, event_), "Set completion event");
            Require(WaitForSingleObject(event_, 10000) == WAIT_OBJECT_0, "WARP copy timed out");
        }
        Require(fence_->GetCompletedValue() != UINT64_MAX, "WARP device removed");
        AssertNoErrors();
        const D3D12_RANGE range{0, sizeof(UINT64)}; void* data = nullptr;
        Check(readback->Map(0, &range, &data), "Map copied result");
        UINT64 value = 0; std::memcpy(&value, data, sizeof(value));
        const D3D12_RANGE none{0, 0}; readback->Unmap(0, &none);
        return value;
    }
private:
    template<class Visitor> void VisitMessages(Visitor visitor) {
        for (UINT64 index = 0; index < messages_->GetNumStoredMessagesAllowedByRetrievalFilter(); ++index) {
            SIZE_T size = 0; Check(messages_->GetMessage(index, nullptr, &size), "Read diagnostic size");
            std::vector<unsigned char> bytes(size);
            auto* message = reinterpret_cast<D3D12_MESSAGE*>(bytes.data());
            Check(messages_->GetMessage(index, message, &size), "Read diagnostic"); visitor(*message);
        }
    }
    ComPtr<ID3D12InfoQueue> messages_;
    ComPtr<ID3D12CommandAllocator> allocator_;
    ComPtr<ID3D12CommandQueue> queue_;
    ComPtr<ID3D12Fence> fence_;
    HANDLE event_ = nullptr;
    bool open_ = true;
};

void CheckForward(const guard::Policy& policy, std::uintptr_t caller,
    ID3D12GraphicsCommandList* list, UINT count, const D3D12_RESOURCE_BARRIER* barriers,
    bool suppressed) {
    std::vector<D3D12_RESOURCE_BARRIER> before;
    if (barriers && count) before.assign(barriers, barriers + count);
    captured = {};
    const auto decision = guard::Forward(policy, caller, &CaptureBarrier, list, count, barriers);
    Require((decision == guard::Decision::Suppress) == suppressed, "Unexpected suppression decision");
    Require(captured.calls == (suppressed ? 0u : 1u), "Forwarded callback count differs");
    if (!suppressed) {
        Require(captured.list == list && captured.count == count && captured.barriers == barriers,
            "Forwarded command list/count/barrier pointer identity changed");
    }
    if (!before.empty()) Require(std::memcmp(before.data(), barriers, before.size() * sizeof(before[0])) == 0,
        "The filter mutated caller-owned barrier bytes");
}

void DecisionMatrix(Warp& warp) {
    const auto resource = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto original = Transition(resource.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    Run("exact-modern-provider-terminal-barrier-is-suppressed", [&] {
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &original, true);
    });
    Run("other-return-address-forwards-identical-arguments", [&] {
        CheckForward(ModernPolicy(), SyntheticReturn + 1, warp.commands.Get(), 1, &original, false);
    });
    Run("unverified-policy-forwards-identical-arguments", [&] {
        auto policy = ModernPolicy(); policy.verified = false;
        CheckForward(policy, SyntheticReturn, warp.commands.Get(), 1, &original, false);
    });
    Run("old-and-unknown-provider-versions-are-not-suppressed", [&] {
        for (const guard::Version version : {guard::Version{0, 0, 0}, guard::Version{0, 99, 99}, guard::Version{1, 0, 0}, guard::Version{1, 2, 1}}) {
            auto policy = ModernPolicy(); policy.version = version;
            CheckForward(policy, SyntheticReturn, warp.commands.Get(), 1, &original, false);
        }
    });
    Run("provider-version-boundary-uses-complete-lexicographic-comparison", [&] {
        for (const guard::Version version : {guard::Version{1, 2, 2}, guard::Version{1, 2, 3}, guard::Version{1, 3, 0}, guard::Version{2, 0, 0}}) {
            auto policy = ModernPolicy(); policy.version = version;
            CheckForward(policy, SyntheticReturn, warp.commands.Get(), 1, &original, true);
        }
    });
    Run("null-command-list-is-forwarded-without-dereference", [&] {
        CheckForward(ModernPolicy(), SyntheticReturn, nullptr, 1, &original, false);
    });
    Run("zero-and-multiple-barrier-counts-forward-unchanged", [&] {
        const std::array<D3D12_RESOURCE_BARRIER, 2> pair{original, original};
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 0, &original, false);
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 2, pair.data(), false);
    });
    Run("null-barrier-array-is-forwarded-without-dereference", [&] {
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, nullptr, false);
    });
    Run("nontransition-barriers-remain-identical", [&] {
        for (const auto type : {D3D12_RESOURCE_BARRIER_TYPE_UAV, D3D12_RESOURCE_BARRIER_TYPE_ALIASING}) {
            auto barrier = original; barrier.Type = type;
            CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &barrier, false);
        }
    });
    Run("split-transition-flags-remain-identical", [&] {
        for (const auto flags : {D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY, D3D12_RESOURCE_BARRIER_FLAG_END_ONLY}) {
            auto barrier = original; barrier.Flags = flags;
            CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &barrier, false);
        }
    });
    Run("single-subresource-transition-remains-identical", [&] {
        auto barrier = original; barrier.Transition.Subresource = 0;
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &barrier, false);
    });
    Run("null-transition-resource-remains-identical", [&] {
        auto barrier = original; barrier.Transition.pResource = nullptr;
        CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &barrier, false);
    });
    Run("different-before-or-after-states-remain-identical", [&] {
        auto before = original; before.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
        auto after = original; after.Transition.StateAfter = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
        auto paired = original; paired.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
        paired.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
        for (const auto& barrier : {before, after, paired})
            CheckForward(ModernPolicy(), SyntheticReturn, warp.commands.Get(), 1, &barrier, false);
    });
    warp.AssertNoErrors();
}

void NegativeControl() {
    Warp warp;
    const auto source = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto upload = warp.Upload(Sentinel);
    warp.commands->CopyBufferRegion(source.Get(), 0, upload.Get(), 0, sizeof(UINT64));
    const auto barrier = Transition(source.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    warp.commands->ResourceBarrier(1, &barrier); // resource is now COPY_SOURCE
    warp.commands->ResourceBarrier(1, &barrier); // reproduce the duplicate terminal transition
    warp.RequireBeforeAfterMismatch();
}
void ModernGpuProof() {
    Warp warp;
    const auto source = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto upload = warp.Upload(Sentinel);
    warp.commands->CopyBufferRegion(source.Get(), 0, upload.Get(), 0, sizeof(UINT64));
    const auto barrier = Transition(source.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    warp.commands->ResourceBarrier(1, &barrier); // modern-provider retained state, already COPY_SOURCE
    const auto decision = guard::Forward(ModernPolicy(), SyntheticReturn, &RealBarrier,
        warp.commands.Get(), 1, &barrier);
    Require(decision == guard::Decision::Suppress, "Exact terminal duplicate was forwarded");
    Require(warp.Readback(source.Get()) == Sentinel, "Guarded source copy did not preserve the GPU data");
}
void LegacyGpuProof() {
    Warp warp;
    const auto source = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto upload = warp.Upload(Sentinel);
    warp.commands->CopyBufferRegion(source.Get(), 0, upload.Get(), 0, sizeof(UINT64));
    const auto terminal = Transition(source.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    warp.commands->ResourceBarrier(1, &terminal);
    auto policy = ModernPolicy(); policy.version = {1, 2, 1};
    const auto beginning = Transition(source.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
    Require(guard::Forward(policy, SyntheticReturn - 1, &RealBarrier, warp.commands.Get(), 1, &beginning)
        != guard::Decision::Suppress, "Legacy paired entry transition suppressed");
    warp.commands->CopyBufferRegion(source.Get(), 0, upload.Get(), 0, sizeof(UINT64));
    Require(guard::Forward(policy, SyntheticReturn, &RealBarrier, warp.commands.Get(), 1, &terminal)
        != guard::Decision::Suppress, "Legacy paired terminal transition suppressed");
    Require(warp.Readback(source.Get()) == Sentinel, "Legacy provider copy no longer has a valid state/data path");
}
void OtherCallerGpuProof() {
    Warp warp;
    const auto source = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto upload = warp.Upload(Sentinel);
    warp.commands->CopyBufferRegion(source.Get(), 0, upload.Get(), 0, sizeof(UINT64));
    const auto barrier = Transition(source.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    Require(guard::Forward(ModernPolicy(), SyntheticReturn + 1, &RealBarrier, warp.commands.Get(), 1, &barrier)
        != guard::Decision::Suppress, "Unrelated caller's required transition suppressed");
    Require(warp.Readback(source.Get()) == Sentinel, "Unrelated caller's valid GPU copy was changed");
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    bool debugEnabled = false;
    try {
        Require(argc == 2, "Usage: nr030_xefg_barrier_checks <evidence JSON>");
        Warp matrixWarp; debugEnabled = matrixWarp.debugEnabled; DecisionMatrix(matrixWarp);
        Run("warp-unfiltered-duplicate-produces-debug-state-mismatch", NegativeControl);
        Run("warp-filtered-modern-sequence-has-valid-state-and-exact-readback", ModernGpuProof);
        Run("warp-legacy-paired-transitions-remain-valid-and-unmodified", LegacyGpuProof);
        Run("warp-other-caller-required-transition-is-preserved", OtherCallerGpuProof);
    } catch (const std::exception& error) {
        results.push_back({"test-harness-initialization", false, error.what()});
        std::cerr << "FAIL test-harness-initialization: " << error.what() << '\n';
    }
    unsigned passed = 0; for (const auto& result : results) if (result.passed) ++passed;
    const auto failed = results.size() - passed;
    if (argc == 2) {
        std::ofstream report(std::filesystem::path(argv[1]), std::ios::binary);
        report << "{\n  \"scope\": \"production filter with synthetic caller/provider policy plus real D3D12 WARP copy/readback; no OptiScaler DLL, NR or gameplay\",\n"
                  "  \"amdGpuGameTested\": false,\n  \"debugLayerEnabled\": " << (debugEnabled ? "true" : "false")
               << ",\n  \"passedCount\": " << passed << ",\n  \"failedCount\": " << failed
               << ",\n  \"success\": " << (failed == 0 ? "true" : "false") << ",\n  \"tests\": [\n";
        for (std::size_t index = 0; index < results.size(); ++index) {
            const auto& result = results[index];
            report << "    {\"name\":" << JsonString(result.name) << ",\"passed\":"
                   << (result.passed ? "true" : "false") << ",\"error\":" << JsonString(result.error) << "}"
                   << (index + 1 < results.size() ? ",\n" : "\n");
        }
        report << "  ]\n}\n";
        if (!report) return 2;
    }
    return failed == 0 ? 0 : 1;
}
