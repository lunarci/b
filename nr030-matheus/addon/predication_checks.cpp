// SPDX-License-Identifier: GPL-3.0-only
// Real WARP conditional-copy regression for the production predication guard.
// Reproduces the C7 wait routine's private SetPredication -> disabled sequence;
// this exercises D3D12 state correctness, not NR inference or Cyberpunk output.
#include "predication.h"
#include "lifetime.h"
#include <MinHook.h>
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
constexpr UINT64 Sentinel = 0x1122334455667788ull;
constexpr UINT64 Replacement = 0xaabbccddeeff1020ull;

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void Check(HRESULT result, const char* operation) {
    if (FAILED(result)) throw std::runtime_error(std::string(operation) + ": HRESULT " +
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

class Warp {
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12CommandQueue> queue;
    bool debugEnabled = false;

    Warp() {
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
            debug->EnableDebugLayer();
            debugEnabled = true;
        }
        ComPtr<IDXGIFactory4> factory;
        Check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Select WARP");
        DXGI_ADAPTER_DESC1 description{};
        Check(adapter->GetDesc1(&description), "Describe WARP");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected software WARP adapter");
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
            IID_PPV_ARGS(&device)), "Create WARP device");
        (void)device.As(&messages_);
        D3D12_COMMAND_QUEUE_DESC queueDescription{};
        queueDescription.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        Check(device->CreateCommandQueue(&queueDescription, IID_PPV_ARGS(&queue)), "Create direct queue");
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&allocator)), "Create allocator");
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(),
            nullptr, IID_PPV_ARGS(&commands)), "Create direct list");
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence_)), "Create completion fence");
        event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        Require(event_ != nullptr, "Create completion event failed");
    }
    ~Warp() {
        if (open_) (void)commands->Close();
        if (event_) CloseHandle(event_);
    }
    ComPtr<ID3D12Resource> Buffer(D3D12_HEAP_TYPE heapType, UINT64 size,
                                  D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = heapType;
        D3D12_RESOURCE_DESC description{};
        description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        description.Width = size;
        description.Height = 1;
        description.DepthOrArraySize = 1;
        description.MipLevels = 1;
        description.SampleDesc.Count = 1;
        description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> resource;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description,
            state, nullptr, IID_PPV_ARGS(&resource)), "Create test buffer");
        return resource;
    }
    template<std::size_t N>
    ComPtr<ID3D12Resource> Upload(const std::array<UINT64, N>& values) {
        auto resource = Buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof(values), D3D12_RESOURCE_STATE_GENERIC_READ);
        void* mapped = nullptr;
        const D3D12_RANGE empty{0, 0};
        Check(resource->Map(0, &empty, &mapped), "Map upload buffer");
        std::memcpy(mapped, values.data(), sizeof(values));
        resource->Unmap(0, nullptr);
        return resource;
    }
    void Reset() {
        if (open_) { Check(commands->Close(), "Close discarded recording"); open_ = false; }
        Check(allocator->Reset(), "Reset completed allocator");
        Check(commands->Reset(allocator.Get(), nullptr), "Reset direct list");
        open_ = true;
    }
    void Submit() {
        Check(commands->Close(), "Close conditional-copy recording");
        open_ = false;
        ID3D12CommandList* lists[]{commands.Get()};
        queue->ExecuteCommandLists(1, lists);
        const auto value = ++fenceValue_;
        Check(queue->Signal(fence_.Get(), value), "Signal test completion");
        if (fence_->GetCompletedValue() < value) {
            Check(fence_->SetEventOnCompletion(value, event_), "Set completion event");
            Require(WaitForSingleObject(event_, 10000) == WAIT_OBJECT_0, "WARP conditional-copy timed out");
        }
        Require(fence_->GetCompletedValue() != UINT64_MAX, "WARP device was removed");
        CheckMessages();
    }
    void CheckMessages() {
        if (!messages_) return;
        for (UINT64 i = 0; i < messages_->GetNumStoredMessagesAllowedByRetrievalFilter(); ++i) {
            SIZE_T size = 0;
            Check(messages_->GetMessage(i, nullptr, &size), "Read debug message size");
            std::vector<unsigned char> storage(size);
            auto* message = reinterpret_cast<D3D12_MESSAGE*>(storage.data());
            Check(messages_->GetMessage(i, message, &size), "Read debug message");
            if (message->Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)
                throw std::runtime_error(std::string("D3D12 debug validation: ") + message->pDescription);
        }
        messages_->ClearStoredMessages();
    }
