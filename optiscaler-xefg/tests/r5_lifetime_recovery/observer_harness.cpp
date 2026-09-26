#include "framegen/FGWorkGate.h"
#include "misc/XeFGWorkDiagnostics.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <condition_variable>
#include <latch>
#include <thread>
#include <iostream>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>
using UINT=unsigned; using UINT64=std::uint64_t; using ULONG=unsigned long;
using LONG=long; using HRESULT=int; using PVOID=void*; using GUID=unsigned;
constexpr HRESULT S_OK=0, E_NOINTERFACE=-1;
constexpr LONG NO_ERROR=0, ERROR_INVALID_PARAMETER=87;
constexpr int D3D12_COMMAND_LIST_TYPE_DIRECT=0, D3D12_COMMAND_QUEUE_FLAG_NONE=0;
constexpr int D3D12_COMMAND_QUEUE_PRIORITY_NORMAL=0, D3D12_HEAP_TYPE_UPLOAD=0;
constexpr int D3D12_HEAP_FLAG_NONE=0, D3D12_RESOURCE_STATE_GENERIC_READ=0;
constexpr unsigned BUFFER_COUNT=4;
#define STDMETHODCALLTYPE
#define IID_PPV_ARGS(x) x
#define SUCCEEDED(x) ((x)>=0)
#define FAILED(x) ((x)<0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
#define LOG_TRACK(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_FUNC() ((void)0)

static std::unordered_map<void*,void*> installed;
static std::vector<std::pair<void*,void*>> staged;
static unsigned attachCalls=0, transactions=0;
static int failAt=0; // 1 Begin, 2 Update, 3..5 Attach, 6 Commit.
LONG DetourTransactionBegin(){ ++transactions; staged.clear(); attachCalls=0; return failAt==1 ? 5 : 0; }
void* GetCurrentThread(){ return nullptr; }
LONG DetourUpdateThread(void*){ return failAt==2 ? 5 : 0; }
template<class F> LONG DetourAttach(PVOID* original,F hook){
    ++attachCalls;
    if(failAt==static_cast<int>(attachCalls)+2) return 5;
    assert(*original!=nullptr && !installed.contains(*original));
    for(auto [address,callback]:staged) assert(address!=*original);
    staged.push_back({*original,reinterpret_cast<void*>(hook)}); return 0;
}
template<class F> LONG DetourDetach(PVOID* original,F){ staged.push_back({*original,nullptr}); return 0; }
LONG DetourTransactionCommit(){
    if(failAt==6){ staged.clear(); return 5; }
    for(auto [target,hook]:staged) { if(hook) installed[target]=hook; else installed.erase(target); }
    staged.clear(); return 0;
}
LONG DetourTransactionAbort(){ staged.clear(); return 0; }
template<class F> F route(F original){
    auto it=installed.find(reinterpret_cast<void*>(original));
    return it==installed.end() ? original : reinterpret_cast<F>(it->second);
}

