// SPDX-License-Identifier: GPL-3.0-only
#include "predication.h"
#include <MinHook.h>
#include <stdexcept>
#include <string>

namespace nr030 {
PredicationTracker* PredicationTracker::instance_ = nullptr;
thread_local PredicationScope* PredicationScope::current_ = nullptr;
namespace {
void* Method(void* object, unsigned index) { return (*reinterpret_cast<void***>(object))[index]; }
void CheckHook(MH_STATUS result, const char* operation) {
    if (result != MH_OK) throw std::runtime_error(std::string(operation) + ": " + MH_StatusToString(result));
}
}
void PredicationTracker::Initialize(ID3D12GraphicsCommandList* firstList) {
    if (instance_ || !firstList) throw std::runtime_error("Predication tracker initialization rejected");
    setTarget_ = Method(firstList, 55);
    clearTarget_ = Method(firstList, 11);
    entries_[0].list = firstList; // Started mid-recording: state remains Unknown.
    trackedLists_.store(1);
    instance_ = this; // Hook owner is pinned for process lifetime, game lists are not.
    CheckHook(MH_CreateHook(setTarget_, reinterpret_cast<void*>(&SetHook),
        reinterpret_cast<void**>(&setOriginal_)), "Create SetPredication hook");
    CheckHook(MH_CreateHook(clearTarget_, reinterpret_cast<void*>(&ClearHook),
        reinterpret_cast<void**>(&clearOriginal_)), "Create ClearState hook");
    CheckHook(MH_QueueEnableHook(setTarget_), "Queue SetPredication hook");
    CheckHook(MH_QueueEnableHook(clearTarget_), "Queue ClearState hook");
    CheckHook(MH_ApplyQueued(), "Enable predication observation");
    ready_ = true;
}
bool PredicationTracker::Covers(ID3D12GraphicsCommandList* list) const noexcept {
    return ready_ && list && list->GetType() == D3D12_COMMAND_LIST_TYPE_DIRECT &&
        Method(list, 55) == setTarget_ && Method(list, 11) == clearTarget_;
}
PredicationState PredicationTracker::Observe(ID3D12GraphicsCommandList* list) noexcept {
    if (!Covers(list)) return PredicationState::Untracked;
    std::lock_guard guard(mutex_);
    Entry* empty = nullptr;
    for (auto& entry : entries_) {
        if (entry.list == list) return entry.state;
        if (!entry.list && !empty) empty = &entry;
    }
    if (!empty) { ++capacityBypass_; return PredicationState::Untracked; }
    empty->list = list;
    empty->state = PredicationState::Unknown;
    ++trackedLists_;
    return empty->state;
}
PredicationState PredicationTracker::State(ID3D12GraphicsCommandList* list) const noexcept {
    if (!Covers(list)) return PredicationState::Untracked;
    std::lock_guard guard(mutex_);
    for (const auto& entry : entries_) if (entry.list == list) return entry.state;
    return PredicationState::Unknown;
}
void PredicationTracker::NotifyReset(ID3D12GraphicsCommandList* list, HRESULT result) noexcept {
    std::lock_guard guard(mutex_);
    for (auto& entry : entries_) if (entry.list == list) {
        if (SUCCEEDED(result)) { entry.state = PredicationState::Disabled; ++resets_; }
        else entry.state = PredicationState::Unknown;
        return;
    }
}
void PredicationTracker::ResetObserver(void* tracker, ID3D12GraphicsCommandList* list, HRESULT result) noexcept {
    static_cast<PredicationTracker*>(tracker)->NotifyReset(list, result);
}
void PredicationTracker::RecordSet(ID3D12GraphicsCommandList* list, bool active, bool clear) noexcept {
    if (PredicationScope::IsPrivate(list)) { ++privateSets_; return; }
    std::lock_guard guard(mutex_);
    for (auto& entry : entries_) if (entry.list == list) {
        entry.state = active ? PredicationState::Active : PredicationState::Disabled;
        if (clear) ++clears_; else ++sets_;
        return;
    }
}
void STDMETHODCALLTYPE PredicationTracker::SetHook(ID3D12GraphicsCommandList* list, ID3D12Resource* buffer,
                                                  UINT64 offset, D3D12_PREDICATION_OP operation) {
    instance_->setOriginal_(list, buffer, offset, operation);
    instance_->RecordSet(list, buffer != nullptr, false);
}
void STDMETHODCALLTYPE PredicationTracker::ClearHook(ID3D12GraphicsCommandList* list, ID3D12PipelineState* state) {
    instance_->clearOriginal_(list, state);
    instance_->RecordSet(list, false, true);
}
PredicationCounters PredicationTracker::Counters() const noexcept {
    return {sets_.load(), resets_.load(), clears_.load(), privateSets_.load(), restores_.load(),
            trackedLists_.load(), capacityBypass_.load()};
}
PredicationScope::PredicationScope(PredicationTracker& tracker, ID3D12GraphicsCommandList* list) noexcept
    : tracker_(&tracker), list_(list), state_(tracker.Observe(list)) {
    if (!Admitted()) return; // NO command or binding change on either bypass path.
    previous_ = current_;
    current_ = this;
    active_ = true;
}
bool PredicationScope::IsPrivate(ID3D12GraphicsCommandList* list) noexcept {
    for (auto* scope = current_; scope; scope = scope->previous_)
        if (scope->active_ && scope->list_ == list) return true;
    return false;
}
void PredicationScope::Restore() noexcept {
    if (!active_) return;
    // Admitted only from an observed NULL predicate. Restoring NULL cannot
    // re-snapshot an application buffer or require any application resource state.
    list_->SetPredication(nullptr, 0, D3D12_PREDICATION_OP_EQUAL_ZERO);
    ++tracker_->restores_;
    current_ = previous_;
    active_ = false;
}
} // namespace nr030