private:
    ComPtr<ID3D12Fence> fence_;
    ComPtr<ID3D12InfoQueue> messages_;
    UINT64 fenceValue_ = 0;
    HANDLE event_ = nullptr;
    bool open_ = true;
};

void SimulateC7PrivateWait(ID3D12GraphicsCommandList* commands, ID3D12Resource* privatePredicate) {
    commands->SetPredication(privatePredicate, 8, D3D12_PREDICATION_OP_EQUAL_ZERO);
    // The real C7 loop dispatches its own wait shader here. Its relevant state
    // mutation is exact: replace the caller's predicate, then disable it.
    commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
}

void SameState(nr030::PredicationTracker& tracker, ID3D12GraphicsCommandList* commands,
               nr030::PredicationState expected) {
    Require(tracker.State(commands) == expected, "Unexpected tracked predication state");
}

void ConditionalCopyProof(Warp& warp, nr030::PredicationTracker& tracker,
                          UINT64 offset, D3D12_PREDICATION_OP operation, bool skipExpected) {
    warp.Reset();
    const auto predicate = warp.Upload(std::array<UINT64, 2>{0, 1});
    const auto replacement = warp.Upload(std::array<UINT64, 1>{Replacement});
    const auto initial = warp.Upload(std::array<UINT64, 4>{Sentinel, Sentinel, Sentinel, Sentinel});
    const auto destination = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, 4 * sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto readback = warp.Buffer(D3D12_HEAP_TYPE_READBACK, 4 * sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    auto* commands = warp.commands.Get();
    commands->CopyBufferRegion(destination.Get(), 0, initial.Get(), 0, 4 * sizeof(UINT64));

    commands->SetPredication(predicate.Get(), offset, operation);
    // Baseline game command obeys the caller's selected skip/pass predicate.
    commands->CopyBufferRegion(destination.Get(), 0, replacement.Get(), 0, sizeof(UINT64));

    SimulateC7PrivateWait(commands, predicate.Get());
    // Unfixed C7 clears the caller predicate; this command incorrectly executes.
    commands->CopyBufferRegion(destination.Get(), sizeof(UINT64), replacement.Get(), 0, sizeof(UINT64));

    commands->SetPredication(predicate.Get(), offset, operation);
    unsigned originalCalls = 0, privateCalls = 0;
    {
        nr030::PredicationScope scope(tracker, commands);
        Require(!scope.Admitted(), "Active predicate must refuse NR without touching GPU state");
        // Production fallback bypasses all private NR work when the caller has
        // a live predicate. It neither resnapshots that buffer nor clears it.
        if (scope.Admitted()) {
            ++privateCalls;
            SimulateC7PrivateWait(commands, predicate.Get());
        }
        SameState(tracker, commands, nr030::PredicationState::Active);
        ++originalCalls;
        commands->CopyBufferRegion(destination.Get(), 2 * sizeof(UINT64), replacement.Get(), 0, sizeof(UINT64));
    }
    Require(originalCalls == 1, "Original work was recorded more than once");
    Require(privateCalls == 0, "Private NR work ran with an active caller predicate");
    SameState(tracker, commands, nr030::PredicationState::Active);
    commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = destination.Get();
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    commands->ResourceBarrier(1, &barrier);
    commands->CopyBufferRegion(readback.Get(), 0, destination.Get(), 0, 4 * sizeof(UINT64));
    warp.Submit();
    void* mapped = nullptr;
    const D3D12_RANGE read{0, 4 * sizeof(UINT64)};
    Check(readback->Map(0, &read, &mapped), "Map conditional-copy evidence");
    std::array<UINT64, 4> actual{};
    std::memcpy(actual.data(), mapped, sizeof(actual));
    const D3D12_RANGE noWrite{0, 0};
    readback->Unmap(0, &noWrite);
    const auto expected = skipExpected ? Sentinel : Replacement;
    Require(actual[0] == expected, "Baseline predicate conditional copy had unexpected result");
    Require(actual[1] == Replacement, "Unfixed control did not demonstrate caller-state corruption");
    Require(actual[2] == expected, "Production guard did not preserve conditional copy output");
    Require(actual[3] == Sentinel, "Private NR work was not skipped");
}

template<std::size_t N>
std::array<UINT64, N> ReadCompleted(Warp& warp, ID3D12Resource* destination) {
    const auto readback = warp.Buffer(D3D12_HEAP_TYPE_READBACK,
        N * sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    warp.commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = destination;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    warp.commands->ResourceBarrier(1, &barrier);
    warp.commands->CopyBufferRegion(readback.Get(), 0, destination, 0, N * sizeof(UINT64));
    warp.Submit();
    void* mapped = nullptr;
    const D3D12_RANGE read{0, N * sizeof(UINT64)};
    Check(readback->Map(0, &read, &mapped), "Map completed GPU values");
    std::array<UINT64, N> actual{};
    std::memcpy(actual.data(), mapped, sizeof(actual));
    const D3D12_RANGE noWrite{0, 0};
    readback->Unmap(0, &noWrite);
    return actual;
}

void KnownDisabledProof(Warp& warp, nr030::PredicationTracker& tracker, bool throwPrivate) {
    warp.Reset();
    const auto predicate = warp.Upload(std::array<UINT64, 1>{0});
    const auto replacement = warp.Upload(std::array<UINT64, 1>{Replacement});
    const auto initial = warp.Upload(std::array<UINT64, 3>{Sentinel, Sentinel, Sentinel});
    const auto destination = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64) * 3,
        D3D12_RESOURCE_STATE_COPY_DEST);
    auto* commands = warp.commands.Get();
    commands->CopyBufferRegion(destination.Get(), 0, initial.Get(), 0, sizeof(UINT64) * 3);
    // Demonstrate a leaked private predicate can suppress a later game command.
    commands->SetPredication(predicate.Get(), 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    commands->CopyBufferRegion(destination.Get(), 0, replacement.Get(), 0, sizeof(UINT64));
    commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    unsigned originalCalls = 0;
    bool caught = false;
    try {
        nr030::PredicationScope scope(tracker, commands);
        Require(scope.Admitted(), "Known disabled caller was rejected");
        commands->CopyBufferRegion(destination.Get(), 2 * sizeof(UINT64), replacement.Get(), 0, sizeof(UINT64));
        commands->SetPredication(predicate.Get(), 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
        // Private bindings must not poison the caller cache.
        SameState(tracker, commands, nr030::PredicationState::Disabled);
        if (throwPrivate) throw std::runtime_error("intentional-private-recording-exception");
        scope.Restore();
        ++originalCalls;
        commands->CopyBufferRegion(destination.Get(), sizeof(UINT64), replacement.Get(), 0, sizeof(UINT64));
    } catch (const std::runtime_error& error) {
        if (std::string(error.what()) != "intentional-private-recording-exception") throw;
        caught = true;
    }
    Require(caught == throwPrivate, "Private exception was swallowed or introduced");
    if (throwPrivate) {
        ++originalCalls;
        commands->CopyBufferRegion(destination.Get(), sizeof(UINT64), replacement.Get(), 0, sizeof(UINT64));
    }
    Require(originalCalls == 1, "Original work was recorded more than once");
    SameState(tracker, commands, nr030::PredicationState::Disabled);
    const auto actual = ReadCompleted<3>(warp, destination.Get());
    Require(actual[0] == Sentinel, "Unfixed private predicate control did not suppress work");
    Require(actual[1] == Replacement, "Known-disabled guard did not restore original work");
    Require(actual[2] == Replacement, "Private work did not execute for known-disabled caller");
}

void MutatedSnapshotProof(Warp& warp, nr030::PredicationTracker& tracker, bool initiallyPass) {
    warp.Reset();
    const auto source = warp.Upload(std::array<UINT64, 1>{Replacement});
    const auto initialValue = warp.Upload(std::array<UINT64, 1>{1});
    const auto initial = warp.Upload(std::array<UINT64, 7>{
        Sentinel, Sentinel, Sentinel, Sentinel, Sentinel, Sentinel, Sentinel});
    const auto predicate = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto activeSeparate = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto nullControl = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto wbiActive = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto wbiNull = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof(UINT64), D3D12_RESOURCE_STATE_COPY_DEST);
    const auto destination = warp.Buffer(D3D12_HEAP_TYPE_DEFAULT, 7 * sizeof(UINT64),
        D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_FEATURE_DATA_D3D12_OPTIONS3 options{};
    ComPtr<ID3D12GraphicsCommandList2> commands2;
    const bool wbiSupported = SUCCEEDED(warp.device->CheckFeatureSupport(
        D3D12_FEATURE_D3D12_OPTIONS3, &options, sizeof(options))) &&
        (options.WriteBufferImmediateSupportFlags & D3D12_COMMAND_LIST_SUPPORT_FLAG_DIRECT) != 0 &&
        SUCCEEDED(warp.commands.As(&commands2));
    D3D12_QUERY_HEAP_DESC queryDescription{};
    queryDescription.Type = D3D12_QUERY_HEAP_TYPE_OCCLUSION;
    queryDescription.Count = 1;
    ComPtr<ID3D12QueryHeap> queries;
    Check(warp.device->CreateQueryHeap(&queryDescription, IID_PPV_ARGS(&queries)), "Create predicate mutation query");
    constexpr auto queryType = D3D12_QUERY_TYPE_BINARY_OCCLUSION;
    auto* commands = warp.commands.Get();
    commands->BeginQuery(queries.Get(), queryType, 0);
    commands->EndQuery(queries.Get(), queryType, 0);
    commands->CopyBufferRegion(predicate.Get(), 0, initialValue.Get(), 0, sizeof(UINT64));
    for (auto* control : {activeSeparate.Get(), nullControl.Get(), wbiActive.Get(), wbiNull.Get()})
        commands->CopyBufferRegion(control, 0, initialValue.Get(), 0, sizeof(UINT64));
    commands->CopyBufferRegion(destination.Get(), 0, initial.Get(), 0, 7 * sizeof(UINT64));
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = predicate.Get();
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PREDICATION;
    commands->ResourceBarrier(1, &barrier);
    commands->SetPredication(predicate.Get(), 0, initiallyPass
        ? D3D12_PREDICATION_OP_EQUAL_ZERO : D3D12_PREDICATION_OP_NOT_EQUAL_ZERO);
    commands->CopyBufferRegion(destination.Get(), 0, source.Get(), 0, sizeof(UINT64));

    // ResolveQueryData is documented as unpredicated. Independently observe
    // this runtime's actual behavior with the same completed query resolved
    // into the bound buffer, an unrelated buffer under the active predicate,
    // and an unrelated buffer after NULL. The mutation assertion stays strict.
    // Keep the bound buffer in COPY_SOURCE to detect an invalid tuple rebind.
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PREDICATION;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
    commands->ResourceBarrier(1, &barrier);
    commands->ResolveQueryData(queries.Get(), queryType, 0, 1, predicate.Get(), 0);
    commands->ResolveQueryData(queries.Get(), queryType, 0, 1, activeSeparate.Get(), 0);
    if (wbiSupported) {
        const D3D12_WRITEBUFFERIMMEDIATE_PARAMETER write{wbiActive->GetGPUVirtualAddress(), 0};
        commands2->WriteBufferImmediate(1, &write, nullptr);
    }
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    commands->ResourceBarrier(1, &barrier);
    {
        nr030::PredicationScope scope(tracker, commands);
        Require(!scope.Admitted(), "Active snapshotted predicate must be passed through untouched");
    }
    commands->CopyBufferRegion(destination.Get(), sizeof(UINT64), source.Get(), 0, sizeof(UINT64));
    commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    commands->ResolveQueryData(queries.Get(), queryType, 0, 1, nullControl.Get(), 0);
    if (wbiSupported) {
        const D3D12_WRITEBUFFERIMMEDIATE_PARAMETER write{wbiNull->GetGPUVirtualAddress(), 0};
        commands2->WriteBufferImmediate(1, &write, nullptr);
    }
    commands->CopyBufferRegion(destination.Get(), 2 * sizeof(UINT64), predicate.Get(), 0, sizeof(UINT64));
    UINT64 outputOffset = 3 * sizeof(UINT64);
    for (auto* control : {activeSeparate.Get(), nullControl.Get(), wbiActive.Get(), wbiNull.Get()}) {
        barrier.Transition.pResource = control;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        commands->ResourceBarrier(1, &barrier);
        commands->CopyBufferRegion(destination.Get(), outputOffset, control, 0, sizeof(UINT64));
        outputOffset += sizeof(UINT64);
    }
    const auto actual = ReadCompleted<7>(warp, destination.Get());
    const auto expected = initiallyPass ? Replacement : Sentinel;
    std::cout << "GPU snapshot evidence: initiallyPass=" << initiallyPass
              << " initialPredicate=1 expected=" << expected
              << " baseline=" << actual[0] << " guarded=" << actual[1]
              << " mutatedPredicate=" << actual[2]
              << " queryActiveSeparate=" << actual[3] << " queryNullControl=" << actual[4]
              << " wbiSupported=" << wbiSupported << " wbiActive=" << actual[5]
              << " wbiNullControl=" << actual[6] << '\n';
    Require(actual[0] == expected && actual[1] == expected,
        "Guard changed a latched predicate after its source buffer mutated");
    Require(actual[4] == 0, "Unpredicated empty-query control did not produce the required zero result");
    if (wbiSupported) Require(actual[6] == 0, "Unpredicated immediate-write control did not produce zero");
    Require(actual[2] == 0,
        "GPU query did not actually mutate the predicate source as intended");
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    std::vector<std::string> passed;
    std::string failure;
    bool debugEnabled = false;
    std::string current = "Initialize real WARP and production hooks";
    try {
        Require(argc == 2, "Usage: nr030_predication_checks <evidence JSON path>");
        Warp warp;
        debugEnabled = warp.debugEnabled;
        const auto initialized = MH_Initialize();
        Require(initialized == MH_OK || initialized == MH_ERROR_ALREADY_INITIALIZED, "Initialize MinHook failed");
        // Production hook owners live until process exit, as in the ASI.
        auto* tracker = new nr030::PredicationTracker();
        tracker->Initialize(warp.commands.Get());
        Require(tracker->Observe(warp.commands.Get()) == nr030::PredicationState::Unknown,
            "Unobserved initial command list was assigned a known state");
        auto* lifetime = new nr030::RecordingLifetime();
        lifetime->Initialize(warp.device.Get(), warp.commands.Get(), nullptr,
            [](void* owner, ID3D12GraphicsCommandList* commands, HRESULT result) noexcept {
                static_cast<nr030::PredicationTracker*>(owner)->NotifyReset(commands, result);
            }, tracker);
        const auto test = [&](const std::string& name, const std::function<void()>& work) {
            current = name;
            try {
                work();
                warp.CheckMessages();
                passed.push_back(name);
                std::cout << "PASS: " << name << '\n';
            } catch (const std::exception& error) {
                const auto detail = name + ": " + error.what();
                if (!failure.empty()) failure += " | ";
                failure += detail;
                std::cerr << "FAIL: " << detail << '\n';
                // Keep the suite failed and retain all assertions, but run
                // independent cases so one failure cannot hide later evidence.
            }
        };
        test("An already-recording unobserved list stays unknown and guard refuses admission", [&] {
            SameState(*tracker, warp.commands.Get(), nr030::PredicationState::Unknown);
            nr030::PredicationScope scope(*tracker, warp.commands.Get());
            Require(!scope.Admitted(), "Unknown predicate state was accepted");
            SameState(*tracker, warp.commands.Get(), nr030::PredicationState::Unknown);
        });
        test("Successful real Reset establishes the documented disabled default", [&] {
            warp.Reset();
            SameState(*tracker, warp.commands.Get(), nr030::PredicationState::Disabled);
        });
        test("Observed non-null predicate refuses NR admission without changing the caller state", [&] {
            const auto predicate = warp.Upload(std::array<UINT64, 2>{0, 1});
            auto* commands = warp.commands.Get();
            commands->SetPredication(predicate.Get(), 8, D3D12_PREDICATION_OP_NOT_EQUAL_ZERO);
            {
                nr030::PredicationScope scope(*tracker, commands);
                Require(!scope.Admitted(), "Active caller predicate was admitted");
            }
            SameState(*tracker, commands, nr030::PredicationState::Active);
            warp.Reset();
            SameState(*tracker, commands, nr030::PredicationState::Disabled);
        });
        test("Failed Reset notification invalidates tracked state and refuses NR admission", [&] {
            const auto predicate = warp.Upload(std::array<UINT64, 1>{0});
            warp.commands->SetPredication(predicate.Get(), 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
            tracker->NotifyReset(warp.commands.Get(), E_FAIL);
            SameState(*tracker, warp.commands.Get(), nr030::PredicationState::Unknown);
            {
                nr030::PredicationScope scope(*tracker, warp.commands.Get());
                Require(!scope.Admitted(), "Failed Reset must not admit private NR work");
            }
            warp.Reset();
        });
        test("Real ClearState establishes the documented disabled predicate state", [&] {
            const auto predicate = warp.Upload(std::array<UINT64, 1>{0});
            warp.commands->SetPredication(predicate.Get(), 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
            warp.commands->ClearState(nullptr);
            SameState(*tracker, warp.commands.Get(), nr030::PredicationState::Disabled);
            warp.Reset();
        });
        test("Known NULL restores disabled state even if private work leaves a predicate bound", [&] {
            const auto predicate = warp.Upload(std::array<UINT64, 2>{0, 1});
            auto* commands = warp.commands.Get();
            {
                nr030::PredicationScope scope(*tracker, commands);
                Require(scope.Admitted(), "Known disabled state was rejected");
                commands->SetPredication(predicate.Get(), 8, D3D12_PREDICATION_OP_NOT_EQUAL_ZERO);
            }
            SameState(*tracker, commands, nr030::PredicationState::Disabled);
            warp.Reset();
        });
        test("Restore releases suppression so original changes persist after scope destruction", [&] {
            const auto predicate = warp.Upload(std::array<UINT64, 2>{0, 1});
            auto* commands = warp.commands.Get();
            commands->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
            {
                nr030::PredicationScope scope(*tracker, commands);
                Require(scope.Admitted(), "Known state was rejected");
                SimulateC7PrivateWait(commands, predicate.Get());
                scope.Restore();
                commands->SetPredication(predicate.Get(), 8, D3D12_PREDICATION_OP_NOT_EQUAL_ZERO);
            }
            SameState(*tracker, commands, nr030::PredicationState::Active);
            warp.Reset();
        });
        test("GPU EQUAL_ZERO conditional-copy control is broken without guard and preserved with guard", [&] {
            ConditionalCopyProof(warp, *tracker, 0, D3D12_PREDICATION_OP_EQUAL_ZERO, true);
        });
        test("GPU NOT_EQUAL_ZERO at nonzero offset preserves the actual conditional-copy result", [&] {
            ConditionalCopyProof(warp, *tracker, 8, D3D12_PREDICATION_OP_NOT_EQUAL_ZERO, true);
        });
        test("GPU active predicate that permits work still permits the original conditional copy", [&] {
            ConditionalCopyProof(warp, *tracker, 8, D3D12_PREDICATION_OP_EQUAL_ZERO, false);
        });
        test("GPU skip snapshot survives mutation and retransition of its original predicate source", [&] {
            MutatedSnapshotProof(warp, *tracker, false);
        });
        test("GPU pass snapshot survives mutation and retransition of its original predicate source", [&] {
            MutatedSnapshotProof(warp, *tracker, true);
        });
        test("GPU known-disabled scope clears private predicate before one original callback", [&] {
            KnownDisabledProof(warp, *tracker, false);
        });
        test("GPU known-disabled scope clears private predicate on exception before one fallback callback", [&] {
            KnownDisabledProof(warp, *tracker, true);
        });
    } catch (const std::exception& error) {
        failure = current + ": " + error.what();
        std::cerr << "FAIL: " << failure << '\n';
    }
    if (argc == 2) {
        std::ofstream output(std::filesystem::path(argv[1]), std::ios::binary);
        output << "{\n  \"scope\": \"production predication tracker + guard + Reset observer with real WARP conditional copies\",\n"
                  "  \"amdGpuGameTested\": false,\n  \"debugLayerEnabled\": " << (debugEnabled ? "true" : "false")
               << ",\n  \"passedCount\": " << passed.size() << ",\n  \"passed\": [";
        for (std::size_t i = 0; i < passed.size(); ++i) output << (i ? ", " : "") << JsonString(passed[i]);
        output << "],\n  \"failure\": " << JsonString(failure)
               << ",\n  \"success\": " << (failure.empty() ? "true" : "false") << "\n}\n";
        if (!output) return 2;
    }
    return failure.empty() ? 0 : 1;
}