struct ID3D12Resource; struct ID3D12GraphicsCommandList; struct ID3D12CommandQueue;
struct ID3D12CommandAllocator; struct ID3D12PipelineState {};
struct ID3D12CommandList;
using PFN_Release=ULONG(*)(ID3D12Resource*);
using PFN_ExecuteCommandLists=void(*)(ID3D12CommandQueue*,UINT,ID3D12CommandList* const*);
using PFN_ResetCommandList=HRESULT(*)(ID3D12GraphicsCommandList*,ID3D12CommandAllocator*,ID3D12PipelineState*);
static ULONG NativeRelease(ID3D12Resource*);
static ULONG NativeDeviceRelease(ID3D12Resource*);
static void NativeExecute(ID3D12CommandQueue*,UINT,ID3D12CommandList* const*);
static HRESULT NativeReset(ID3D12GraphicsCommandList*,ID3D12CommandAllocator*,ID3D12PipelineState*);
struct IUnknown {
    void** vtable=nullptr; // Deliberately first: actual production vtable inspection.
    ULONG refs=1; unsigned releases=0;
    IUnknown* real=nullptr;
    HRESULT QueryInterface(GUID,void** output){
        if(!real){*output=nullptr;return E_NOINTERFACE;}
        *output=real; real->AddRef(); return S_OK;
    }
    template<class T> HRESULT QueryInterface(T** output){ *output=nullptr; return E_NOINTERFACE; }
    ULONG AddRef(){return ++refs;}
    ULONG Release(){
        auto method=reinterpret_cast<PFN_Release>(vtable[2]);
        return route(method)(reinterpret_cast<ID3D12Resource*>(this));
    }
};
struct ID3D12Resource: IUnknown {};
struct ID3D12CommandList: ID3D12Resource {};
struct ID3D12GraphicsCommandList: ID3D12CommandList {
    HRESULT Close(){return S_OK;}
    HRESULT Reset(){return route(reinterpret_cast<PFN_ResetCommandList>(vtable[10]))(this,nullptr,nullptr);}
};
struct ID3D12CommandAllocator: IUnknown {};
struct ID3D12CommandQueue: IUnknown {
    unsigned executions=0;
    void ExecuteCommandLists(UINT count,ID3D12CommandList* const* lists){
        route(reinterpret_cast<PFN_ExecuteCommandLists>(vtable[10]))(this,count,lists);
    }
};
static ULONG NativeRelease(ID3D12Resource* object){ assert(object->refs>0); ++object->releases; return --object->refs; }
static ULONG NativeDeviceRelease(ID3D12Resource* object){ return NativeRelease(object); }
static HRESULT resetResult=S_OK;
static HRESULT NativeReset(ID3D12GraphicsCommandList*,ID3D12CommandAllocator*,ID3D12PipelineState*){return resetResult;}
static std::latch* nativeEntered=nullptr;
static std::latch* nativeMayReturn=nullptr;
static void NativeExecute(ID3D12CommandQueue* queue,UINT,ID3D12CommandList* const*){
    ++queue->executions;
    if(nativeEntered) nativeEntered->count_down();
    if(nativeMayReturn) nativeMayReturn->wait();
}
// MSVC /OPT:ICF merges identical empty template bodies. Native COM methods
// below need distinct target identities so duplicate-detour checks model the
// real vtable rather than linker folding in this CPU fixture.
static volatile int dummyIdentity=0;
template<int N> void dummy() { dummyIdentity=N; }
static std::array<void*,48> deviceTable,queueTable,listTable,allocatorTable,resourceTable;
static void InitializeTables(){
    assert(reinterpret_cast<void*>(&dummy<22>) != reinterpret_cast<void*>(&dummy<16>) &&
           "fake native vtable methods must retain distinct linker identities");
    deviceTable.fill(nullptr);queueTable.fill(nullptr);listTable.fill(nullptr);allocatorTable.fill(nullptr);
    deviceTable[2]=reinterpret_cast<void*>(&NativeDeviceRelease);
    deviceTable[22]=reinterpret_cast<void*>(&dummy<22>);deviceTable[16]=reinterpret_cast<void*>(&dummy<16>);
    queueTable[2]=allocatorTable[2]=resourceTable[2]=listTable[2]=reinterpret_cast<void*>(&NativeRelease);
    queueTable[10]=reinterpret_cast<void*>(&NativeExecute);listTable[10]=reinterpret_cast<void*>(&NativeReset);
}
struct D3D12_COMMAND_QUEUE_DESC {int Type=0,Flags=0,NodeMask=0,Priority=0;};
struct CD3DX12_RESOURCE_DESC {static int Buffer(int n){return n;}};
struct CD3DX12_HEAP_PROPERTIES {explicit CD3DX12_HEAP_PROPERTIES(int){}};
// GPU allocation/residency diagnostics are an external boundary in this
// lifetime-observer suite. Their real hook/notifier behavior is checked by R6.
struct LUID { unsigned LowPart=1; long HighPart=0; };
static bool IsEqualLUID(LUID a,LUID b){return a.LowPart==b.LowPart && a.HighPart==b.HighPart;}
static uint64_t ResidencyLuidKey(LUID a){return (uint64_t(uint32_t(a.HighPart))<<32)|a.LowPart;}
enum class VendorId { AMD, Other };
namespace IdentifyGpu {
struct Gpu { LUID luid; VendorId vendorId=VendorId::AMD; };
static std::array<Gpu,1> getAllGpus(){return {};}
}
static std::atomic<bool> residencyAmdKnown{false};
static std::atomic<uint64_t> residencyAmdLuid{0};
static bool coreUeHooksInstalled=false;
struct ID3D12Device1: IUnknown {};
struct ID3D12Device: IUnknown {
    ID3D12CommandQueue queue;ID3D12GraphicsCommandList list;
    ID3D12CommandAllocator allocator;ID3D12Resource resource;
    LUID GetAdapterLuid(){return {};}
    ID3D12Device(){vtable=deviceTable.data();queue.vtable=queueTable.data();list.vtable=listTable.data();
        allocator.vtable=allocatorTable.data();resource.vtable=resourceTable.data();}
    HRESULT CreateCommandQueue(D3D12_COMMAND_QUEUE_DESC*,ID3D12CommandQueue** out){queue.refs=1;*out=&queue;return S_OK;}
    HRESULT CreateCommandAllocator(int,ID3D12CommandAllocator** out){allocator.refs=1;*out=&allocator;return S_OK;}
    HRESULT CreateCommandList(int,int,ID3D12CommandAllocator*,void*,ID3D12GraphicsCommandList** out){list.refs=1;*out=&list;return S_OK;}
    HRESULT CreateCommittedResource(CD3DX12_HEAP_PROPERTIES*,int,int*,int,void*,ID3D12Resource** out){resource.refs=1;*out=&resource;return S_OK;}
};
static GUID streamlineRiid=1;static std::once_flag streamlineRiidInitFlag;
HRESULT IIDFromString(const wchar_t*,GUID* value){*value=1;return S_OK;}
namespace Util {template<class T> bool CheckForRealObject(const char*,T* input,IUnknown** out){
    if(!input->real)return false;*out=input->real;return true;}}
