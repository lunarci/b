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
            command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/Od", "/W4", "/UNDEBUG",
                       "/I" + str(ROOT / "OptiScaler"), str(cpp), "/Fe:" + str(exe)]
        else:
            command = [compiler, "-std=c++20", "-O0", "-UNDEBUG", "-Wall", "-Wextra", "-pthread",
                       "-I", str(ROOT / "OptiScaler"), str(cpp), "-o", str(exe)]
        subprocess.run(command, check=True, cwd=temp, timeout=90)
        subprocess.run([str(exe)], check=True, cwd=temp, timeout=30)


# Compile the complete production FGPresent function, retaining its mutex,
# provider selection, early exits and marker/semaphore cleanup control flow.
present_body = body("OptiScaler/hooks/FG_Hooks.cpp", "HRESULT FGHooks::FGPresent(")
present_harness = r'''
#include <framegen/FGWorkGate.h>
#include <misc/LongSessionTiming.h>
#include <misc/XeFGWorkDiagnostics.h>
#include <shared_mutex>
#include <unordered_map>
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
#define LOG_INFO(...) ((void)0)
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
struct ID3D12Device {}; struct ID3D12CommandQueue {}; struct FG_Constants {};
constexpr unsigned BUFFER_COUNT = 4;
enum xefg_swapchain_result_t { XEFG_SWAPCHAIN_RESULT_SUCCESS, XEFG_SWAPCHAIN_RESULT_ERROR };
namespace XeFGPacing { void RequestReset() {} }
namespace XeFGProxy {
    static bool failDisable=false, failEnable=false;
    static unsigned enableCalls=0, disableCalls=0;
    xefg_swapchain_result_t set(void*,bool enabled) {
        if(enabled) ++enableCalls; else ++disableCalls;
        return (enabled ? failEnable : failDisable) ? XEFG_SWAPCHAIN_RESULT_ERROR : XEFG_SWAPCHAIN_RESULT_SUCCESS;
    }
    auto SetEnabled() { return &set; }
}
struct XeFG_Dx12 {
    FGWorkGate _workGate, _submissionGate, _providerPresentGate;
    FGWorkGate& submissionGate = _providerPresentGate;
    bool _workWasClosed=false, _submissionWasClosed=false, _presentWasClosed=false, _submissionClosedByLifecycle=false;
    std::atomic<bool> _aliasResetPending{false};
    std::recursive_mutex _lifecycleMutex;
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<int,int> _frameResources[BUFFER_COUNT],_resourceReady[BUFFER_COUNT];
    bool _noUi[BUFFER_COUNT]{},_noHudless[BUFFER_COUNT]{},_noDistortionField[BUFFER_COUNT]{};
    bool _uiCommandListResetted[BUFFER_COUNT]{};
    bool _isActive=true,_lifecycleFailed=false,_waitingNewFrameData=true;
    bool discardOk=true, objectsReady=true;
    unsigned historyResets=0,targetUpdates=0;
    void* _fgContext=reinterpret_cast<void*>(1);
    void* _swapChainContext=reinterpret_cast<void*>(1);
    ID3D12Device* _device=nullptr; ID3D12CommandQueue* _gameCommandQueue=nullptr;
    uint64_t _lastDispatchedFrame=7;
    XeFGDiagnostics::WorkDiagnostics _workDiagnostics;
    auto AcquireWork(){return _workGate.TryEnter();}
    bool TryCloseCpuAdmission();void RestoreCpuAdmission();void RestoreProviderState(bool);
    bool DeactivateImpl(bool submitPending=true);void DestroyFGContext();
    void CreateContext(ID3D12Device*,FG_Constants&);
    unsigned GetIndex()const{return 0;}
    void RequestHistoryReset(){++historyResets;}void UpdateTarget(){++targetUpdates;}
    bool SubmitUICommandList(unsigned){return true;}
    bool DiscardPendingCommandRecordings(){return discardOk;}
    void CreateObjects(ID3D12Device*){}
    bool CommandObjectsReady()const{return objectsReady;}
    OwnedMutex Mutex;
    bool& active = _isActive; bool paused = false;
    bool requireMutexBeforeAdmission = false;
    unsigned fgPresents = 0;
    bool IsActive() const { return active; }
    bool IsPaused() const { return paused; }
    unsigned FrameCount() const { return 1; }
    void Present() { ++fgPresents; }
    auto AcquirePresentWork() {
        if (requireMutexBeforeAdmission) assert(Mutex.getOwner() == 2);
        return submissionGate.TryEnter();
    }
};
using FakeFG = XeFG_Dx12;
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
namespace ResTrack_Dx12 { void ClearPossibleHudless() {} bool HookLifetimeObservers(ID3D12Device*,ID3D12CommandQueue*){return true;} }
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
        XeFGProxy::failDisable=XeFGProxy::failEnable=false;
        XeFGProxy::enableCalls=XeFGProxy::disableCalls=0;
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
    for (bool present1 : {false, true}) {
        Fixture fixture; FakeFG fg; fixture.state.currentFG=&fg;
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==1);
        // Run the real alias-reset failure paths, then the full FGPresent body.
        XeFGProxy::failDisable=true;fg.DestroyFGContext();
        assert(fg.IsActive() && fg._fgContext==fg._swapChainContext);
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==2);
        XeFGProxy::failDisable=false;fg.discardOk=false;fg.DestroyFGContext();
        assert(fg.IsActive() && fg._fgContext==fg._swapChainContext && XeFGProxy::enableCalls==1);
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==3);
        { auto busy=fg.AcquireWork();fg.DestroyFGContext();assert(fg.IsActive() && fg._fgContext!=nullptr); }
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==4);
        fg.discardOk=true;fg.DestroyFGContext();
        assert(!fg.IsActive() && fg._fgContext==nullptr);
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==5);
        assert(fg._workGate.TryCloseWhenIdle() && fg._providerPresentGate.TryCloseWhenIdle());
        assert(fixture.call(present1)==S_OK && fixture.nativeCount()==5);
        ID3D12Device device;FG_Constants constants;
        fg.CreateContext(&device,constants);fg.RestoreProviderState(true);
        assert(fg.IsActive() && fg._fgContext==fg._swapChainContext);
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        assert(fixture.call(present1)==nativeResult && fixture.nativeCount()==6 && fg.fgPresents==5);
        assert((present1 ? nativePresent1Calls : nativePresentCalls)==6);
        assert(fg.Mutex.locks==fg.Mutex.unlocks && fg.Mutex.getOwner()==0);
        assert(semaphoreReleases==7 && Hudfix_Dx12::ends==7);
    }
    std::cout << "PASS: complete FGPresent/Present1 lifetime plus actual provider-disable rollback and CreateContext resume\n";
}
'''
lifecycle_bodies = "\n".join(body("OptiScaler/framegen/xefg/XeFG_Dx12.cpp", signature) for signature in [
    "bool XeFG_Dx12::TryCloseCpuAdmission()", "void XeFG_Dx12::RestoreCpuAdmission()",
    "void XeFG_Dx12::RestoreProviderState(bool wasActive)", "bool XeFG_Dx12::DeactivateImpl(bool submitPending)",
    "void XeFG_Dx12::DestroyFGContext()", "void XeFG_Dx12::CreateContext("])
compile_and_run(present_harness + "\n" + lifecycle_bodies + "\n" + present_body + "\n" + present_tests, "native_present")
