#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>
// NEGATIVE_ASSERT_SHIM
using UINT = unsigned; using UINT64 = std::uint64_t; using ULONG = unsigned long;
using HRESULT = int; using HWND = void*;
#define STDMETHODCALLTYPE
constexpr HRESULT S_OK = 0;
#define XEFG_RESOURCE_REF_LIMIT 1
#define LOG_DEBUG(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
#define IID_PPV_ARGS(x) x
struct IUnknown {
    ULONG refs = 1, releases = 0, adds = 0;
    virtual ~IUnknown() = default;
    ULONG AddRef() { ++adds; return ++refs; }
    ULONG Release() { assert(refs != 0); ++releases; return --refs; }
};
struct ID3D12Resource : IUnknown {};
struct DXGI_SWAP_CHAIN_DESC { UINT BufferCount = 2; HWND OutputWindow = reinterpret_cast<void*>(1); };
struct IDXGISwapChain : IUnknown {
    ID3D12Resource buffers[2];
    IDXGISwapChain() { buffers[0].refs = buffers[1].refs = 4; }
    HRESULT GetDesc(DXGI_SWAP_CHAIN_DESC* desc) { *desc = {}; return S_OK; }
    HRESULT GetBuffer(UINT index, ID3D12Resource** output) {
        assert(index < 2); *output = &buffers[index]; (*output)->AddRef(); return S_OK;
    }
};
struct Fence { UINT64 GetCompletedValue() { return 999; } HRESULT SetEventOnCompletion(UINT64, void*) { return S_OK; } };
struct Queue { HRESULT Signal(Fence*, UINT64) { return S_OK; } };
unsigned WaitForSingleObject(void*, unsigned) { assert(false && "unexpected blocking wait"); return 0; }
struct FakeFG {
    bool releaseOk = false;
    unsigned attempts = 0;
    void* context = reinterpret_cast<void*>(1);
    struct MutexType { int getOwner() const { return 0; } } Mutex;
    void* SwapchainContext() const { return context; }
    HWND Hwnd() const { return reinterpret_cast<void*>(1); }
    void Deactivate() {}
    bool UsesLifetimeObservers() const { return true; }
    bool ReleaseSwapchain(HWND) { ++attempts; return releaseOk; }
};
enum class FGOutput { XeFG, Other };
struct Flag { bool enabled = false; bool value_or_default() const { return enabled; } };
struct Config { Flag FGPreserveSwapChain; static Config* Instance() { static Config config; return &config; } };
struct State {
    IUnknown* currentFGSwapchain = nullptr;
    IUnknown* currentWrappedSwapchain = nullptr;
    FakeFG* currentFG = nullptr;
    Queue* currentCommandQueue = nullptr;
    DXGI_SWAP_CHAIN_DESC currentSwapchainDesc;
    bool isShuttingDown = false;
    FGOutput activeFgOutput = FGOutput::XeFG;
    IUnknown* currentSwapchain = nullptr;
    IUnknown* currentRealSwapchain = nullptr;
    static State& Instance() { static State state; return state; }
};
IUnknown* oldSwapChain = nullptr;
std::vector<ID3D12Resource*> oldBackBuffers;
Fence* resizeFence = nullptr;
void* resizeFenceEvent = nullptr;
UINT64 resizeFenceValue = 0;
HWND _hwnd = reinterpret_cast<void*>(1);
ULONG o_FGRelease(IUnknown* object) { return object->Release(); }
struct FGHooks { static ULONG hkFGRelease(IUnknown*); };
static unsigned wrapperDestructions = 0, menuCleanups = 0;
unsigned long InterlockedDecrement(long* value) { return --*value; }
unsigned long InterlockedIncrement(long* value) { return ++*value; }
namespace MenuOverlayDx { void CleanupRenderTarget(bool, HWND) { ++menuCleanups; } }
struct WrappedIDXGISwapChain4 : IUnknown {
    long _refcount = 1;
    HWND _handle = reinterpret_cast<void*>(1);
    IUnknown* _real = nullptr;
    explicit WrappedIDXGISwapChain4(IUnknown* real) : _real(real) {}
    ~WrappedIDXGISwapChain4() { ++wrapperDestructions; }
    ULONG Release();
};

// ACTUAL_RELEASE_FUNCTION
// ACTUAL_WRAPPER_RELEASE_FUNCTION

int main() {
    for (auto selected : {FGOutput::XeFG, FGOutput::Other})
    for (bool releaseOk : {false, true}) {
        State::Instance() = State{};
        oldSwapChain = nullptr; oldBackBuffers.clear();
        IDXGISwapChain chain;
        IUnknown wrapped; wrapped.refs = 3;
        FakeFG fg; fg.releaseOk = releaseOk;
        auto& state = State::Instance();
        state.activeFgOutput = selected;
        state.currentFGSwapchain = &chain;
        state.currentWrappedSwapchain = &wrapped;
        state.currentFG = &fg;
        FGHooks::hkFGRelease(&chain);
        assert(fg.attempts == 1);
#if CHECK_REFERENCE_OWNERSHIP
        // The caller does not own the other backbuffer/wrapper references.
        assert(chain.buffers[0].refs == 4 && chain.buffers[1].refs == 4);
        assert(chain.buffers[0].releases <= chain.buffers[0].adds);
        assert(chain.buffers[1].releases <= chain.buffers[1].adds);
        assert(wrapped.refs == 3 && wrapped.releases == 0);
#endif
#if CHECK_RELEASE_FAILURE
        if (!releaseOk) {
            assert(state.currentFGSwapchain == &chain);
            assert(state.currentWrappedSwapchain == &wrapped);
            assert(chain.refs != 0 && wrapped.releases == 0);
        } else {
            assert(state.currentFGSwapchain == nullptr);
        }
#endif
    }
#if CHECK_WRAPPER_RELEASE
    for (auto selected : {FGOutput::XeFG, FGOutput::Other}) {
        wrapperDestructions = menuCleanups = 0;
        State::Instance() = State{};
        IUnknown real; real.refs = 2;
        FakeFG fg;
        auto* wrapper = new WrappedIDXGISwapChain4(&real);
        auto& state = State::Instance();
        state.activeFgOutput = selected;
        state.currentFG = &fg;
        state.currentFGSwapchain = &real;
        state.currentSwapchain = state.currentRealSwapchain = state.currentWrappedSwapchain = wrapper;
        assert(wrapper->Release() == 1);
        assert(fg.attempts == 1 && real.releases == 0 && wrapperDestructions == 0 && menuCleanups == 0);
        assert(wrapper->_refcount == 1 && state.currentWrappedSwapchain == wrapper);
        assert(state.currentSwapchain == wrapper && state.currentRealSwapchain == wrapper);
        assert(state.currentFGSwapchain == &real);
        fg.releaseOk = true;
        assert(wrapper->Release() == 0);
        assert(fg.attempts == 2 && real.releases == 1 && real.refs == 1);
        assert(wrapperDestructions == 1 && menuCleanups == 1);
        assert(state.currentWrappedSwapchain == nullptr && state.currentSwapchain == nullptr);
    }
#endif
    std::cout << "Actual FG release failure propagation and borrowed-reference ownership passed\n";
}
