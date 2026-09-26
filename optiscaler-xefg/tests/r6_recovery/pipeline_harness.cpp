
#include <cassert>
#include <atomic>
#include <optional>
#include <cstring>
#include <limits>
#include <latch>
#include <thread>
#include <framegen/xefg/XeFGRecovery.h>
#include <framegen/xefg/XeFGCapacityPolicy.h>
#include <misc/XeFGPresentDiagnostics.h>
#include <misc/LongSessionTiming.h>
#include <misc/XeFGProgressDiagnostics.h>
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
using UINT = unsigned; using UINT64 = uint64_t;using HRESULT=int32_t;constexpr HRESULT S_OK=0;
#define SUCCEEDED(x) ((x)>=0)
#define LOG_FUNC() ((void)0)
#define LOG_INFO(...) ((void)0)
namespace XeFGDiagnostics{inline std::atomic<uint64_t> testNow{0};inline uint64_t WorkNowMs(){return testNow.load();}}
namespace XeFGPacing{inline void RequestReset(){} inline double RenderTimeMs(){return 16.0;} inline void NoteFedFrameTime(float){}}
struct XMFLOAT3{float x,y,z;};struct XMVECTOR{float x=0,y=0,z=0,w=0;};struct XMMATRIX{XMVECTOR r[4];};
inline XMVECTOR XMLoadFloat3(const XMFLOAT3*){return {};}
inline float XMVectorGetX(XMVECTOR a){return a.x;}inline float XMVectorGetY(XMVECTOR a){return a.y;}inline float XMVectorGetZ(XMVECTOR a){return a.z;}
inline XMVECTOR XMVector3Dot(XMVECTOR,XMVECTOR){return {};}
inline XMVECTOR XMVectorSet(float x,float y,float z,float w){return {x,y,z,w};}
inline bool XMScalarNearEqual(float a,float b,float){return a==b;}
inline XMMATRIX XMMatrixPerspectiveFovLH(float,float,float,float){return {};}
struct xefg_swapchain_frame_constant_data_t{float viewMatrix[16]{},projectionMatrix[16]{};float jitterOffsetX=0,jitterOffsetY=0,motionVectorScaleX=0,motionVectorScaleY=0,frameRenderTime=0;bool resetHistory=false;};
constexpr int XEFG_SWAPCHAIN_UI_COMPOSITION_STATE_ENABLED=1,XEFG_SWAPCHAIN_UI_COMPOSITION_STATE_DISABLED=0;
constexpr int XEFG_SWAPCHAIN_DEBUG_FEATURE_TAG_INTERPOLATED_FRAMES=0,XEFG_SWAPCHAIN_DEBUG_FEATURE_SHOW_ONLY_INTERPOLATION=1,XEFG_SWAPCHAIN_RES_BACKBUFFER=99;
enum class FrameTimeSource{Input,Opti,Zero};
namespace GameQuirk{constexpr unsigned ForceFGRenderSizeMVs=1;}

constexpr int BUFFER_COUNT = 4;
enum D3D12_RESOURCE_STATES { D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE,
    D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS };
