
#include <framegen/FGWorkGate.h>
#include <misc/XeFGWorkDiagnostics.h>
#include <misc/XeFGProgressDiagnostics.h>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <future>
#include <iostream>
#include <latch>
#include <mutex>
#include <thread>
#include <vector>
using namespace std::chrono_literals;
using UINT = unsigned;
using UINT64 = unsigned long long;
constexpr size_t BUFFER_COUNT = 4;
#define LOG_ERROR(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_WARN(...) ((void)0)
struct ID3D12CommandList {};
struct ID3D12GraphicsCommandList : ID3D12CommandList {};
using IUnknown = void;
static ID3D12CommandList* wrappedList = nullptr;
static ID3D12CommandList* canonicalList = nullptr;
bool CheckForRealObject(const char*, ID3D12CommandList* list, IUnknown** output) {
    if (wrappedList != nullptr && list == wrappedList) {
        *output = canonicalList;
        return true;
    }
    return false;
}
struct ID3D12CommandQueue {
    unsigned refs = 0;
    void AddRef() { ++refs; }
};
namespace ResTrack_Dx12 { static bool observersReady=true;
    bool LifetimeObserversReady(ID3D12GraphicsCommandList*,ID3D12CommandQueue*) { return observersReady; } }
struct XeFG_Dx12 {
    FGWorkGate _workGate, _providerPresentGate, _submissionGate;
    bool _workWasClosed=false,_presentWasClosed=false,_submissionWasClosed=false,_submissionClosedByLifecycle=false;
    XeFGDiagnostics::WorkDiagnostics _workDiagnostics;
    XeFGDiagnostics::PendingSnapshot _pendingStats;
    uint64_t _pendingGeneration=0;
    ID3D12CommandQueue* _gameCommandQueue=nullptr;
    bool TryCloseCpuAdmission(); void RestoreCpuAdmission(); void PublishPendingLocked();
    uint64_t CapturePendingCommandListGeneration(const void*);
    void RetirePendingCommandList(const void*,uint64_t);
    std::recursive_mutex _lifecycleMutex;
    std::mutex _pendingCommandMutex, _lifetimeQueueMutex;
    std::condition_variable _pendingCommandsSubmitted;
    static constexpr size_t MaxPendingCommandLists = 256;
    static constexpr size_t MaxLifetimeQueues = 8;
    struct PendingCommandList { ID3D12CommandList* identity=nullptr; uint64_t generation=0,firstSeenTickMs=0; };
    PendingCommandList _pendingCommandLists[MaxPendingCommandLists]{};
    size_t _pendingCommandListCount = 0;
    bool _pendingTrackingComplete = true, _queueTrackingComplete = true;
    std::atomic<bool> _lifecycleFailed{false};
    bool _objectsDrained = false;
    struct LifetimeQueue { ID3D12CommandQueue* queue = nullptr; XeFGProgress::QueueSnapshot progress; };
    LifetimeQueue _lifetimeQueues[MaxLifetimeQueues]{};
    size_t _lifetimeQueueCount = 0;
    ID3D12GraphicsCommandList* _uiCommandList[BUFFER_COUNT]{};
    ID3D12GraphicsCommandList* _scCommandList[BUFFER_COUNT]{};
    auto AcquireWork() { return _workGate.TryEnter(); }
    auto AcquireSubmissionWork() { return _submissionGate.TryEnter(); }
    bool QuiesceWork();
    bool PendingForTest() {
        std::lock_guard lock(_pendingCommandMutex);
        return _pendingCommandListCount != 0 || !_pendingTrackingComplete;
    }
    bool TrackPendingCommandList(ID3D12GraphicsCommandList*);
    void DiscardPendingCommandList(ID3D12GraphicsCommandList*);
    void BeforeCommandSubmission(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
    void AfterCommandSubmission(UINT, ID3D12CommandList* const*);
    void TrackLifetimeQueue(ID3D12CommandQueue*);
};
template<class Predicate> void await(Predicate predicate) {
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!predicate()) {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::yield();
    }
}

// ACTUAL_FUNCTIONS

#include <cstdlib>
#undef assert
#define assert(condition) do { if (!(condition)) { std::cerr << "R6 invariant failure: " << #condition << "\n"; std::exit(42); } } while(false)
int main() {
    XeFG_Dx12 fg; ID3D12GraphicsCommandList list; ID3D12CommandQueue queue;
    ID3D12CommandList* batch[]{&list};
    fg.TrackPendingCommandList(&list);
    fg.BeforeCommandSubmission(&queue, 1, batch);
    fg.DiscardPendingCommandList(&list); // Reset after native Execute returns
    fg.TrackPendingCommandList(&list);  // New recording before the old After
    fg.AfterCommandSubmission(1, batch);
    assert(fg.PendingForTest() && "late After must retain a newer recording of the same command list");
}
