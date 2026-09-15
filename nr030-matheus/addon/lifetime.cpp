// SPDX-License-Identifier: GPL-3.0-only
#include "lifetime.h"
#include <MinHook.h>
#include <algorithm>
#include <stdexcept>
#include <string>

namespace nr030 {
RecordingLifetime* RecordingLifetime::instance_ = nullptr;
namespace {
void CheckHook(MH_STATUS status, const char* operation) {
    if (status != MH_OK) throw std::runtime_error(std::string(operation) + ": " + MH_StatusToString(status));
}
void* Method(void* object, unsigned index) { return (*reinterpret_cast<void***>(object))[index]; }
}
void RecordingLifetime::Report(const char* message) noexcept { if (log_) log_(message); }

void RecordingLifetime::Initialize(ID3D12Device* device, ID3D12GraphicsCommandList* firstList, LogFn log,
                                   ResetObserverFn observer, void* observerContext) {
    if (instance_) throw std::runtime_error("Recording lifetime initialized twice");
    device_ = device;
    log_ = log;
    resetObserver_ = observer;
    resetObserverContext_ = observerContext;
    D3D12_COMMAND_QUEUE_DESC desc{};
    desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ComPtr<ID3D12CommandQueue> probe;
    if (FAILED(device->CreateCommandQueue(&desc, IID_PPV_ARGS(&probe))))
        throw std::runtime_error("Cannot discover native command queue entry");
    executeTarget_ = Method(probe.Get(), 10);
    resetTarget_ = Method(firstList, 10);
    instance_ = this; // These objects/hooks are pinned for the process lifetime.
    CheckHook(MH_CreateHook(executeTarget_, reinterpret_cast<void*>(&ExecuteHook),
                           reinterpret_cast<void**>(&executeOriginal_)), "Create Execute hook");
    try {
        CheckHook(MH_CreateHook(resetTarget_, reinterpret_cast<void*>(&ResetHook),
                               reinterpret_cast<void**>(&resetOriginal_)), "Create Reset hook");
        CheckHook(MH_QueueEnableHook(executeTarget_), "Queue Execute hook");
        CheckHook(MH_QueueEnableHook(resetTarget_), "Queue Reset hook");
        CheckHook(MH_ApplyQueued(), "Enable lifetime hooks");
    } catch (...) {
        // Do not unload this instance or uninitialize another hook owner's state.
        failed_.store(true);
        throw;
    }
    Report("lifetime hooks installed; queue observation and successful Reset are both required");
}
bool RecordingLifetime::Covers(ID3D12GraphicsCommandList* list) const noexcept {
    return list && resetTarget_ && Method(list, 10) == resetTarget_ && !failed_.load();
}
std::shared_ptr<RecordingUse> RecordingLifetime::Begin(ID3D12GraphicsCommandList* list) {
    std::lock_guard guard(mutex_);
    if (!Covers(list)) throw std::runtime_error("Untracked command-list Reset implementation");
    for (const auto& weak : uses_) {
        if (const auto active = weak.lock(); active && !active->sealed && active->commands.Get() == list)
            throw std::runtime_error("A scaled dispatch already belongs to this command-list recording");
    }
    auto use = std::make_shared<RecordingUse>();
    use->commands = list;
    uses_.erase(std::remove_if(uses_.begin(), uses_.end(), [](const auto& p) { return p.expired(); }), uses_.end());
    uses_.push_back(use);
    return use;
}
bool RecordingLifetime::Reusable(const std::shared_ptr<RecordingUse>& use) {
    if (!use) return true;
    std::lock_guard guard(mutex_);
    if (use->unknown || !use->sealed || use->pendingSubmissions) return false;
    // An unsubmitted list may be discarded by a successful Reset; no GPU can
    // execute the discarded recording. Missing observation after submission is
    // intentionally NOT assumed to be this case: admission requires observation
    // of at least one submit, even for an otherwise sealed recording.
    if (!use->submitted || use->completions.empty()) return false;
    for (const auto& item : use->completions) {
        const auto done = item->fence->GetCompletedValue();
        if (done == UINT64_MAX || done < item->value) return false;
    }
    return true;
}
void STDMETHODCALLTYPE RecordingLifetime::ExecuteHook(ID3D12CommandQueue* queue, UINT n, ID3D12CommandList* const* lists) {
    instance_->Execute(queue, n, lists);
}
HRESULT STDMETHODCALLTYPE RecordingLifetime::ResetHook(ID3D12GraphicsCommandList* list,
                                                       ID3D12CommandAllocator* allocator, ID3D12PipelineState* state) {
    return instance_->Reset(list, allocator, state);
}
HRESULT RecordingLifetime::Reset(ID3D12GraphicsCommandList* list, ID3D12CommandAllocator* allocator,
                                 ID3D12PipelineState* state) {
    // Admission cannot insert a new recording between the successful Reset and
    // the sealing step. No GPU wait is performed while this mutex is held.
    std::lock_guard guard(mutex_);
    const auto result = resetOriginal_(list, allocator, state);
    if (SUCCEEDED(result)) {
        for (auto& weak : uses_) if (auto use = weak.lock(); use && use->commands.Get() == list) use->sealed = true;
    }
    // Observer only takes its own tracker lock and never calls back into lifetime
    // admission. It also watches lists with no RecordingUse (first-frame bypass).
    if (resetObserver_) resetObserver_(resetObserverContext_, list, result);
    return result;
}
void RecordingLifetime::Execute(ID3D12CommandQueue* queue, UINT n, ID3D12CommandList* const* lists) {
    std::vector<std::shared_ptr<RecordingUse>> matched;
    std::shared_ptr<QueueCompletion> ticket;
    try {
        std::lock_guard guard(mutex_);
        if (lists) for (auto& weak : uses_) if (auto use = weak.lock(); use && !use->sealed) {
            bool found = false;
            for (UINT i = 0; i < n; ++i) found |= lists[i] == use->commands.Get();
            if (found) { matched.push_back(use); ++use->pendingSubmissions; }
        }
        if (!matched.empty()) {
            ticket = std::make_shared<QueueCompletion>();
            ticket->queue = queue;
            ticket->value = 1;
            const auto hr = device_->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&ticket->fence));
            if (FAILED(hr)) throw std::runtime_error("Create submission fence failed");
        }
    } catch (...) {
        failed_.store(true);
        std::lock_guard guard(mutex_);
        for (auto& weak : uses_) if (auto use = weak.lock()) use->unknown = true;
        Report("submission tracking allocation failed; all referenced slots retained");
    }

    // The existing NR Execute hook MUST run normally: it publishes the HIP job
    // after its real ExecuteCommandLists. The addon does not wake a worker.
    executeOriginal_(queue, n, lists);

    if (matched.empty()) return;
    const auto signaled = ticket && ticket->fence && SUCCEEDED(queue->Signal(ticket->fence.Get(), ticket->value));
    std::lock_guard guard(mutex_);
    for (auto& use : matched) {
        --use->pendingSubmissions;
        use->submitted = true;
        if (!signaled) { use->unknown = true; failed_.store(true); }
        else {
            // Every observed replay before Reset gets its own queue fence.
            try {
                if (use->completions.size() >= 128)
                    throw std::runtime_error("Unbounded command-list replay rejected");
                use->completions.push_back(ticket);
            }
            catch (...) { use->unknown = true; failed_.store(true); }
        }
    }
    if (!signaled) Report("queue Signal failed; referenced slots retained and addon admission stopped");
}
} // namespace nr030