template<class T> bool CheckForRealObject(const char* name,T* input,IUnknown** out){return Util::CheckForRealObject(name,input,out);}
enum class FG_ResourceType {Depth,Velocity,UIColor,HudlessColor};
enum class FGInput {DLSSG,Upscaler,NvngxFG};enum class FGOutput {XeFG,DLSSG};enum class SwapchainInteropApi {None};
struct Flag {bool value=false;bool value_or_default()const{return value;}};
struct Config {Flag FGDisableHUDFix{true},UESpoofIntelAtomics64;static Config* Instance(){static Config c;return &c;}};
struct XeFG_Dx12;
struct State {
    XeFG_Dx12* currentFG=nullptr;FGInput activeFgInput=FGInput::DLSSG;FGOutput activeFgOutput=FGOutput::XeFG;
    SwapchainInteropApi swapchainInteropApi=SwapchainInteropApi::None;bool isShuttingDown=false;
    std::unordered_set<ID3D12Resource*> capturedHudlesses;
    static State& Instance(){static State s;return s;}
};
struct Heap {void ClearSlotIfMatches(unsigned,ID3D12Resource*){}};
struct TrackedResourceSlot {std::weak_ptr<Heap> heap;unsigned index=0;};
static std::mutex _trackedResourcesMutex,_resourceCommandListMutex;
static std::unordered_map<ID3D12Resource*,std::vector<TrackedResourceSlot>> _trackedResources;
static std::unordered_set<ID3D12CommandList*> _notFoundCmdLists;
static std::unordered_map<FG_ResourceType,ID3D12CommandList*> _resCmdList[BUFFER_COUNT];

