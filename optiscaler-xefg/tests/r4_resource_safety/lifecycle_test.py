"""Compile production lifecycle code against deterministic concurrency fakes.

The included gate is unmodified production code. Further extracted production
functions use only fake external D3D/Intel boundaries; this is not a GPU test.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(sys.argv[1]).resolve()
HERE = Path(__file__).resolve().parent


def body(relative_path, signature):
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for end in range(opening, len(text)):
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
            if depth == 0:
                return text[start:end + 1]
    raise AssertionError(f"Unterminated production body: {signature}")


def compile_and_run(source, name):
    with tempfile.TemporaryDirectory(prefix="xefg_r4_lifecycle_") as temp_name:
        temp = Path(temp_name)
        cpp = temp / (name + ".cpp")
        exe = temp / (name + (".exe" if os.name == "nt" else ""))
        cpp.write_text(source, encoding="utf-8")
        compiler = os.environ.get("CXX") or ("cl" if os.name == "nt" and shutil.which("cl") else "g++")
        if Path(compiler).name.lower() in ("cl", "cl.exe"):
            command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/Od", "/UNDEBUG", "/W4",
                       "/I" + str(ROOT / "OptiScaler"), str(cpp), "/Fe:" + str(exe)]
        else:
            command = [compiler, "-std=c++20", "-O0", "-UNDEBUG", "-Wall", "-Wextra", "-pthread",
                       "-I", str(ROOT / "OptiScaler"), str(cpp), "-o", str(exe)]
        subprocess.run(command, check=True, cwd=temp, timeout=90)
        subprocess.run([str(exe)], check=True, cwd=temp, timeout=30)


compile_and_run((HERE / "lifecycle_tests.cpp").read_text(encoding="utf-8"), "gate")

# Keep the real hook control flow, including all early returns. The fake FG
# boundary records only externally observable ordering and holds a real token.
hook = body("OptiScaler/resource_tracking/ResTrack_dx12.cpp",
            "void ResTrack_Dx12::hkExecuteCommandLists(")
hook_harness = r'''
#include <framegen/FGWorkGate.h>
#include <misc/XeFGWorkDiagnostics.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>
#include <latch>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>
using namespace std::chrono_literals;
using UINT = unsigned;
#define LOG_TRACK(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
enum class FG_ResourceType { Depth, Velocity, UIColor };
struct ID3D12CommandList {};
struct ID3D12GraphicsCommandList : ID3D12CommandList {};
struct ID3D12CommandAllocator {};
struct ID3D12PipelineState {};
struct ID3D12CommandQueue {};
static std::vector<char> events;
bool IsHudFixActive() { return true; }
struct FakeFG {
    FGWorkGate gate,resourceGate;
    auto AcquireWork() { return resourceGate.TryEnter(); }
    bool active = true, paused = false;
    std::atomic<bool> tracked{false}, after{false};
    unsigned beforeCalls = 0, afterCalls = 0, readyCalls = 0;
    unsigned discardCalls = 0;
    bool pending = true;
    auto AcquireSubmissionWork() { return gate.TryEnter(); }
    bool IsActive() { return active; }
    bool IsPaused() { return paused; }
    int GetIndex() { return 0; }
    void SetResourceReady(FG_ResourceType) { ++readyCalls; }
    void SetCommandQueue(FG_ResourceType, ID3D12CommandQueue*) {
        tracked = true; events.push_back('Q');
    }
    void BeforeCommandSubmission(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*) {
        ++beforeCalls; tracked = true; events.push_back('B');
    }
    void AfterCommandSubmission(UINT, ID3D12CommandList* const*) {
        ++afterCalls; after = true; events.push_back('A');
    }
    void DiscardPendingCommandList(ID3D12GraphicsCommandList*) {
        ++discardCalls; pending = false; events.push_back('D');
    }
};
struct State {
    FakeFG* currentFG = nullptr;
    static State& Instance() { static State state; return state; }
};
struct ResTrack_Dx12 {
    static inline std::mutex _resourceCommandListMutex;
    static inline std::unordered_set<ID3D12CommandList*> _notFoundCmdLists;
    static inline std::unordered_map<FG_ResourceType, ID3D12CommandList*> _resCmdList[4];
    static void hkExecuteCommandLists(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
};
static std::latch* executed = nullptr;
static std::latch* allowReturn = nullptr;
static bool requireTracking = true;
static unsigned originalCalls = 0;
void o_ExecuteCommandLists(ID3D12CommandQueue*, UINT count, ID3D12CommandList* const* lists) {
    assert(count == 1 && lists && lists[0]);
    auto fg = State::Instance().currentFG;
    if (requireTracking) assert(fg && fg->tracked.load());
    ++originalCalls;
    events.push_back('E');
    if (executed) executed->count_down();
    if (allowReturn) allowReturn->wait();
}
'''
hook_tests = r'''
void reset(FakeFG* fg) {
    State::Instance().currentFG = fg;
    events.clear(); originalCalls = 0;
    executed = nullptr; allowReturn = nullptr; requireTracking = true;
    ResTrack_Dx12::_notFoundCmdLists.clear();
    for (auto& slot : ResTrack_Dx12::_resCmdList) slot.clear();
}
int main() {
    ID3D12CommandQueue queue;
    ID3D12CommandList list;
    ID3D12CommandList* lists[]{&list};
    for (bool known : {false, true}) {
        FakeFG fg; reset(&fg);
        if (known) ResTrack_Dx12::_resCmdList[0][FG_ResourceType::Depth] = &list;
        ResTrack_Dx12::hkExecuteCommandLists(&queue, 1, lists);
        assert(originalCalls == 1 && fg.beforeCalls == 1 && fg.afterCalls == 1);
        auto b = std::find(events.begin(), events.end(), 'B');
        auto e = std::find(events.begin(), events.end(), 'E');
        auto a = std::find(events.begin(), events.end(), 'A');
        assert(b < e && e < a);
    }
    {
        // The production hook must retain admission across the real submission
        // and the bookkeeping AFTER it, even when shutdown begins inside D3D.
        FakeFG fg; reset(&fg);
        ResTrack_Dx12::_resCmdList[0][FG_ResourceType::Depth] = &list;
        std::latch entered{1}, release{1}; executed = &entered; allowReturn = &release;
        std::thread submit([&] { ResTrack_Dx12::hkExecuteCommandLists(&queue, 1, lists); });
        entered.wait();
        auto cleanup = std::async(std::launch::async, [&] {
            const bool drained = fg.gate.CloseAndWait(3s);
            assert(drained && fg.after.load());
            return drained;
        });
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (!fg.gate.IsClosed()) {
            assert(std::chrono::steady_clock::now() < deadline);
            std::this_thread::yield();
        }
        assert(cleanup.wait_for(0ms) == std::future_status::timeout);
        release.count_down(); submit.join();
        assert(cleanup.wait_for(1s) == std::future_status::ready && cleanup.get());
        assert(originalCalls == 1);
    }
    {
        // Closing FG rejects its tracking/tagging work, never the game's D3D
        // submission itself. No callback may touch released FG resources.
        FakeFG fg; reset(&fg); requireTracking = false;
        assert(fg.gate.CloseAndWait(1s));
        ResTrack_Dx12::_resCmdList[0][FG_ResourceType::Depth] = &list;
        ResTrack_Dx12::hkExecuteCommandLists(&queue, 1, lists);
        assert(originalCalls == 1 && fg.beforeCalls == 0 && fg.afterCalls == 0 && fg.readyCalls == 0);
        assert(!fg.tracked.load());
    }
    {
        reset(nullptr); requireTracking = false;
        ResTrack_Dx12::hkExecuteCommandLists(&queue, 1, lists);
        assert(originalCalls == 1);
    }
    std::cout << "PASS: actual ExecuteCommandLists hook tracks before submit, retains admission and closes FG callbacks\n";
}
'''
compile_and_run("#include <algorithm>\n" + hook_harness + "\n" + hook + "\n" + hook_tests,
                "submission_hook")

reset_hook = body("OptiScaler/resource_tracking/ResTrack_dx12.cpp",
                  "static HRESULT STDMETHODCALLTYPE hkResetCommandList(")
reset_boundary = r'''
using HRESULT = int;
#define STDMETHODCALLTYPE
#define SUCCEEDED(hr) ((hr) >= 0)
static HRESULT resetResult = 0;
static unsigned resetCalls = 0;
HRESULT o_ResetCommandList(ID3D12GraphicsCommandList*, ID3D12CommandAllocator*, ID3D12PipelineState*) {
    ++resetCalls; events.push_back('R');
    if (executed) executed->count_down();
    if (allowReturn) allowReturn->wait();
    return resetResult;
}
'''
reset_tests = r'''
int main() {
    ID3D12GraphicsCommandList list;
    for (HRESULT status : {0, -1}) {
        FakeFG fg; State::Instance().currentFG = &fg;
        resetResult = status; resetCalls = 0; events.clear();
        assert(hkResetCommandList(&list, nullptr, nullptr) == status);
        assert(resetCalls == 1);
        if (status == 0) {
            assert(!fg.pending && fg.discardCalls == 1);
            assert((events == std::vector<char>{'R','D'}));
        } else {
            assert(fg.pending && fg.discardCalls == 0);
            assert((events == std::vector<char>{'R'}));
        }
    }
    {
        FakeFG fg; State::Instance().currentFG = &fg;
        resetResult = 0; resetCalls = 0; events.clear();
        std::latch entered{1}, release{1}; executed = &entered; allowReturn = &release;
        std::thread reset([&] { assert(hkResetCommandList(&list, nullptr, nullptr) == 0); });
        entered.wait();
        auto cleanup = std::async(std::launch::async, [&] { return fg.gate.CloseAndWait(3s); });
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (!fg.gate.IsClosed()) {
            assert(std::chrono::steady_clock::now() < deadline);
            std::this_thread::yield();
        }
        assert(cleanup.wait_for(0ms) == std::future_status::timeout);
        release.count_down(); reset.join();
        assert(cleanup.wait_for(1s) == std::future_status::ready && cleanup.get());
        assert(!fg.pending && fg.discardCalls == 1);
        executed = nullptr; allowReturn = nullptr;
        assert(hkResetCommandList(&list, nullptr, nullptr) == 0);
        assert(resetCalls == 2 && fg.discardCalls == 1);
    }
    State::Instance().currentFG = nullptr;
    assert(hkResetCommandList(&list, nullptr, nullptr) == 0);
    std::cout << "PASS: actual command Reset hook consumes only successful resets under admission\n";
}
'''
compile_and_run(hook_harness + "\n" + reset_boundary + "\n" + reset_hook + "\n" + reset_tests,
                "reset_hook")

pending_bodies = "\n\n".join(body("OptiScaler/framegen/xefg/XeFG_Dx12.cpp", signature)
                            for signature in (
    "bool XeFG_Dx12::QuiesceWork()",
    "bool XeFG_Dx12::TryCloseCpuAdmission()",
    "void XeFG_Dx12::RestoreCpuAdmission()",
    "uint64_t XeFG_Dx12::CapturePendingCommandListGeneration(",
    "void XeFG_Dx12::RetirePendingCommandList(",
    "void XeFG_Dx12::PublishPendingLocked()",
    "bool XeFG_Dx12::TrackPendingCommandList(",
    "void XeFG_Dx12::DiscardPendingCommandList(",
    "void XeFG_Dx12::BeforeCommandSubmission(",
    "void XeFG_Dx12::AfterCommandSubmission(",
    "void XeFG_Dx12::TrackLifetimeQueue(",
))
pending_harness = r'''
#include <framegen/FGWorkGate.h>
#include <misc/XeFGWorkDiagnostics.h>
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
    struct LifetimeQueue { ID3D12CommandQueue* queue = nullptr; };
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
'''
pending_tests = r'''
int main() {
    {
        // R5 defers immediately when CPU tagging is in flight. Both admission
        // gates roll back, while the independent game observer remains live.
        XeFG_Dx12 fg; ID3D12GraphicsCommandList list;
        ID3D12CommandList* lists[]{&list}; ID3D12CommandQueue queue;
        { auto work=fg.AcquireWork(); assert(work && fg.TrackPendingCommandList(&list));
          auto begin=std::chrono::steady_clock::now(); assert(!fg.QuiesceWork());
          assert(std::chrono::steady_clock::now()-begin<250ms);
          assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed()); }
        assert(fg.PendingForTest());
        auto begin=std::chrono::steady_clock::now(); assert(!fg.QuiesceWork());
        assert(std::chrono::steady_clock::now()-begin<250ms);
        assert(!fg._workGate.IsClosed() && !fg._submissionGate.IsClosed());
        { auto work=fg.AcquireSubmissionWork(); assert(work);
          fg.BeforeCommandSubmission(&queue,1,lists);
          assert(queue.refs==1 && fg._lifetimeQueueCount==1 && fg.PendingForTest());
          fg.AfterCommandSubmission(1,lists); assert(!fg.PendingForTest());
          // Observer bookkeeping in flight must also defer without closing it.
          assert(!fg.QuiesceWork());
          assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed()); }
        assert(fg.QuiesceWork());
        assert(fg._workGate.IsClosed() && fg._providerPresentGate.IsClosed() && fg._submissionGate.IsClosed());
        assert(!fg.AcquireWork() && !fg.AcquireSubmissionWork());
    }
    {
        // Duplicate tags of one command list require one submission, whereas
        // an unrelated list cannot consume it or make cleanup appear safe.
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList first, second, unrelated;
        ID3D12CommandList* one[]{&first};
        ID3D12CommandList* other[]{&unrelated};
        ID3D12CommandList* both[]{&first, &second};
        ID3D12CommandQueue queue;
        fg.TrackPendingCommandList(&first);
        fg.TrackPendingCommandList(&first);
        fg.TrackPendingCommandList(&second);
        assert(fg._pendingCommandListCount == 2);
        fg.AfterCommandSubmission(1, other);
        assert(fg._pendingCommandListCount == 2);
        fg.BeforeCommandSubmission(&queue, 1, one);
        fg.AfterCommandSubmission(1, one);
        assert(fg._pendingCommandListCount == 1 && fg.PendingForTest());
        fg.BeforeCommandSubmission(&queue, 2, both);
        fg.AfterCommandSubmission(2, both);
        assert(!fg.PendingForTest() && queue.refs == 1);
        assert(fg.QuiesceWork());
    }
    {
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList first, second;
        ID3D12CommandQueue queue;
        ID3D12CommandList* submitted[]{&first};
        fg.TrackPendingCommandList(&first);
        fg.BeforeCommandSubmission(&queue, 1, submitted);
        fg.AfterCommandSubmission(1, submitted);
        assert(queue.refs == 1 && fg._lifetimeQueueCount == 1);
        // A later recording of the SAME list may be discarded. That cancels
        // the new recording only; its earlier submitted GPU work still owns
        // the registered queue and requires the separate fence drain.
        fg.TrackPendingCommandList(&first);
        fg.TrackPendingCommandList(&second);
        fg.DiscardPendingCommandList(&first);
        assert(fg._pendingCommandListCount == 1 && fg.PendingForTest());
        fg.DiscardPendingCommandList(&first);
        assert(fg._pendingCommandListCount == 1);
        fg.DiscardPendingCommandList(&second);
        assert(!fg.PendingForTest() && fg.QuiesceWork());
        assert(queue.refs == 1 && fg._lifetimeQueueCount == 1);
    }
    {
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList wrapped, canonical;
        ID3D12CommandQueue queue;
        wrappedList = &wrapped; canonicalList = &canonical;
        ID3D12CommandList* wrappedBatch[]{&wrapped};
        fg.TrackPendingCommandList(&wrapped);
        fg.TrackPendingCommandList(&canonical);
        assert(fg._pendingCommandListCount == 1);
        fg.BeforeCommandSubmission(&queue, 1, wrappedBatch);
        assert(queue.refs == 1);
        fg.AfterCommandSubmission(1, wrappedBatch);
        assert(!fg.PendingForTest());
        fg.TrackPendingCommandList(&canonical);
        fg.DiscardPendingCommandList(&wrapped);
        assert(!fg.PendingForTest() && fg.QuiesceWork());
        assert(queue.refs == 1 && fg._lifetimeQueueCount == 1);
        wrappedList = nullptr; canonicalList = nullptr;
    }
    {
        // A recorded game list can be discarded/reset without Execute. Until
        // that lifecycle is observed, production must defer and KEEP its
        // pending identity instead of treating the resources as safe to free.
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList discarded;
        fg.TrackPendingCommandList(&discarded);
        assert(!fg.QuiesceWork());
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed() && fg.PendingForTest());
        assert(fg._pendingCommandListCount == 1);
    }
    {
        // Capacity failure rejects the new recording BEFORE any GPU injection;
        // existing tracked recordings stay complete and can finish/recover.
        XeFG_Dx12 fg; ID3D12GraphicsCommandList lists[XeFG_Dx12::MaxPendingCommandLists+1];
        for(size_t i=0;i<XeFG_Dx12::MaxPendingCommandLists;++i) assert(fg.TrackPendingCommandList(&lists[i]));
        assert(!fg.TrackPendingCommandList(&lists[XeFG_Dx12::MaxPendingCommandLists]));
        assert(fg._pendingTrackingComplete && fg._pendingCommandListCount==XeFG_Dx12::MaxPendingCommandLists);
        assert(!fg.QuiesceWork() && !fg._workGate.IsClosed());
        for(size_t i=0;i<XeFG_Dx12::MaxPendingCommandLists;++i) fg.DiscardPendingCommandList(&lists[i]);
        assert(!fg.PendingForTest() && fg.QuiesceWork());
    }
    {
        // Missing observers reject tagging without poisoning or adding pending.
        XeFG_Dx12 fg; ID3D12GraphicsCommandList list;
        ResTrack_Dx12::observersReady=false;
        assert(!fg.TrackPendingCommandList(&list) && !fg.PendingForTest());
        ResTrack_Dx12::observersReady=true;
        assert(fg.TrackPendingCommandList(&list));
        auto oldGeneration=fg.CapturePendingCommandListGeneration(&list); assert(oldGeneration!=0);
        fg.DiscardPendingCommandList(&list); assert(fg.TrackPendingCommandList(&list));
        auto newGeneration=fg.CapturePendingCommandListGeneration(&list); assert(newGeneration>oldGeneration);
        fg.RetirePendingCommandList(&list,oldGeneration); assert(fg.PendingForTest());
        fg.RetirePendingCommandList(&list,0); assert(fg.PendingForTest());
        fg.RetirePendingCommandList(&list,newGeneration); assert(!fg.PendingForTest());
        assert(fg._pendingStats.registered==2 && fg._pendingStats.resetDiscarded==1 && fg._pendingStats.destroyed==1);
    }
    {
        // Observation age is diagnostic only, never evidence for freeing work.
        XeFG_Dx12 fg; ID3D12GraphicsCommandList list; assert(fg.TrackPendingCommandList(&list));
        fg._pendingCommandLists[0].firstSeenTickMs=1; fg.PublishPendingLocked();
        assert(!fg.QuiesceWork() && fg._pendingCommandListCount==1 && fg.PendingForTest());
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
    }
    std::cout << "PASS: actual pending-list quiescence, late submission, queue ownership and overflow tests\n";
}
'''
compile_and_run(pending_harness + "\n" + pending_bodies + "\n" + pending_tests, "pending_work")

# This separate harness preserves the complete native Present/Present1 coverage
# and adds reopening checks using the independent provider Present gate.
subprocess.run([sys.executable, str(HERE / "native_present_test.py"), str(ROOT)], check=True)
