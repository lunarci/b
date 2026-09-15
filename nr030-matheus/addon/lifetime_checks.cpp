// SPDX-License-Identifier: GPL-3.0-only
// Exercises the production lifetime tracker through real MinHook/D3D12 calls.
// WARP validates submission ownership; it does not emulate the NR game engine.
#include "lifetime.h"
#include <MinHook.h>
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using nr030::RecordingLifetime;
using nr030::RecordingUse;
using Microsoft::WRL::ComPtr;

void Require(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
void Check(HRESULT value, const char* message) {
    if (FAILED(value)) throw std::runtime_error(std::string(message) + ": HRESULT " +
                                               std::to_string(static_cast<unsigned long>(value)));
}
struct Results {
    std::vector<std::string> passed;
    std::string failed;
    void Pass(const char* name) {
        passed.emplace_back(name);
        std::cout << "PASS: " << name << '\n';
    }
};
std::string JsonString(const std::string& value) {
    std::string result = "\"";
    for (const auto c : value) {
        if (c == '\\' || c == '"') result += '\\';
        if (c == '\n') result += "\\n";
        else if (c == '\r') result += "\\r";
        else result += c;
    }
    return result + '"';
}
void Save(const std::filesystem::path& path, const Results& results, bool debugEnabled) {
    std::ofstream file(path, std::ios::binary);
    Require(bool(file), "Cannot create lifetime evidence JSON");
    file << "{\n  \"scope\": \"production lifetime.cpp + MinHook + real D3D12 WARP queues\",\n"
            "  \"amdGpuGameTested\": false,\n  \"debugLayerEnabled\": "
         << (debugEnabled ? "true" : "false") << ",\n  \"passedCount\": "
         << results.passed.size() << ",\n  \"passed\": [";
    for (std::size_t i = 0; i < results.passed.size(); ++i)
        file << (i ? ", " : "") << JsonString(results.passed[i]);
    file << "],\n  \"failure\": " << JsonString(results.failed) << "\n}\n";
    Require(bool(file), "Cannot write lifetime evidence JSON");
}

struct Commands {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;
    Commands(ID3D12Device* device) {
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&allocator)), "Create direct allocator");
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
            allocator.Get(), nullptr, IID_PPV_ARGS(&list)), "Create direct command list");
    }
    void Close() { Check(list->Close(), "Close command recording"); }
};

// A test can deliberately hold one queue behind a CPU fence. Destruction always
// releases it, including assertion failure, so tests cannot strand a WARP queue.
struct Gate {
    ComPtr<ID3D12Fence> fence;
    Gate(ID3D12Device* device, ID3D12CommandQueue* queue) {
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "Create queue gate");
        Check(queue->Wait(fence.Get(), 1), "Insert nonblocking queue gate");
    }
    ~Gate() { if (fence) (void)fence->Signal(1); }
    void Open() { Check(fence->Signal(1), "Release queue gate"); }
};

