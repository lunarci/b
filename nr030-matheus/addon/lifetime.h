// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace nr030 {
using Microsoft::WRL::ComPtr;
struct QueueCompletion {
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12Fence> fence;
    std::uint64_t value = 0;
};
struct RecordingUse {
    // AddRef prevents a released object's address being mistaken for a new list.
    ComPtr<ID3D12GraphicsCommandList> commands;
    std::vector<ComPtr<ID3D12Resource>> borrowed;
    std::vector<std::shared_ptr<QueueCompletion>> completions;
    bool sealed = false;
    bool submitted = false;
    bool unknown = false;
    unsigned pendingSubmissions = 0;
};

// Owns no shader resources. The slot that owns this RecordingUse MUST retain all
// textures/descriptors until Reusable() returns true. Fence completion alone is
// insufficient: successfully Reset must first seal the recorded list for replay.
class RecordingLifetime {
public:
    using LogFn = void(*)(const char*);
    void Initialize(ID3D12Device* device, ID3D12GraphicsCommandList* firstList, LogFn log);
    bool Covers(ID3D12GraphicsCommandList* list) const noexcept;
    std::shared_ptr<RecordingUse> Begin(ID3D12GraphicsCommandList* list);
    bool Reusable(const std::shared_ptr<RecordingUse>& use);
    bool HasUnknownUse() const noexcept { return failed_.load(); }

private:
    using ExecuteFn = void(STDMETHODCALLTYPE*)(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
    using ResetFn = HRESULT(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*, ID3D12CommandAllocator*, ID3D12PipelineState*);
    static void STDMETHODCALLTYPE ExecuteHook(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
    static HRESULT STDMETHODCALLTYPE ResetHook(ID3D12GraphicsCommandList*, ID3D12CommandAllocator*, ID3D12PipelineState*);
    void Execute(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
    HRESULT Reset(ID3D12GraphicsCommandList*, ID3D12CommandAllocator*, ID3D12PipelineState*);
    void Report(const char*) noexcept;

    static RecordingLifetime* instance_;
    ExecuteFn executeOriginal_ = nullptr;
    ResetFn resetOriginal_ = nullptr;
    void* executeTarget_ = nullptr;
    void* resetTarget_ = nullptr;
    ComPtr<ID3D12Device> device_;
    std::recursive_mutex mutex_;
    std::vector<std::weak_ptr<RecordingUse>> uses_;
    std::atomic<bool> failed_{false};
    LogFn log_ = nullptr;
};
} // namespace nr030