struct XeFG_Dx12 {
    FGWorkGate _workGate,_submissionGate,_providerPresentGate;
    std::mutex _pendingCommandMutex,_lifetimeQueueMutex;
    // ACTUAL_PENDING_FIELDS
    XeFGDiagnostics::WorkDiagnostics _workDiagnostics;
    ID3D12CommandQueue* _gameCommandQueue=nullptr;
    unsigned hudWrites=0;
    auto AcquireWork(){return _workGate.TryEnter();}
    void PublishPendingLocked();
    bool TryCloseCpuAdmission();
    void RestoreCpuAdmission();
    bool QuiesceWork();
    static constexpr size_t MaxLifetimeQueues=8;
    struct LifetimeQueue {ID3D12CommandQueue* queue=nullptr;};
    LifetimeQueue _lifetimeQueues[MaxLifetimeQueues]{};size_t _lifetimeQueueCount=0;
    bool _queueTrackingComplete=true,_objectsDrained=false;
    ID3D12GraphicsCommandList* _uiCommandList[BUFFER_COUNT]{},*_scCommandList[BUFFER_COUNT]{};
    auto AcquireSubmissionWork(){return _submissionGate.TryEnter();}
    bool IsActive()const{return true;}bool IsPaused()const{return false;}int GetIndex()const{return 0;}
    void SetResourceReady(FG_ResourceType){++hudWrites;}void SetCommandQueue(FG_ResourceType,ID3D12CommandQueue*){++hudWrites;}
    TRACK_RETURN TrackPendingCommandList(ID3D12GraphicsCommandList*);
    void BeforeCommandSubmission(ID3D12CommandQueue*,UINT,ID3D12CommandList* const*);
    void AfterCommandSubmission(UINT,ID3D12CommandList* const*);
    void DiscardPendingCommandList(ID3D12GraphicsCommandList*);
    void TrackLifetimeQueue(ID3D12CommandQueue*);
    std::uint64_t CapturePendingCommandListGeneration(const void*);
    void RetirePendingCommandList(const void*,std::uint64_t);
};
static PFN_ExecuteCommandLists o_ExecuteCommandLists=nullptr;
static PFN_ResetCommandList o_ResetCommandList=nullptr;
static PFN_Release o_CommandListRelease=nullptr,o_Release=nullptr;
static std::recursive_mutex lifetimeHookMutex;
static std::atomic<uintptr_t> lifetimeExecuteTarget{0},lifetimeResetTarget{0},lifetimeReleaseTarget{0};
static uintptr_t resourceReleaseTarget=0;
static std::atomic<bool> resourceReleaseViaLifetime{false},lifetimeReleaseViaResource{false};
static unsigned lifetimeInstallFailures=0;
using Generic=void(*)();
using PFN_CreateSampler=Generic;using PFN_CheckFeatureSupport=Generic;using PFN_CreateRootSignature=Generic;
using PFN_GetResourceAllocationInfo=Generic;using PFN_CreateCommittedResource=Generic;using PFN_CreatePlacedResource=Generic;
using PFN_SetResidencyPriority=Generic;
static Generic o_CreateSampler=nullptr,o_CheckFeatureSupport=nullptr,o_CreateRootSignature=nullptr;
static Generic o_GetResourceAllocationInfo=nullptr,o_CreateCommittedResource=nullptr,o_CreatePlacedResource=nullptr;
static Generic o_SetResidencyPriority=nullptr;static PFN_Release o_D3D12DeviceRelease=nullptr;
void hkCreateSampler(){}void hkCreateRootSignature(){}void hkD3D12DeviceRelease(){}void hkSetResidencyPriority(){}
void hkCheckFeatureSupport(){}void hkCreateCommittedResource(){}void hkCreatePlacedResource(){}void hkGetResourceAllocationInfo(){}
namespace GpuAllocationHooks {
static unsigned installCalls=0;
static void Install(ID3D12Device* device,Generic*,Generic,bool){assert(device);++installCalls;}
}
static Generic o_CreateDescriptorHeap=nullptr; void hkCreateDescriptorHeap(){}
static Generic o_CreateRenderTargetView=nullptr; void hkCreateRenderTargetView(){}
static Generic o_CreateShaderResourceView=nullptr; void hkCreateShaderResourceView(){}
static Generic o_CreateUnorderedAccessView=nullptr; void hkCreateUnorderedAccessView(){}
static Generic o_CopyDescriptors=nullptr; void hkCopyDescriptors(){}
static Generic o_CopyDescriptorsSimple=nullptr; void hkCopyDescriptorsSimple(){}
static Generic o_OMSetRenderTargets=nullptr; void hkOMSetRenderTargets(){}
static Generic o_SetGraphicsRootDescriptorTable=nullptr; void hkSetGraphicsRootDescriptorTable(){}
static Generic o_SetComputeRootDescriptorTable=nullptr; void hkSetComputeRootDescriptorTable(){}
static Generic o_DrawIndexedInstanced=nullptr; void hkDrawIndexedInstanced(){}
static Generic o_DrawInstanced=nullptr; void hkDrawInstanced(){}
static Generic o_Dispatch=nullptr; void hkDispatch(){}
static Generic o_Close=nullptr; void hkClose(){}
static Generic o_ExecuteBundle=nullptr; void hkExecuteBundle(){}
void HookToCommandList(ID3D12Device*){}
namespace StreamlineProxy {bool LoadStreamline(){return false;}void InitWithD3D12(ID3D12Device*){}}
struct ResTrack_Dx12 {
    static inline bool hudFix=false;
    static bool IsHudFixActive(){return hudFix;}
    static void HookDevice(ID3D12Device*){assert(false && "HUD hooks enabled in DLSSG-only test");}
    static bool HookLifetimeObservers(ID3D12Device*,ID3D12CommandQueue* =nullptr);
    static bool LifetimeObserversReady(ID3D12GraphicsCommandList*,ID3D12CommandQueue* =nullptr);
    static void hkExecuteCommandLists(ID3D12CommandQueue*,UINT,ID3D12CommandList* const*);
    static ULONG hkCommandListRelease(ID3D12Resource*);
    static ULONG hkRelease(ID3D12Resource*);
    static ULONG ReleaseTrackedResource(ID3D12Resource*,bool);
    static void HookResource(ID3D12Device*);
    static void ReleaseDeviceHooks();
};