class Warp {
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> firstQueue, secondQueue;
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
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Select WARP adapter");
        DXGI_ADAPTER_DESC1 description{};
        Check(adapter->GetDesc1(&description), "Read WARP adapter description");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected real software WARP device");
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
            IID_PPV_ARGS(&device)), "Create WARP device");
        (void)device.As(&messages_);
        D3D12_COMMAND_QUEUE_DESC desc{};
        desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        Check(device->CreateCommandQueue(&desc, IID_PPV_ARGS(&firstQueue)), "Create first direct queue");
        Check(device->CreateCommandQueue(&desc, IID_PPV_ARGS(&secondQueue)), "Create second direct queue");
    }

    void Execute(ID3D12CommandQueue* queue, ID3D12GraphicsCommandList* list) {
        ID3D12CommandList* lists[]{list};
        queue->ExecuteCommandLists(1, lists);
    }
    void Drain(ID3D12CommandQueue* queue) {
        ComPtr<ID3D12Fence> fence;
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "Create drain fence");
        Check(queue->Signal(fence.Get(), 1), "Signal drain fence");
        if (fence->GetCompletedValue() < 1) {
            const HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            Require(event != nullptr, "Create drain event failed");
            const auto armed = fence->SetEventOnCompletion(1, event);
            const auto wait = SUCCEEDED(armed) ? WaitForSingleObject(event, 5000) : WAIT_FAILED;
            CloseHandle(event);
            Check(armed, "Arm drain event");
            Require(wait == WAIT_OBJECT_0, "WARP queue did not drain within five seconds");
        }
        const auto completed = fence->GetCompletedValue();
        Require(completed != UINT64_MAX && completed >= 1, "Drain fence failed or device was removed");
    }
    ComPtr<ID3D12Resource> Buffer(D3D12_HEAP_TYPE heapType, D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = heapType;
        heap.CreationNodeMask = 1;
        heap.VisibleNodeMask = 1;
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = 256;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> resource;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            state, nullptr, IID_PPV_ARGS(&resource)), "Create test buffer");
        return resource;
    }
    void CheckMessages() {
        if (!messages_) return;
        for (UINT64 i = 0; i < messages_->GetNumStoredMessagesAllowedByRetrievalFilter(); ++i) {
            SIZE_T size = 0;
            Check(messages_->GetMessage(i, nullptr, &size), "Read D3D12 message size");
            std::vector<unsigned char> bytes(size);
            auto* message = reinterpret_cast<D3D12_MESSAGE*>(bytes.data());
            Check(messages_->GetMessage(i, message, &size), "Read D3D12 message");
            if (message->Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)
                throw std::runtime_error(std::string("D3D12 debug validation: ") + message->pDescription);
        }
        messages_->ClearStoredMessages();
    }
private:
    ComPtr<ID3D12InfoQueue> messages_;
};

void Trace(const char* message) { std::cout << "lifetime: " << message << '\n'; }
} // namespace

