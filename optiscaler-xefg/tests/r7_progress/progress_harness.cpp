#include <framegen/FGWorkGate.h>
#include <misc/XeFGProgressDiagnostics.h>
#include <misc/LongSessionTiming.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <future>
#include <iostream>
#include <latch>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
using UINT = unsigned;
using UINT64 = uint64_t;
using HRESULT = int32_t;
using HANDLE = void*;
using IUnknown = void;
constexpr HRESULT S_OK = 0, E_FAIL = -1;
constexpr HRESULT DXGI_ERROR_DEVICE_REMOVED = static_cast<int32_t>(0x887A0005u);
constexpr unsigned D3D12_FENCE_FLAG_NONE = 0;
#define SUCCEEDED(result) ((result) >= 0)
#define FAILED(result) ((result) < 0)
#define IID_PPV_ARGS(pointer) pointer
#define LOG_WARN(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define SAFE_RELEASE(pointer) do { if ((pointer) != nullptr) { (pointer)->Release(); (pointer) = nullptr; } } while(false)
namespace XeFGDiagnostics {
inline std::atomic<uint64_t> testClock { 1 };
inline uint64_t WorkNowMs() { return testClock.load(); }
}
struct State {
    bool isShuttingDown = false;
    static State& Instance() { static State state; return state; }
};
struct ID3D12Fence {
    std::atomic<uint64_t> completed { 0 };
    std::atomic<unsigned> refs { 1 }, reads { 0 }, releases { 0 };
    uint64_t GetCompletedValue() { assert(refs != 0); ++reads; return completed.load(); }
    unsigned Release() { ++releases; assert(refs != 0); return --refs; }
    void SetName(const wchar_t*) {}
    HRESULT SetEventOnCompletion(UINT64, HANDLE) { assert(false && "progress observation must not wait on an event"); return E_FAIL; }
};
struct ID3D12Device {
    std::array<ID3D12Fence, 32> fences;
    unsigned created = 0, createCalls = 0, releases = 0;
    uint64_t createDelayMs = 0;
    HRESULT createResult = S_OK, removedResult = S_OK;
    HRESULT CreateFence(UINT64 initial, unsigned flags, ID3D12Fence** output) {
        ++createCalls; assert(initial == 0 && flags == D3D12_FENCE_FLAG_NONE);
        XeFGDiagnostics::testClock.fetch_add(createDelayMs);
        *output = nullptr;
        if (FAILED(createResult)) return createResult;
        assert(created < fences.size()); *output = &fences[created++]; return createResult;
    }
    HRESULT GetDeviceRemovedReason() { return removedResult; }
    unsigned Release() { ++releases; return 1; }
};
struct ID3D12CommandQueue {
    ID3D12Device* device = nullptr;
    unsigned refs = 1, releases = 0, signals = 0;
    HRESULT signalResult = S_OK;
    struct Desc { unsigned Type = 0; } desc;
    ID3D12Fence* lastFence = nullptr;
    uint64_t lastValue = 0;
    std::latch* signalEntered = nullptr;
    std::latch* signalContinue = nullptr;
    unsigned AddRef() { return ++refs; }
    unsigned Release() { ++releases; assert(refs != 0); return --refs; }
    Desc GetDesc() const { return desc; }
    HRESULT GetDevice(ID3D12Device** output) { *output = device; return device ? S_OK : E_FAIL; }
    HRESULT Signal(ID3D12Fence* fence, UINT64 value) {
        assert(refs != 0 && fence != nullptr && fence->refs != 0);
        ++signals; lastFence = fence; lastValue = value;
        if (signalEntered) signalEntered->count_down();
        if (signalContinue) signalContinue->wait();
        return signalResult;
    }
};
inline bool CheckForRealObject(const char*, ID3D12CommandQueue*, IUnknown**) { return false; }
inline void CloseHandle(HANDLE) {}
constexpr size_t BUFFER_COUNT = 4;
struct XeFG_Dx12 {
    FGWorkGate _submissionGate;
    auto AcquireSubmissionWork() { return _submissionGate.TryEnter(); }
    static constexpr size_t MaxLifetimeQueues = 8;
    // ACTUAL_QUEUE_ENTRY
    LifetimeQueue _lifetimeQueues[MaxLifetimeQueues] {};
    size_t _lifetimeQueueCount = 0;
    std::mutex _lifetimeQueueMutex, _gpuProgressMutex;
    std::atomic<uint64_t> _gpuProgressBusy { 0 };
    uint64_t _gpuProgressContextId = 1, _nextGpuProgressPollMs = 0;
    bool _queueTrackingComplete = true, _objectsDrained = false;
    ID3D12Device* _device = nullptr;
    std::atomic<bool> _lifecycleFailed { false };
    void* _swapChainContext = reinterpret_cast<void*>(1);
    struct CopyInfo { uint64_t bytes = 0; bool known = false; };
    std::mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<int, ID3D12Fence*> _resourceCopy[BUFFER_COUNT];
    std::unordered_map<int, CopyInfo> _copyAllocationInfo[BUFFER_COUNT];
    struct ResourceDiagnostics { void OnRelease(uint64_t, bool) {} } _resourceDiagnostics;
    ID3D12Fence* _uiFence = nullptr;
    ID3D12Fence* _scFence = nullptr;
    HANDLE _uiFenceEvent = nullptr, _scFenceEvent = nullptr;
    UINT64 _uiFenceValue = 0;
    ID3D12CommandQueue* _gameCommandQueue = nullptr;
    std::unique_ptr<int> _renderUI, _hudlessCompare, _mvFlip, _depthFlip, _depthInvert;
    unsigned commandReleases = 0;
    void ReleaseCommandObjects() { ++commandReleases; }
    void ReleaseObjects();
    void TrackLifetimeQueue(ID3D12CommandQueue*);
    void ObserveSubmittedQueue(ID3D12CommandQueue*);
    void PollGpuProgress();
    void PollGpuProgressLocked(uint64_t);
    void PublishGpuProgressLocked(uint64_t);
};
// ACTUAL_FUNCTIONS
// TEST_BODY
