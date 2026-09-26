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
            command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/Od", "/W4",
                       "/I" + str(ROOT / "OptiScaler"), str(cpp), "/Fe:" + str(exe)]
        else:
            command = [compiler, "-std=c++20", "-O0", "-Wall", "-Wextra", "-pthread",
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
struct FakeFG {
    FGWorkGate gate;
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
    "void XeFG_Dx12::TrackPendingCommandList(",
    "void XeFG_Dx12::DiscardPendingCommandList(",
    "void XeFG_Dx12::BeforeCommandSubmission(",
    "void XeFG_Dx12::AfterCommandSubmission(",
    "void XeFG_Dx12::TrackLifetimeQueue(",
))
pending_harness = r'''
#include <framegen/FGWorkGate.h>
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
struct XeFG_Dx12 {
    FGWorkGate _workGate, _submissionGate;
    std::recursive_mutex _lifecycleMutex;
    std::mutex _pendingCommandMutex, _lifetimeQueueMutex;
    std::condition_variable _pendingCommandsSubmitted;
    static constexpr size_t MaxPendingCommandLists = 256;
    static constexpr size_t MaxLifetimeQueues = 8;
    ID3D12CommandList* _pendingCommandLists[MaxPendingCommandLists]{};
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
    void TrackPendingCommandList(ID3D12GraphicsCommandList*);
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
        // Shutdown starts with a live tag operation. Its game-owned list must
        // still be allowed to submit after NEW tagging admission is closed.
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList list;
        ID3D12CommandList* lists[]{&list};
        ID3D12CommandQueue queue;
        std::latch taggingEntered{1}, finishTagging{1};
        std::thread tag([&] {
            auto work = fg.AcquireWork(); assert(work);
            fg.TrackPendingCommandList(&list);
            taggingEntered.count_down(); finishTagging.wait();
        });
        taggingEntered.wait();
        auto cleanup = std::async(std::launch::async, [&] { return fg.QuiesceWork(); });
        await([&] { return fg._workGate.IsClosed(); });
        assert(!fg.AcquireWork());
        assert(cleanup.wait_for(0ms) == std::future_status::timeout);
        finishTagging.count_down(); tag.join();
        assert(fg.PendingForTest());
        {
            auto work = fg.AcquireSubmissionWork(); assert(work);
            fg.BeforeCommandSubmission(&queue, 1, lists);
            // The actual before callback must retain the queue before Execute.
            assert(queue.refs == 1 && fg._lifetimeQueueCount == 1);
            assert(fg.PendingForTest());
            fg.AfterCommandSubmission(1, lists);
            assert(!fg.PendingForTest());
            await([&] { return fg._submissionGate.IsClosed(); });
            assert(cleanup.wait_for(0ms) == std::future_status::timeout);
        }
        assert(cleanup.wait_for(1s) == std::future_status::ready && cleanup.get());
        assert(fg._workGate.IsClosed() && fg._submissionGate.IsClosed());
        assert(!fg.AcquireSubmissionWork());
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
        // that lifecycle is observed, production must time out and KEEP its
        // pending identity instead of treating the resources as safe to free.
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList discarded;
        fg.TrackPendingCommandList(&discarded);
        assert(!fg.QuiesceWork());
        assert(fg._workGate.IsClosed() && fg.PendingForTest());
        assert(fg._pendingCommandListCount == 1);
    }
    {
        // A full registry cannot silently claim that all injected GPU uses
        // were tracked. Failure must preserve resources, not permit cleanup.
        XeFG_Dx12 fg;
        ID3D12GraphicsCommandList lists[XeFG_Dx12::MaxPendingCommandLists + 1];
        for (auto& list : lists) fg.TrackPendingCommandList(&list);
        assert(!fg._pendingTrackingComplete && fg.PendingForTest());
        assert(!fg.QuiesceWork());
        assert(fg._workGate.IsClosed());
    }
    std::cout << "PASS: actual pending-list quiescence, late submission, queue ownership and overflow tests\n";
}
'''
compile_and_run(pending_harness + "\n" + pending_bodies + "\n" + pending_tests, "pending_work")