// NEGATIVE_ASSERT_SHIM

// ACTUAL_FUNCTIONS

static void ResetInstallation(){
    installed.clear();staged.clear();failAt=0;transactions=0;
    coreUeHooksInstalled=false;residencyAmdKnown=false;residencyAmdLuid=0;GpuAllocationHooks::installCalls=0;
    o_CreateSampler=o_CheckFeatureSupport=o_CreateRootSignature=nullptr;
    o_GetResourceAllocationInfo=o_CreateCommittedResource=o_CreatePlacedResource=nullptr;
    o_D3D12DeviceRelease=nullptr;o_ExecuteCommandLists=nullptr;o_ResetCommandList=nullptr;
    o_CommandListRelease=o_Release=nullptr;resourceReleaseTarget=0;
    resourceReleaseViaLifetime=false;lifetimeReleaseViaResource=false;lifetimeInstallFailures=0;
    lifetimeExecuteTarget=0;lifetimeResetTarget=0;lifetimeReleaseTarget=0;
    State::Instance().currentFG=nullptr;
}
int main(){
    InitializeTables();
    {
        ResetInstallation();ID3D12Device device;XeFG_Dx12 fg;State::Instance().currentFG=&fg;
        HookToDevice(&device); // Actual caller: DLSSG input, HUD disabled, XeFG output.
        ID3D12CommandQueue queue;queue.vtable=queueTable.data();
        std::array<ID3D12GraphicsCommandList,51> lists;
        for(auto& list:lists){
            list.vtable=listTable.data();fg.TrackPendingCommandList(&list);
            ID3D12CommandList* batch[]{&list};queue.ExecuteCommandLists(1,batch);
        }
        assert(queue.executions==51);
#if !BASELINE_RECOVERY
        assert(fg._pendingCommandListCount==0 && "real submissions were invisible: R4 DLSSG install regression");
#else
        assert(fg._pendingCommandListCount==51);
        assert(!fg.QuiesceWork());
        assert(!fg._workGate.IsClosed() && "failed cleanup permanently blocked new FG data");
#endif
#if !R4_BASELINE
        assert(ResTrack_Dx12::LifetimeObserversReady(&lists[0],&queue));
        assert(fg._lifetimeQueueCount==1 && queue.refs==2);
        fg.TrackPendingCommandList(&lists[0]);resetResult=-1;lists[0].Reset();
        assert(fg._pendingCommandListCount==1);
        resetResult=S_OK;lists[0].Reset();assert(fg._pendingCommandListCount==0);
        fg.TrackPendingCommandList(&lists[1]);lists[1].AddRef();
        assert(lists[1].Release()==1 && fg._pendingCommandListCount==1);
        assert(lists[1].Release()==0 && fg._pendingCommandListCount==0);
        auto different=listTable;different[10]=reinterpret_cast<void*>(&dummy<10>);
        lists[2].vtable=different.data();assert(!ResTrack_Dx12::LifetimeObserversReady(&lists[2],&queue));
        // Soft resource gate closure must leave installed completion observers live.
        assert(fg.TryCloseCpuAdmission());
        assert(fg._workGate.IsClosed() && fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        ResTrack_Dx12::hudFix=true;
        for(unsigned i=3;i<6;++i) { lists[i].vtable=listTable.data();assert(fg.TrackPendingCommandList(&lists[i])); }
        _resCmdList[0][FG_ResourceType::Depth]=&lists[3];
        ID3D12CommandList* batch[]{&lists[3]};queue.ExecuteCommandLists(1,batch);
        lists[4].Reset();lists[5].Release();
        assert(fg._pendingCommandListCount==0 && fg.hudWrites==0);
        assert(_resCmdList[0].contains(FG_ResourceType::Depth));
        fg.RestoreCpuAdmission();
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed());
        ResTrack_Dx12::hudFix=false;
        // A stale final-Release generation cannot remove a reused identity.
        assert(fg.TrackPendingCommandList(&lists[6]));
        auto oldGeneration=fg.CapturePendingCommandListGeneration(&lists[6]);
        lists[6].Reset();assert(fg.TrackPendingCommandList(&lists[6]));
        fg.RetirePendingCommandList(&lists[6],oldGeneration);
        assert(fg._pendingCommandListCount==1);lists[6].Reset();assert(fg._pendingCommandListCount==0);
        // An actually delayed batch is recoverable: no 5-second retry or closed admission latch.
        for(auto& list:lists) { list.vtable=listTable.data();fg.TrackPendingCommandList(&list); }
        auto started=std::chrono::steady_clock::now();
        for(unsigned retry=0;retry<3;++retry) {
            assert(!fg.QuiesceWork());
            assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        }
        assert(std::chrono::steady_clock::now()-started < std::chrono::seconds(1));
        for(auto& list:lists) { ID3D12CommandList* delayed[]{&list};queue.ExecuteCommandLists(1,delayed); }
        assert(fg._pendingCommandListCount==0 && fg.QuiesceWork());
        assert(fg._workGate.IsClosed() && fg._providerPresentGate.IsClosed() && fg._submissionGate.IsClosed());
        fg.RestoreCpuAdmission();
        { auto busy=fg.AcquireWork(); assert(!fg.QuiesceWork()); assert(!fg._workGate.IsClosed()); }
        { auto observing=fg.AcquireSubmissionWork(); assert(!fg.QuiesceWork());
          assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed()); }
        assert(fg.QuiesceWork());fg.RestoreCpuAdmission();
        // The callback entered via its installed native target keeps admission
        // until both the real API and production AfterCommandSubmission return.
        assert(fg.TrackPendingCommandList(&lists[7]));
        std::latch entered{1}, mayReturn{1};nativeEntered=&entered;nativeMayReturn=&mayReturn;
        std::thread nativeCall([&]{ ID3D12CommandList* inFlight[]{&lists[7]};queue.ExecuteCommandLists(1,inFlight); });
        entered.wait();
        assert(fg._pendingCommandListCount==1 && !fg.QuiesceWork());
        assert(!fg._workGate.IsClosed() && !fg._providerPresentGate.IsClosed() && !fg._submissionGate.IsClosed());
        mayReturn.count_down();nativeCall.join();nativeEntered=nativeMayReturn=nullptr;
        assert(fg._pendingCommandListCount==0 && fg.QuiesceWork());fg.RestoreCpuAdmission();
#endif
    }