using DXGI_FORMAT = int;
constexpr DXGI_FORMAT DXGI_FORMAT_UNKNOWN = 0;
enum FG_ResourceType : uint32_t {Depth=0,Velocity,HudlessColor,UIColor,Distortion,ResourceTypeCOUNT};
enum class FG_ResourceValidity { ValidNow, UntilPresent, UntilPresentFromDispatch, ValidButMakeCopy, JustTrackCmdlist };
enum class FGInput { Upscaler, Other };
struct feature_version {
    int major, minor, patch;
    bool operator<(const feature_version& rhs) const {
        return std::tie(major, minor, patch) < std::tie(rhs.major, rhs.minor, rhs.patch);
    }
};
struct ID3D12GraphicsCommandList {};using ID3D12CommandList=ID3D12GraphicsCommandList;
struct Desc { int Format = 28; UINT64 Width=2560; UINT Height=1440; };
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
template<class T> struct Option{T value{};bool set=false;T value_or_default()const{return value;}T value_or(T fallback)const{return set?value:fallback;}bool has_value()const{return set;}Option& operator=(T v){value=v;set=true;return *this;}};
struct Config {
    Flag FGDisableHudless, FGOnlyAcceptFirstHudless, FGDisableUI, FGDrawUIOverFG,
         FGResourceFlip, FGXeFGDepthInverted;
    Flag FGEnabled{true},FGXeFGIgnoreInitChecks{true},FGXeFGUIComposition,FGXeFGDebugView,FGSkipReset;
    Option<int> FGXeFGInterpolationCount{5,true},FGAllowedFrameAhead{3,true};
    Option<UINT> FGRectLeft,FGRectTop,FGRectWidth,FGRectHeight;
    Option<FrameTimeSource> FTInput{FrameTimeSource::Input,true};
    static Config* Instance() { static Config instance; return &instance; }
};
struct FakeFeature{UINT RenderWidth(){return 2560;}UINT DisplayWidth(){return 3840;}};
struct State {
    bool fgHudlessCompare = false, fgChanged = false;
    FGInput activeFgInput = FGInput::Other;
    FakeFeature* currentFeature=nullptr;unsigned gameQuirks=0;
    unsigned fgLastFrame=0;bool WAR_xefgRequestFGToggle=false,fgOnlyGenerated=false;double lastFGFrameTime=16.0;
    struct {struct {UINT Width=2560,Height=1440;} BufferDesc;} currentSwapchainDesc;
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
enum xefg_swapchain_result_t { XEFG_SWAPCHAIN_RESULT_SUCCESS = 0, XEFG_SWAPCHAIN_RESULT_ERROR = -14,
    XEFG_SWAPCHAIN_RESULT_ERROR_UNSUPPORTED_DEVICE=-1,XEFG_SWAPCHAIN_RESULT_ERROR_UNSUPPORTED_DRIVER=-2,
    XEFG_SWAPCHAIN_RESULT_ERROR_UNINITIALIZED=-3,XEFG_SWAPCHAIN_RESULT_ERROR_NOT_IMPLEMENTED=-7,
    XEFG_SWAPCHAIN_RESULT_ERROR_INVALID_CONTEXT=-8,XEFG_SWAPCHAIN_RESULT_ERROR_CANT_LOAD_LIBRARY=-11,
    XEFG_SWAPCHAIN_RESULT_ERROR_LATENCY_REDUCTION_FUNCTION_MISSING=-16 };
constexpr int XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT = 1;
struct xefg_swapchain_d3d12_resource_data_t {
    ID3D12Resource* resource = nullptr;
    D3D12_RESOURCE_STATES incomingState = D3D12_RESOURCE_STATE_COMMON;
    int validity = XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT;int type=0;struct Pair{UINT x=0,y=0;} resourceBase,resourceSize;
};
struct XeFGProxy {
    inline static ID3D12Resource* lastTagged = nullptr;
    inline static unsigned tagCalls = 0; inline static bool failTag=false;
    inline static bool enabled=true;inline static int32_t enableResult=0,disableResult=0,resourceResult=0,constantsResult=0,presentIdResult=0,backbufferResult=0;
    inline static unsigned enableCalls=0,disableCalls=0,tagsWhileDisabled=0,constantsCalls=0,idCalls=0;
    inline static std::vector<char> order;inline static uint32_t acceptedMask=0,lastTagFrame=0,lastConstantsFrame=0,lastIdFrame=0;
    inline static std::latch* controlEntered=nullptr;inline static std::latch* controlMayReturn=nullptr;
    static xefg_swapchain_result_t Control(void*,bool wantEnabled){
        (wantEnabled?enableCalls:disableCalls)++;order.push_back(wantEnabled?'E':'D');
        if(controlEntered)controlEntered->count_down();if(controlMayReturn)controlMayReturn->wait();
        auto result=wantEnabled?enableResult:disableResult;
        if(result==0){enabled=wantEnabled;acceptedMask=0;lastConstantsFrame=lastIdFrame=0;}
        return static_cast<xefg_swapchain_result_t>(result);
    }
    static auto SetEnabled(){return &Control;}
    static xefg_swapchain_result_t Ui(void*,int){return XEFG_SWAPCHAIN_RESULT_SUCCESS;}
    static auto SetUiCompositionState(){return static_cast<decltype(&Ui)>(nullptr);}
    static auto SetNumInterpolatedFrames(){return static_cast<decltype(&Ui)>(nullptr);}
    static xefg_swapchain_result_t Debug(void*,int,bool,void*){return XEFG_SWAPCHAIN_RESULT_SUCCESS;}
    static auto EnableDebugFeature(){return &Debug;}
    static xefg_swapchain_result_t Constants(void*,uint32_t frame,xefg_swapchain_frame_constant_data_t*){
        ++constantsCalls;order.push_back('C');if(enabled&&constantsResult==0)lastConstantsFrame=frame;
        return static_cast<xefg_swapchain_result_t>(constantsResult);
    }
    static auto TagFrameConstants(){return &Constants;}
    static xefg_swapchain_result_t Id(void*,uint32_t frame){++idCalls;order.push_back('I');if(enabled&&presentIdResult==0)lastIdFrame=frame;return static_cast<xefg_swapchain_result_t>(presentIdResult);}
    static auto SetPresentId(){return &Id;}
    static void Reset(){enabled=true;failTag=false;enableResult=disableResult=resourceResult=constantsResult=presentIdResult=backbufferResult=0;
       tagCalls=enableCalls=disableCalls=tagsWhileDisabled=constantsCalls=idCalls=0;order.clear();acceptedMask=0;lastTagFrame=lastConstantsFrame=lastIdFrame=0;controlEntered=controlMayReturn=nullptr;}

