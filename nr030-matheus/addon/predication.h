// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d12.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>

namespace nr030 {
enum class PredicationState { Unknown, Disabled, Active, Untracked };
struct PredicationCounters {
    std::uint64_t observedSets = 0, observedResets = 0, observedClears = 0;
    std::uint64_t privateSets = 0, privateRestores = 0;
    std::uint64_t trackedLists = 0, capacityBypass = 0;
};
class PredicationScope;

// There is no D3D12 getter for the GPU-latched predicate. Only an observed NULL
// binding/Reset/ClearState permits private NR work. In particular, saving and
// rebinding a non-NULL buffer tuple would re-snapshot its value and is unsafe.
class PredicationTracker {
public:
    void Initialize(ID3D12GraphicsCommandList* firstList);
    PredicationState Observe(ID3D12GraphicsCommandList* list) noexcept;
    PredicationState State(ID3D12GraphicsCommandList* list) const noexcept;
    void NotifyReset(ID3D12GraphicsCommandList* list, HRESULT result) noexcept;
    static void ResetObserver(void* tracker, ID3D12GraphicsCommandList* list, HRESULT result) noexcept;
    PredicationCounters Counters() const noexcept;

private:
    friend class PredicationScope;
    using SetFn = void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*, ID3D12Resource*, UINT64, D3D12_PREDICATION_OP);
    using ClearFn = void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*, ID3D12PipelineState*);
    static void STDMETHODCALLTYPE SetHook(ID3D12GraphicsCommandList*, ID3D12Resource*, UINT64, D3D12_PREDICATION_OP);
    static void STDMETHODCALLTYPE ClearHook(ID3D12GraphicsCommandList*, ID3D12PipelineState*);
    bool Covers(ID3D12GraphicsCommandList*) const noexcept;
    void RecordSet(ID3D12GraphicsCommandList*, bool active, bool clear) noexcept;
    struct Entry {
        // Non-owning identity only, never dereferenced from this cache. Newly
        // created DIRECT lists begin Disabled; all covered SetPredication calls
        // are observed. Reused stale Active/Unknown can only refuse private work.
        // Do not pin game lists/allocator graphs while already under VRAM pressure.
        ID3D12GraphicsCommandList* list = nullptr;
        PredicationState state = PredicationState::Unknown;
    };
    static PredicationTracker* instance_;
    SetFn setOriginal_ = nullptr;
    ClearFn clearOriginal_ = nullptr;
    void* setTarget_ = nullptr;
    void* clearTarget_ = nullptr;
    bool ready_ = false;
    mutable std::mutex mutex_;
    std::array<Entry, 64> entries_{};
    std::atomic<std::uint64_t> sets_{0}, resets_{0}, clears_{0}, privateSets_{0}, restores_{0};
    std::atomic<std::uint64_t> trackedLists_{0}, capacityBypass_{0};
};

class PredicationScope {
public:
    PredicationScope(PredicationTracker& tracker, ID3D12GraphicsCommandList* list) noexcept;
    ~PredicationScope() { Restore(); }
    PredicationScope(const PredicationScope&) = delete;
    PredicationScope& operator=(const PredicationScope&) = delete;
    bool Admitted() const noexcept { return state_ == PredicationState::Disabled; }
    PredicationState State() const noexcept { return state_; }
    // Must run BEFORE the original FFX callback. Never restore after that callback:
    // its own state changes belong to the application and must remain observable.
    void Restore() noexcept;
private:
    friend class PredicationTracker;
    static bool IsPrivate(ID3D12GraphicsCommandList*) noexcept;
    static thread_local PredicationScope* current_;
    PredicationTracker* tracker_;
    ID3D12GraphicsCommandList* list_;
    PredicationState state_;
    PredicationScope* previous_ = nullptr;
    bool active_ = false;
};
} // namespace nr030
