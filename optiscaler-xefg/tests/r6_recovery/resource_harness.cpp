
#include <cassert>
#include <cstdint>
#include <format>
#include <iostream>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>
#if __has_include("framegen/FGWorkGate.h")
#include "framegen/FGWorkGate.h"
#else
// Historical R2/R3 local audits contain no admission calls.
struct FGWorkGate { struct Scope { explicit operator bool() const { return true; } }; Scope TryEnter() { return {}; } };
#endif
#if __has_include("misc/XeFGResourceDiagnostics.h")
#define TEST_HAS_DIAGNOSTICS 1
#include "misc/XeFGResourceDiagnostics.h"
#endif
#define LOG_ERROR(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
using UINT = unsigned; using UINT64 = uint64_t;
constexpr int BUFFER_COUNT = 4;
enum D3D12_RESOURCE_STATES { D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE,
    D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS };
using DXGI_FORMAT = int;
constexpr DXGI_FORMAT DXGI_FORMAT_UNKNOWN = 0;
enum class FG_ResourceType { UIColor, Depth, Velocity, HudlessColor, Distortion };
enum class FG_ResourceValidity { ValidNow, UntilPresent, UntilPresentFromDispatch, ValidButMakeCopy, JustTrackCmdlist };
enum class FGInput { Upscaler, Other };
struct feature_version {
    int major, minor, patch;
    bool operator<(const feature_version& rhs) const {
        return std::tie(major, minor, patch) < std::tie(rhs.major, rhs.minor, rhs.patch);
    }
};
struct ID3D12GraphicsCommandList {};
struct Desc { int Format = 28; };
struct ID3D12Device {
    struct AllocationInfo { uint64_t SizeInBytes = 8192; };
    AllocationInfo GetResourceAllocationInfo(unsigned, unsigned, const Desc*) { return {}; }
};
struct ID3D12Resource {
    bool live = true; unsigned descCalls = 0; int format=28;
    D3D12_RESOURCE_STATES actualState = D3D12_RESOURCE_STATE_COMMON;
    Desc GetDesc() { assert(live && "accessed expired borrowed resource"); ++descCalls; return {format}; }
    void SetName(const wchar_t*) {}
};
struct Dx12Resource {
    FG_ResourceType type = FG_ResourceType::HudlessColor;
    ID3D12Resource* resource = nullptr;
    UINT top = 0, left = 0; UINT64 width = 2560; UINT height = 1440;
    ID3D12GraphicsCommandList* cmdList = nullptr;
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
    FG_ResourceValidity validity = FG_ResourceValidity::UntilPresent;
    ID3D12Resource* copy = nullptr; int frameIndex = -1; bool waitingExecution = false;
    ID3D12Resource* GetResource() { return copy ? copy : resource; }
};
struct Flag { bool value = false; bool value_or_default() const { return value; } };
struct Config {
    Flag FGDisableHudless, FGOnlyAcceptFirstHudless, FGDisableUI, FGDrawUIOverFG,
         FGResourceFlip, FGXeFGDepthInverted;
    static Config* Instance() { static Config instance; return &instance; }
};
struct State {
    bool fgHudlessCompare = false, fgChanged = false;
    FGInput activeFgInput = FGInput::Other;
    static State& Instance() { static State instance; return instance; }
};
struct DI_Dx12 {
    DI_Dx12(const char*, ID3D12Device*) {}
    bool IsInit() const { return false; }
    bool CreateBufferResource(ID3D12Device*, ID3D12Resource*, UINT64, UINT, D3D12_RESOURCE_STATES) { return false; }
    ID3D12Resource* Buffer() const { return nullptr; }
    void SetBufferState(ID3D12GraphicsCommandList*, D3D12_RESOURCE_STATES) {}
    bool Dispatch(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*) { return false; }
};
struct RF_Dx12 {
    RF_Dx12(const char*, ID3D12Device*) {}
    bool IsInit() const { return true; }
    bool Dispatch(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*, UINT64, UINT, bool) { return true; }
};
enum xefg_swapchain_result_t { XEFG_SWAPCHAIN_RESULT_SUCCESS = 0, XEFG_SWAPCHAIN_RESULT_ERROR = -1 };
constexpr int XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT = 1;
struct xefg_swapchain_d3d12_resource_data_t {
    ID3D12Resource* resource = nullptr;
    D3D12_RESOURCE_STATES incomingState = D3D12_RESOURCE_STATE_COMMON;
    int validity = XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT;
};
struct XeFGProxy {
    inline static ID3D12Resource* lastTagged = nullptr;
    inline static unsigned tagCalls = 0; inline static bool failTag=false;
    static void* SetUiCompositionState() { return reinterpret_cast<void*>(1); }
    static xefg_swapchain_result_t Tag(void*, ID3D12GraphicsCommandList*, uint32_t,
                                      xefg_swapchain_d3d12_resource_data_t* data) {
        assert(data->resource && data->resource->live);
        assert(data->resource->actualState == data->incomingState);
        lastTagged = data->resource; ++tagCalls;
        return failTag ? XEFG_SWAPCHAIN_RESULT_ERROR : XEFG_SWAPCHAIN_RESULT_SUCCESS;
    }
    static auto D3D12TagFrameResource() { return &Tag; }
};
struct XeFG_Dx12 {
    FGWorkGate _workGate;
    auto AcquireWork() { return _workGate.TryEnter(); }
#if TEST_HAS_DIAGNOSTICS
    XeFGDiagnostics::Context _resourceDiagnostics;
    struct CopyAllocationInfo { uint64_t bytes = 0; bool known = false; };
    std::unordered_map<FG_ResourceType, CopyAllocationInfo> _copyAllocationInfo[BUFFER_COUNT];
#endif
    bool _lifecycleFailed = false, active = true, paused = false, failCopy = false;
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, Dx12Resource> _frameResources[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, ID3D12Resource*> _resourceCopy[BUFFER_COUNT];
    std::unordered_map<FG_ResourceType, bool> _resourceReady[BUFFER_COUNT];
    bool _noHudless[BUFFER_COUNT] {true,true,true,true};
    bool _noUi[BUFFER_COUNT] {true,true,true,true};
    bool _noDistortionField[BUFFER_COUNT] {true,true,true,true};
    ID3D12Device* _device = nullptr;
    std::unique_ptr<DI_Dx12> _depthInvert;
    std::unique_ptr<RF_Dx12> _depthFlip, _mvFlip;
    uint64_t _frameCount = 8;
    void* _swapChainContext = reinterpret_cast<void*>(1);
    ID3D12Resource freshCopy;
    ID3D12Resource* nextFlipOutput = &freshCopy;
    unsigned copyCalls = 0, readinessCalls = 0;
    unsigned pendingCalls = 0;
    bool pendingOk = true;
    bool TrackPendingCommandList(ID3D12GraphicsCommandList*) { ++pendingCalls; return pendingOk; }
    bool IsActive() const { return active; }
    bool IsPaused() const { return paused; }
    int GetIndex() const { return 0; }
    static feature_version Version() { return {1,3,1}; }
#if R4_SOURCE
    void FlipResource(Dx12Resource*);
    void RecordCopyAllocation(int, FG_ResourceType, ID3D12Resource*);
    // ACTUAL_INLINE_FAILURE_HANDLER
#else
    void FlipResource(Dx12Resource*) { assert(false && "unexpected test branch"); }
#endif
    bool CreateBufferResource(ID3D12Device*, ID3D12Resource*, D3D12_RESOURCE_STATES state,
                              ID3D12Resource** output, bool, bool) {
        if (failCopy) return false;
        *output = nextFlipOutput; (*output)->actualState = state; return true;
    }
    ID3D12GraphicsCommandList* GetUICommandList(int) { return nullptr; }
    bool CopyResource(ID3D12GraphicsCommandList*, ID3D12Resource* src, ID3D12Resource** out, D3D12_RESOURCE_STATES) {
        assert(src && src->live); ++copyCalls;
        if (failCopy) return false;
        freshCopy.actualState = D3D12_RESOURCE_STATE_COPY_DEST;
        *out = &freshCopy; return true;
    }
    xefg_swapchain_d3d12_resource_data_t GetResourceData(FG_ResourceType type, int slot) {
        auto& entry = _frameResources[slot].at(type);
        return {entry.GetResource(), entry.state};
    }
    void ResourceBarrier(ID3D12GraphicsCommandList*, ID3D12Resource*, D3D12_RESOURCE_STATES, D3D12_RESOURCE_STATES) {}
    unsigned updateTargetCalls=0;
    void UpdateTarget() {++updateTargetCalls;}
    void Deactivate() { active = false; }
    void SetResourceReady(FG_ResourceType type, int slot) { _resourceReady[slot][type] = true; ++readinessCalls; }
    bool SetResource(Dx12Resource* inputResource);
};
// This alias keeps the extracted base-class function body and signature intact
// while the CPU harness supplies the virtual/backend boundary in one fake class.
using IFGFeature_Dx12 = XeFG_Dx12;

// ASSERT_SHIM
// ACTUAL_FUNCTIONS
// TEST_BODY