# Compile the complete production FGPresent function, retaining its mutex,
# provider selection, early exits and marker/semaphore cleanup control flow.
present_body = body("OptiScaler/hooks/FG_Hooks.cpp", "HRESULT FGHooks::FGPresent(")
present_harness = r'''
#include <framegen/FGWorkGate.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <deque>
#include <future>
#include <iostream>
#include <latch>
#include <mutex>
#include <optional>
#include <thread>
using namespace std::chrono_literals;
using HRESULT = int; using UINT = unsigned; using IUnknown = void;
constexpr HRESULT S_OK = 0, DXGI_ERROR_DEVICE_REMOVED = -5;
constexpr UINT DXGI_PRESENT_TEST = 1, DXGI_PRESENT_ALLOW_TEARING = 2;
#define LOG_DEBUG(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
struct DXGI_PRESENT_PARAMETERS {};
struct IDXGISwapChain { UINT GetCurrentBackBufferIndex() { return 0; } };
using IDXGISwapChain1 = IDXGISwapChain;
using IDXGISwapChain4 = IDXGISwapChain;
struct ID3D11DeviceContext { void Release() {} };
struct ID3D11Device {
    ID3D11DeviceContext context;
    void GetImmediateContext(ID3D11DeviceContext** output) { *output = &context; }
};
template<class T> struct Setting {
    T value{};
    T value_or_default() const { return value; }
};
struct Config {
    static inline Config* current = nullptr;
    static Config* Instance() { return current; }
    Setting<bool> FGUseMutexForSwapchain{true};
    Setting<bool> FGDLSSGUseGamesReflexMarkers{true};
    std::optional<bool> ForceVsync{};
    Setting<UINT> VsyncInterval{1};
    Setting<bool> SimulateWaitableObject{true};
};
struct OwnedMutex {
    std::mutex mutex;
    std::atomic<int> owner{0};
    unsigned locks = 0, unlocks = 0;
    int getOwner() { return owner.load(); }
    void lock(int id) { mutex.lock(); owner = id; ++locks; }
    void unlockThis(int id) { assert(owner == id); owner = 0; ++unlocks; mutex.unlock(); }
};
struct FakeFG {
    FGWorkGate submissionGate;
    OwnedMutex Mutex;
    bool active = true, paused = false;
    bool requireMutexBeforeAdmission = false;
    unsigned fgPresents = 0;
    bool IsActive() const { return active; }
    bool IsPaused() const { return paused; }
    unsigned FrameCount() const { return 1; }
    void Present() { ++fgPresents; }
    auto AcquireSubmissionWork() {
        if (requireMutexBeforeAdmission) assert(Mutex.getOwner() == 2);
        return submissionGate.TryEnter();
    }
};
using IFGFeature = FakeFG;
struct Feature {
    std::optional<double> ReadUpscalerTime(void*) { return {}; }
    void ReadDetailedGpuTimes(void*, int&) {}
};
enum class SwapchainInteropApi { None, Dx11wDx12 };
enum class FGOutput { NoFG, XeFG, DLSSG };
enum class FGInput { Other, FSRFG, FSRFG30 };
enum class GameEngineType { Other, Unity };
struct State {
    static inline State* current = nullptr;
    static State& Instance() { return *current; }
    bool isShuttingDown = false;
    unsigned fgLastFrame = 0;
    double lastFGFrameTime = 0;
    FakeFG* currentFG = nullptr;
    Feature* currentFeature = nullptr;
    SwapchainInteropApi swapchainInteropApi = SwapchainInteropApi::None;
    ID3D11Device* currentD3D11Device = nullptr;
    void* currentD3D12Device = nullptr;
    void* currentCommandQueue = nullptr;
    int detailedGpuTimes = 0;
    std::mutex frameTimeMutex;
    std::deque<double> upscaleTimes{0.0};
    unsigned dlssgDetectedInterpolationCount = 5;
    FGOutput activeFgOutput = FGOutput::XeFG;
    FGInput activeFgInput = FGInput::Other;
    bool SCAllowTearing = false, realExclusiveFullscreen = false, fgPresentIsCalled = false;
    bool reflexLimitsFps = true;
    GameEngineType gameEngine = GameEngineType::Other;
};
namespace Util {
    double MillisecondsNow() { return 50.0; }
    void GetDeviceRemovedReason(void*) {}
}
namespace sl {
    struct FrameToken {};
    enum class Result { eErrorReflexAPI, eOk };
    enum class PCLMarker { ePresentStart, ePresentEnd };
}
namespace ReflexHooks { bool gameIsSendingMarkers() { return true; } }
namespace StreamlineProxy {
    void marker(sl::PCLMarker, sl::FrameToken&) {}
    auto PCLSetMarker() { return &marker; }
    sl::Result token(sl::FrameToken*&, const uint32_t*) { return sl::Result::eErrorReflexAPI; }
    auto GetNewFrameToken() { return &token; }
    void sleep(sl::FrameToken&) {}
    auto ReflexSleep() { return &sleep; }
}
void ffxPresentCallback() {}
namespace FSR3FG { void ffxPresentCallback() {} }
namespace ResTrack_Dx12 { void ClearPossibleHudless() {} }
namespace Hudfix_Dx12 {
    static unsigned starts = 0, ends = 0;
    void PresentStart() { ++starts; }
    void PresentEnd() { ++ends; }
}
namespace IdentifyGpu {
    struct Gpu { bool usesDxvk = false; };
    Gpu getPrimaryGpu() { return {}; }
}
namespace XellHooks { bool canLimit() { return true; } }
namespace FrameLimit { void sleep(bool) {} }
static unsigned semaphoreReleases = 0;
void ReleaseSemaphore(void*, int count, void*) { assert(count == 1); ++semaphoreReleases; }
struct FGHooks {
    static inline UINT _lastPresentFlags = 0;
    static inline double _lastFGFrameTime = 0.0;
    static inline void* _semaphore = reinterpret_cast<void*>(1);
    static HRESULT FGPresent(IDXGISwapChain*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*);
};
static unsigned nativePresentCalls = 0, nativePresent1Calls = 0;
static std::latch* nativeEntered = nullptr;
static std::latch* nativeRelease = nullptr;
static HRESULT nativeResult = 7;
HRESULT nativeWait() {
    if (nativeEntered) nativeEntered->count_down();
    if (nativeRelease) nativeRelease->wait();
    return nativeResult;
}
HRESULT o_FGSCPresent(IDXGISwapChain*, UINT, UINT) {
    ++nativePresentCalls; return nativeWait();
}
HRESULT o_FGSCPresent1(IDXGISwapChain1*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*) {
    ++nativePresent1Calls; return nativeWait();
}
struct Fixture {
    Config config;
    State state;
    IDXGISwapChain swapchain;
    DXGI_PRESENT_PARAMETERS parameters;
    Fixture() {
        Config::current = &config; State::current = &state;
        nativePresentCalls = nativePresent1Calls = semaphoreReleases = 0;
        Hudfix_Dx12::starts = Hudfix_Dx12::ends = 0;
        nativeEntered = nativeRelease = nullptr; nativeResult = 7;
        FGHooks::_lastFGFrameTime = 0.0;
    }
    HRESULT call(bool present1, UINT flags = 0) {
        return FGHooks::FGPresent(&swapchain, 1, flags, present1 ? &parameters : nullptr);
    }
    unsigned nativeCount() const { return nativePresentCalls + nativePresent1Calls; }
};
'''
present_tests = r'''
int main() {
    for (bool present1 : {false, true}) {
      for (bool active : {false, true}) {
       for (UINT flags : {0u, DXGI_PRESENT_TEST}) {
        // The actual native provider call is held open while shutdown attempts
        // to drain. A token scoped only to fg->Present() would fail this case.
        Fixture fixture; FakeFG fg; fixture.state.currentFG = &fg;
        fg.active = active;
        const unsigned expectedActiveCalls = active && flags == 0 ? 1u : 0u;
        fg.requireMutexBeforeAdmission = expectedActiveCalls != 0;
        std::latch entered{1}, release{1}; nativeEntered = &entered; nativeRelease = &release;
        std::thread presenting([&] { assert(fixture.call(present1, flags) == nativeResult); });
        entered.wait();
        auto cleanup = std::async(std::launch::async, [&] {
            return fg.submissionGate.CloseAndWait(3s);
        });
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (!fg.submissionGate.IsClosed()) {
            assert(std::chrono::steady_clock::now() < deadline);
            std::this_thread::yield();
        }
        assert(cleanup.wait_for(0ms) == std::future_status::timeout);
        release.count_down(); presenting.join();
        assert(cleanup.wait_for(1s) == std::future_status::ready && cleanup.get());
        assert(fixture.nativeCount() == 1 && fg.fgPresents == expectedActiveCalls);
        assert((present1 ? nativePresent1Calls : nativePresentCalls) == 1);
        assert(fg.Mutex.locks == expectedActiveCalls && fg.Mutex.unlocks == expectedActiveCalls && fg.Mutex.getOwner() == 0);
        assert(semaphoreReleases == 1 && Hudfix_Dx12::ends == 1);
       }
      }
    }
    for (bool present1 : {false, true}) {
        Fixture fixture; FakeFG fg; fixture.state.currentFG = &fg;
        fg.requireMutexBeforeAdmission = true;
        assert(fg.submissionGate.CloseAndWait(1s));
        assert(fixture.call(present1) == S_OK);
        assert(fixture.nativeCount() == 0 && fg.fgPresents == 0);
        assert(!fixture.state.fgPresentIsCalled);
        assert(fg.Mutex.locks == 1 && fg.Mutex.unlocks == 1 && fg.Mutex.getOwner() == 0);
        assert(semaphoreReleases == 1 && Hudfix_Dx12::ends == 1);
    }
    for (bool present1 : {false, true}) {
        for (bool inactive : {false, true}) {
            Fixture fixture; FakeFG fg; fixture.state.currentFG = &fg;
            fg.active = !inactive; fg.paused = !inactive;
            assert(fixture.call(present1) == nativeResult);
            assert(fixture.nativeCount() == 1 && fg.fgPresents == 0);
            assert(fg.Mutex.locks == 0 && fg.Mutex.unlocks == 0);
        }
        {
            Fixture fixture; FakeFG fg; fixture.state.currentFG = &fg;
            assert(fixture.call(present1, DXGI_PRESENT_TEST) == nativeResult);
            assert(fixture.nativeCount() == 1 && fg.fgPresents == 0);
            assert(fg.Mutex.locks == 0 && fg.Mutex.unlocks == 0);
            assert(fg.submissionGate.CloseAndWait(1s));
            assert(fixture.call(present1, DXGI_PRESENT_TEST) == S_OK);
            assert(fixture.nativeCount() == 1);
        }
        {
            Fixture fixture; fixture.state.currentFG = nullptr;
            assert(fixture.call(present1) == nativeResult);
            assert(fixture.nativeCount() == 1);
            assert(semaphoreReleases == 1);
        }
    }
    std::cout << "PASS: complete FGPresent native Present/Present1 lifetime, admission, passthrough and cleanup tests\n";
}
'''
compile_and_run(present_harness + "\n" + present_body + "\n" + present_tests, "native_present")