    static xefg_swapchain_result_t Tag(void*, ID3D12GraphicsCommandList*, uint32_t frame,
                                      xefg_swapchain_d3d12_resource_data_t* data) {
        if(data->type==XEFG_SWAPCHAIN_RES_BACKBUFFER){++tagCalls;return static_cast<xefg_swapchain_result_t>(backbufferResult);}
        assert(data->resource && data->resource->live);
        assert(data->resource->actualState == data->incomingState);
        lastTagged = data->resource; ++tagCalls;
        order.push_back('T');auto result=failTag?-1:resourceResult;
        if(!enabled)++tagsWhileDisabled;
        if(enabled&&result==0){if(lastTagFrame!=frame)acceptedMask=0;lastTagFrame=frame;acceptedMask|=1u<<data->type;}
        return static_cast<xefg_swapchain_result_t>(result);
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
    bool _lifecycleFailed=false,_isActive=true,paused=false,failCopy=false;bool& active=_isActive;
    XeFGRecovery _recovery;std::mutex _recoveryActionMutex;
    DXGI_FORMAT _hudlessObservedFormat[BUFFER_COUNT]{},_hudlessAcceptedFormat[BUFFER_COUNT]{};
    std::atomic<uint64_t> _lastRecoveryLogMs{0};
    std::atomic<uint64_t> _lastFormatLogMs[2]{},_formatTransitions[2]{};
    void ReportFormatTransition(bool,DXGI_FORMAT,DXGI_FORMAT,UINT64,int,UINT64,UINT);void* _fgContext=reinterpret_cast<void*>(1);
    bool _waitingNewFrameData=false;uint64_t _lastDispatchedFrame=0;
    unsigned historyRequests=0;int currentSlot=0;
    void RequestHistoryReset(){++historyRequests;}uint64_t PendingHistoryResetToken(uint64_t){return historyRequests;}
    void AcknowledgeHistoryReset(uint64_t){}
    bool TryBeginRecoveryTrial(UINT64);void NoteRecoveryFault(UINT64,const char*,int32_t);
    // Progress methods execute against their real bodies in r7_progress.
    void PollGpuProgress() {}
    void PreparePresent();void MarkFrameConstantsReady(UINT64);UINT64 PresentRecoveryToken();
    void ObservePresentStatus(UINT64,HRESULT,int32_t,uint32_t,int32_t,bool);void Activate();
    bool Dispatch();bool IsLowResMV()const{return true;}
    bool _uiComposition=false,_infiniteDepth=false;std::optional<bool> _haveHudless;
    int _maxInterpolationCount=5,_framesToInterpolate=5;
    // This recovery fixture starts with an already initialized full-capacity
    // context. R8 tests exercise smaller capacities and pending requests.
    std::atomic<int> _initializedInterpolationCapacity{5};
    int _lastCapacityRequest=-1;
    int GameRequestedInterpolationCount(){return 5;}
    UINT64 _lastFGFrame=0;
    int GetDispatchIndex(UINT64& frame);
    bool HasResource(FG_ResourceType type,int slot){return _frameResources[slot].contains(type);}
    bool IsUsingHudless(int slot){return !_noHudless[slot];}
    void ReportResourceDiagnostics(){}
    float _cameraPosition[BUFFER_COUNT][3]{},_cameraRight[BUFFER_COUNT][3]{},_cameraUp[BUFFER_COUNT][3]{},_cameraForward[BUFFER_COUNT][3]{};
    float _cameraNear[BUFFER_COUNT]{},_cameraFar[BUFFER_COUNT]{},_cameraVFov[BUFFER_COUNT]{},_cameraAspectRatio[BUFFER_COUNT]{};
    float _jitterX[BUFFER_COUNT]{},_jitterY[BUFFER_COUNT]{},_mvScaleX[BUFFER_COUNT]{},_mvScaleY[BUFFER_COUNT]{};
    bool _reset[BUFFER_COUNT]{};double _ftDelta[BUFFER_COUNT]{};
    UINT _interpolationWidth[BUFFER_COUNT]{},_interpolationHeight[BUFFER_COUNT]{};
    std::optional<UINT> _interpolationLeft[BUFFER_COUNT],_interpolationTop[BUFFER_COUNT];
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
    int GetIndex() const { return currentSlot; }
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
        xefg_swapchain_d3d12_resource_data_t data{entry.GetResource(),entry.state};data.type=static_cast<int>(type);return data;
    }
    void ResourceBarrier(ID3D12GraphicsCommandList*, ID3D12Resource*, D3D12_RESOURCE_STATES, D3D12_RESOURCE_STATES) {}
    unsigned updateTargetCalls=0;
    void UpdateTarget() {++updateTargetCalls;}
    void Deactivate() { active = false; }
    void DeactivateForReason(XeFGProgress::DeactivateReason) { Deactivate(); }
    void SetResourceReady(FG_ResourceType type, int slot) { _resourceReady[slot][type] = true; ++readinessCalls; }
    bool SetResource(Dx12Resource* inputResource);
};
// This alias keeps the extracted base-class function body and signature intact
// while the CPU harness supplies the virtual/backend boundary in one fake class.
using IFGFeature_Dx12 = XeFG_Dx12;
using IFGFeature = XeFG_Dx12;

// ASSERT_SHIM
// ACTUAL_FUNCTIONS
// TEST_BODY