int wmain(int argc, wchar_t** argv) {
    const auto report = argc > 1 ? std::filesystem::path(argv[1]) : std::filesystem::path(L"lifetime_results.json");
    Results results;
    bool debugEnabled = false;
    try {
        Warp gpu;
        debugEnabled = gpu.debugEnabled;
        Commands copied(gpu.device.Get());
        Require(MH_Initialize() == MH_OK, "Initialize real MinHook failed");
        // Production tracker/hook targets are deliberately pinned until process
        // exit. This test follows the same ownership contract as the ASI.
        auto* lifetime = new RecordingLifetime();
        lifetime->Initialize(gpu.device.Get(), copied.list.Get(), &Trace);
        Require(lifetime->Covers(copied.list.Get()), "Native Reset hook does not cover the test list");
        results.Pass("native_direct_command_list_is_covered");

        auto copyUse = lifetime->Begin(copied.list.Get());
        auto upload = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        auto readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
        std::array<unsigned char, 256> expected{};
        for (std::size_t i = 0; i < expected.size(); ++i)
            expected[i] = static_cast<unsigned char>((i * 37 + 11) & 255);
        void* mapped = nullptr;
        const D3D12_RANGE noRead{0, 0};
        Check(upload->Map(0, &noRead, &mapped), "Map upload buffer");
        std::memcpy(mapped, expected.data(), expected.size());
        upload->Unmap(0, nullptr);
        copyUse->borrowed.emplace_back(upload);
        copyUse->borrowed.emplace_back(readback);
        copied.list->CopyBufferRegion(readback.Get(), 0, upload.Get(), 0, expected.size());
        upload.Reset();
        readback.Reset(); // RecordingUse now owns the application's buffer references.
        Require(!lifetime->Reusable(copyUse), "An open recording was released before submission");
        results.Pass("unsubmitted_open_recording_is_retained");
        copied.Close();
        gpu.Execute(gpu.firstQueue.Get(), copied.list.Get());
        Require(copyUse->submitted && copyUse->pendingSubmissions == 0 && copyUse->completions.size() == 1,
                "ExecuteCommandLists hook did not record the actual submission");
        results.Pass("real_execute_hook_records_submission_fence");
        gpu.Drain(gpu.firstQueue.Get());
        Require(!lifetime->Reusable(copyUse), "Fence completion allowed replayable recording reuse");
        results.Pass("completed_fence_without_reset_is_retained");
        const D3D12_RANGE allRead{0, expected.size()};
        Check(copyUse->borrowed[1]->Map(0, &allRead, &mapped), "Map retained readback buffer");
        const bool equal = std::memcmp(mapped, expected.data(), expected.size()) == 0;
        copyUse->borrowed[1]->Unmap(0, &noRead);
        Require(equal, "Borrowed buffers did not survive a real GPU copy");
        results.Pass("borrowed_resources_survive_actual_gpu_copy");
        Check(copied.allocator->Reset(), "Reset completed copy allocator");
        Check(copied.list->Reset(copied.allocator.Get(), nullptr), "Reset completed copy list");
        Require(copyUse->sealed && lifetime->Reusable(copyUse), "Completed and Reset recording was not reusable");
        results.Pass("completed_fence_and_successful_reset_are_reusable");
        copyUse.reset();
        gpu.CheckMessages();

        {
            Commands delayed(gpu.device.Get());
            Commands spare(gpu.device.Get());
            spare.Close();
            auto use = lifetime->Begin(delayed.list.Get());
            delayed.Close();
            Gate gate(gpu.device.Get(), gpu.firstQueue.Get());
            gpu.Execute(gpu.firstQueue.Get(), delayed.list.Get());
            Check(delayed.list->Reset(spare.allocator.Get(), nullptr), "Reset pending list with a fresh allocator");
            Require(use->sealed && use->submitted && !lifetime->Reusable(use),
                    "Successful Reset released a recording while the actual GPU queue remained gated");
            results.Pass("reset_before_gpu_completion_is_retained");
            gate.Open();
            gpu.Drain(gpu.firstQueue.Get());
            Require(lifetime->Reusable(use), "Opening the queue gate did not retire the sealed recording");
            results.Pass("gated_recording_retires_only_after_actual_completion");
            gpu.CheckMessages();
        }

        {
            Commands discarded(gpu.device.Get());
            auto use = lifetime->Begin(discarded.list.Get());
            discarded.Close();
            Check(discarded.list->Reset(discarded.allocator.Get(), nullptr), "Reset unsubmitted test list");
            Require(use->sealed && !use->submitted && !lifetime->Reusable(use),
                    "Missing submission observation was silently treated as safe completion");
            results.Pass("unobserved_submission_remains_conservatively_retained");
            gpu.CheckMessages();
        }

        {
            Commands replayed(gpu.device.Get());
            Commands spare(gpu.device.Get());
            spare.Close();
            auto use = lifetime->Begin(replayed.list.Get());
            replayed.Close();
            // D3D12 permits the driver to patch submitted command lists, so
            // even an empty list must finish before it is submitted again.
            // Complete the first queue, then retain a replay on the second.
            gpu.Execute(gpu.firstQueue.Get(), replayed.list.Get());
            gpu.Drain(gpu.firstQueue.Get());
            Gate secondGate(gpu.device.Get(), gpu.secondQueue.Get());
            gpu.Execute(gpu.secondQueue.Get(), replayed.list.Get());
            Require(use->completions.size() == 2 && use->pendingSubmissions == 0,
                    "A replay on a second actual queue was not observed");
            results.Pass("replays_on_two_actual_queues_are_both_tracked");
            Check(replayed.list->Reset(spare.allocator.Get(), nullptr), "Seal cross-queue replay recording");
            Require(!lifetime->Reusable(use), "One completed queue released work still pending on another queue");
            results.Pass("one_completed_queue_cannot_release_another_pending_replay");
            secondGate.Open();
            gpu.Drain(gpu.secondQueue.Get());
            Require(lifetime->Reusable(use), "All completed replay queues did not retire the sealed recording");
            results.Pass("all_replay_fences_and_reset_allow_reuse");
            gpu.CheckMessages();
        }
        Require(!lifetime->HasUnknownUse(), "Native lifetime tracking unexpectedly entered a failed state");
        results.Pass("native_submission_tracking_remains_healthy");
        Save(report, results, debugEnabled);
        std::cout << "Scope: actual WARP queues, production lifetime hooks, resource references and retirement; "
                     "no AMD NR inference, game execution, FPS or map-transition measurement.\n";
        return 0;
    } catch (const std::exception& error) {
        results.failed = error.what();
        std::cerr << "FAIL: " << error.what() << '\n';
        try { Save(report, results, debugEnabled); } catch (...) {}
        return 1;
    }
}