#if !R4_BASELINE
    for(bool resourceFirst:{false,true}){
        ResetInstallation();ID3D12Device device;
        if(resourceFirst) ResTrack_Dx12::HookResource(&device);
        assert(ResTrack_Dx12::HookLifetimeObservers(&device));
        if(!resourceFirst) ResTrack_Dx12::HookResource(&device);
        assert(installed.size()==3 && "common native Release must have one detour");
        XeFG_Dx12 fg;State::Instance().currentFG=&fg;
        ID3D12GraphicsCommandList list;list.vtable=listTable.data();
        fg.TrackPendingCommandList(&list);
        assert(list.Release()==0 && fg._pendingCommandListCount==0);
    }
    {
        ResetInstallation();ID3D12Device device;XeFG_Dx12 fg;
        assert(ResTrack_Dx12::HookLifetimeObservers(&device));State::Instance().currentFG=&fg;
        ResTrack_Dx12::ReleaseDeviceHooks();assert(installed.size()==3);
        assert(ResTrack_Dx12::LifetimeObserversReady(&device.list,&device.queue));
        State::Instance().currentFG=nullptr;ResTrack_Dx12::ReleaseDeviceHooks();
        assert(installed.empty() && !ResTrack_Dx12::LifetimeObserversReady(&device.list,&device.queue));
    }
    for(int failure=1;failure<=6;++failure){
        ResetInstallation();ID3D12Device device;failAt=failure;
        for(unsigned attempt=0;attempt<5;++attempt) assert(!ResTrack_Dx12::HookLifetimeObservers(&device));
        assert(lifetimeInstallFailures==3 && installed.empty());
        assert(!ResTrack_Dx12::LifetimeObserversReady(&device.list,&device.queue));
        XeFG_Dx12 fg;assert(!fg.TrackPendingCommandList(&device.list));
        assert(fg._pendingCommandListCount==0);
    }
#endif
    std::cout<<"Actual DLSSG/HUD-off installation, 51 routed submissions, Reset/Release and transactional failure passed\n";
}
