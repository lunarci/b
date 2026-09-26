"""Fault-inject the actual production allocation and teardown functions.

No D3D device is required. The source bodies are compiled against a small COM
fake so allocation failure, reference ownership and teardown order are tested.
Run: python tests/test_xefg_owned_resource_lifetime.py [source-root]
"""
from pathlib import Path
import os
import subprocess
import shutil
import sys
import tempfile

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]

def body(path, signature):
    text = (root / path).read_text()
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 0
    for end in range(opening, len(text)):
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
            if depth == 0:
                return text[start:end + 1]
    raise AssertionError(signature)

allocation = body('OptiScaler/framegen/IFGFeature_Dx12.cpp', 'bool IFGFeature_Dx12::CreateBufferResource(')
allocation_sized = body('OptiScaler/framegen/IFGFeature_Dx12.cpp', 'bool IFGFeature_Dx12::CreateBufferResourceWithSize(')
shutdown = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'bool XeFG_Dx12::Shutdown()')
destroy_fg = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::DestroyFGContext()')
create_fg = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::CreateContext(')
constructor = body('OptiScaler/framegen/xefg/XeFG_Dx12.h', 'XeFG_Dx12() : IFGFeature_Dx12(), IFGFeature()')
# Only the class name is adapted; execute the complete production initializer/body.
constructor = constructor.replace('XeFG_Dx12()', 'XeFGCtorProbe()', 1)
recovery_bodies = '\n'.join(body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', sig) for sig in (
    'bool XeFG_Dx12::TryCloseCpuAdmission()', 'void XeFG_Dx12::RestoreCpuAdmission()',
    'bool XeFG_Dx12::QuiesceWork()', 'bool XeFG_Dx12::CommandObjectsReady() const',
    'void XeFG_Dx12::CreateObjects(', 'bool XeFG_Dx12::DeactivateImpl(',
    'void XeFG_Dx12::RestoreProviderState('))

harness = r'''
#include "framegen/FGWorkGate.h"
#include "misc/XeFGProgressDiagnostics.h"
#include "misc/XeFGWorkDiagnostics.h"
#include "misc/XeFGPresentDiagnostics.h"
#include "framegen/xefg/XeFGRecovery.h"
#include "misc/LongSessionTiming.h"
#include <shared_mutex>
#include <unordered_map>
#include <cassert>
#include <format>
#include <cstdint>
#include <vector>
#include <string>
#include <iostream>
#include <mutex>
using UINT=unsigned; using UINT64=uint64_t; using HRESULT=int;
constexpr int DXGI_FORMAT_UNKNOWN=0;
constexpr HRESULT S_OK=0; constexpr size_t BUFFER_COUNT=4;
constexpr int D3D12_COMMAND_LIST_TYPE_DIRECT=0,D3D12_FENCE_FLAG_NONE=0,FALSE=0;
struct CommandObject { unsigned releases=0; void Release(){++releases;} void SetName(const wchar_t*){} HRESULT Close(){return 0;} };
using ID3D12CommandAllocator=CommandObject; using ID3D12GraphicsCommandList=CommandObject; using IUnknown=void;
bool CheckForRealObject(const char*,CommandObject*,IUnknown**) {return false;}
static int eventCalls=0,eventFailAt=0;
void* CreateEvent(void*,int,int,void*) { ++eventCalls; return eventCalls==eventFailAt ? nullptr : reinterpret_cast<void*>(1); }
#define FAILED(x) ((x)<0)
#define LOG_ERROR(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define IID_PPV_ARGS(x) x
#define SAFE_RELEASE(x) do { if ((x)!=nullptr) { (x)->Release(); (x)=nullptr; } } while (0)
using D3D12_RESOURCE_STATES=int;
using D3D12_HEAP_FLAGS=int;
constexpr int D3D12_HEAP_FLAG_NONE=0, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS=4, DXGI_FORMAT_R32_FLOAT=40;
struct D3D12_HEAP_PROPERTIES { int marker=0; };
struct Desc { UINT64 Width=10; UINT Height=10; int Format=1; int Flags=0; };
struct ID3D12Resource {
    Desc desc; int releases=0; HRESULT heapResult=0;
    Desc GetDesc() const { return desc; }
    HRESULT GetHeapProperties(D3D12_HEAP_PROPERTIES* p,D3D12_HEAP_FLAGS* f) { p->marker=7; *f=0; return heapResult; }
    void Release() { ++releases; }
};
struct ID3D12Device {
    int calls=0; HRESULT allocResult=0; ID3D12Resource fresh;
    int commandCalls=0, failCommandAt=0; CommandObject commandObjects[64];
    HRESULT allocate(CommandObject** out) { ++commandCalls; if(commandCalls==failCommandAt) return -1;
        *out=&commandObjects[commandCalls]; return 0; }
    HRESULT CreateCommandAllocator(int,CommandObject** out){return allocate(out);}
    HRESULT CreateCommandList(int,int,CommandObject*,void*,CommandObject** out){return allocate(out);}
    HRESULT CreateFence(int,int,CommandObject** out){return allocate(out);}
    HRESULT CreateCommittedResource(D3D12_HEAP_PROPERTIES* p,int,Desc* d,int,void*,ID3D12Resource** out) {
        ++calls; assert(p->marker==7);
        if (allocResult<0) { *out=nullptr; return allocResult; }
        fresh.desc=*d; *out=&fresh; return 0;
    }
};
struct IFGFeature_Dx12 {
    bool _useIsolatedAllocatorFences=false;
    bool CreateBufferResource(ID3D12Device*,ID3D12Resource*,int,ID3D12Resource**,bool=false,bool=false);
    bool CreateBufferResourceWithSize(ID3D12Device*,ID3D12Resource*,int,ID3D12Resource**,UINT,UINT,bool=false,bool=false);
};
struct State { bool isShuttingDown=false, fgChanged=false; static State& Instance() { static State s; return s; } };
struct IFGFeature {};
struct FG_Constants {};
using xefg_swapchain_result_t=int; constexpr int XEFG_SWAPCHAIN_RESULT_SUCCESS=0;
namespace XeFGPacing { void RequestReset(){} }
struct XeFGProxy { static void* Module(){return reinterpret_cast<void*>(1);} static bool InitXeFG(){return true;}
    static int Enabled(void*,bool); static auto SetEnabled(){return &Enabled;} };
struct XeFGCtorProbe : IFGFeature_Dx12, IFGFeature {
    FGWorkGate _workGate, _providerPresentGate, _submissionGate;
    // ACTUAL_CONSTRUCTOR
};
static std::vector<char> order;
namespace MenuOverlayDx { void CleanupRenderTarget(bool,void*) { order.push_back('M'); } }
namespace ResTrack_Dx12 { static bool observersReady=true;
    bool HookLifetimeObservers(ID3D12Device*,void*) { return observersReady; } }
struct XeFG_Dx12 {
    int drainCalls=0, failDrainAt=0; bool destroyOk=true, disableOk=true, discardOk=true;
    int disableResult=-1; unsigned recoveryFaults=0; UINT64 _frameCount=57,lastFaultFrame=0;
    int32_t lastFaultResult=0; std::string lastFaultStage;
    void NoteRecoveryFault(UINT64 frame,const char* stage,int32_t result) {
        assert(result<0); ++recoveryFaults;lastFaultFrame=frame;lastFaultStage=stage;lastFaultResult=result;
    }
    std::mutex _lifecycleMutex, _pendingCommandMutex;
    FGWorkGate _workGate, _providerPresentGate, _submissionGate;
    bool _workWasClosed=false,_presentWasClosed=false,_submissionWasClosed=false,_submissionClosedByLifecycle=false;
    bool _lifecycleFailed=false, _objectsDrained=false, _aliasResetPending=false;
    bool _pendingTrackingComplete=true; size_t _pendingCommandListCount=0;
    XeFGDiagnostics::WorkDiagnostics _workDiagnostics;
    XeFGRecovery _recovery;
    int _hudlessObservedFormat[BUFFER_COUNT]{},_hudlessAcceptedFormat[BUFFER_COUNT]{};
    void* _fgContext=reinterpret_cast<void*>(1);
    void* _swapChainContext=this;
    ID3D12Device* _device=nullptr; void* _gameCommandQueue=nullptr;
    int _lastDispatchedFrame=42; bool _isActive=true, _waitingNewFrameData=true;
    CommandObject* _uiCommandAllocator[BUFFER_COUNT]{}; CommandObject* _uiCommandList[BUFFER_COUNT]{};
    CommandObject* _scCommandAllocator[BUFFER_COUNT]{}; CommandObject* _scCommandList[BUFFER_COUNT]{};
    CommandObject* _uiFence=nullptr; CommandObject* _scFence=nullptr;
    void* _uiFenceEvent=nullptr; void* _scFenceEvent=nullptr;
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<int,int> _frameResources[BUFFER_COUNT],_resourceReady[BUFFER_COUNT];
    bool _noUi[BUFFER_COUNT]{},_noHudless[BUFFER_COUNT]{},_noDistortionField[BUFFER_COUNT]{};
    bool TryCloseCpuAdmission(); void RestoreCpuAdmission(); bool QuiesceWork();
    void PublishPendingLocked() {}
    bool _uiCommandListResetted[BUFFER_COUNT]{};
    int GetIndex(){return 0;} bool SubmitUICommandList(int){order.push_back('S');return true;}
    bool DeactivateImpl(bool,XeFGProgress::DeactivateReason=XeFGProgress::DeactivateReason::External); void RestoreProviderState(bool);
    bool DiscardPendingCommandRecordings(){order.push_back('C');return discardOk;}
    void CreateObjects(ID3D12Device*); bool CommandObjectsReady() const;
    void RequestHistoryReset(){order.push_back('H');}
    void UpdateTarget(){order.push_back('U');}
    bool DrainLifetimeQueues(){order.push_back('Q');return ++drainCalls!=failDrainAt;}
    bool DestroySwapchainContext(){order.push_back('X');if(destroyOk)_swapChainContext=nullptr;return destroyOk;}
    void ReleaseObjects(){order.push_back('R');assert(_objectsDrained);}
    void DestroyFGContext(); void CreateContext(ID3D12Device*,FG_Constants&); bool Shutdown();
};
int XeFGProxy::Enabled(void* context,bool enable) {
    auto self=static_cast<XeFG_Dx12*>(context); order.push_back(enable?'V':'D');
    return enable || self->disableOk ? 0 : self->disableResult;
}'''

tests = r'''
int main() {
    {
        XeFGCtorProbe startup;
        assert(startup._workGate.IsClosed() && !startup._submissionGate.IsClosed());
        assert(!startup._workGate.TryEnter() && startup._submissionGate.TryEnter());
    }
    // Execute the actual disable path: warnings preserve state without a
    // recovery fault; every negative result must propagate its exact frame,
    // stage and result to recovery before the failed lifecycle returns.
    for(int result : {0,2,-1,-4,-17}) {
        XeFG_Dx12 x; x.disableOk=result==0; x.disableResult=result;
        order.clear(); assert(x.DeactivateImpl(false)==(result==0));
        assert(x._isActive==(result!=0));
        assert(x._waitingNewFrameData==(result!=0));
        assert(x.recoveryFaults==(result<0?1u:0u));
        if(result<0) assert(x.lastFaultFrame==x._frameCount && x.lastFaultStage=="disable" && x.lastFaultResult==result);
        assert((order==std::vector<char>{'H','D'}));
    }
    IFGFeature_Dx12 f;
    {
        ID3D12Resource src, old; ID3D12Device d; ID3D12Resource* slot=&old;
        assert(f.CreateBufferResource(&d,&src,0,&slot));
        assert(slot==&old && old.releases==0 && d.calls==0);
    }
    for(bool sized: {false,true}) {
        ID3D12Resource src, old; old.desc.Width=5; ID3D12Device d; d.allocResult=-1;
        ID3D12Resource* slot=&old;
        bool ok=sized ? f.CreateBufferResourceWithSize(&d,&src,0,&slot,10,10) : f.CreateBufferResource(&d,&src,0,&slot);
        assert(!ok && slot==&old && old.releases==0 && d.calls==1);
        d.allocResult=0;
        ok=sized ? f.CreateBufferResourceWithSize(&d,&src,0,&slot,10,10) : f.CreateBufferResource(&d,&src,0,&slot);
        assert(ok && slot==&d.fresh && old.releases==1);
        int calls=d.calls;
        ok=sized ? f.CreateBufferResourceWithSize(&d,&src,0,&slot,10,10) : f.CreateBufferResource(&d,&src,0,&slot);
        assert(ok && d.calls==calls && d.fresh.releases==0);
    }
    for(bool sized: {false,true}) {
        ID3D12Resource src, old; src.heapResult=-2; old.desc.Width=5;
        ID3D12Device d; ID3D12Resource* slot=&old;
        bool ok=sized ? f.CreateBufferResourceWithSize(&d,&src,0,&slot,10,10) : f.CreateBufferResource(&d,&src,0,&slot);
        assert(!ok && slot==&old && old.releases==0 && d.calls==0);
    }
    {
        ID3D12Resource src; ID3D12Device d; ID3D12Resource* slot=nullptr;
        d.allocResult=-1; assert(!f.CreateBufferResource(&d,&src,0,&slot) && slot==nullptr);
        d.allocResult=0; assert(f.CreateBufferResource(&d,&src,0,&slot) && slot==&d.fresh);
        assert(!f.CreateBufferResource(&d,&src,0,nullptr));
        assert(!f.CreateBufferResourceWithSize(&d,&src,0,nullptr,10,10));
    }
    {
        XeFG_Dx12 x; order.clear(); assert(x.Shutdown());
        assert((order==std::vector<char>{'H','D','C','Q','M','X','Q','R'}));
        assert(x._fgContext==nullptr);
        assert(x._workGate.IsClosed() && x._providerPresentGate.IsClosed() && x._submissionGate.IsClosed());
    }
    for(int busyGate: {0,1,2}) {
        XeFG_Dx12 x; auto hold=(busyGate==0?x._workGate:busyGate==1?x._providerPresentGate:x._submissionGate).TryEnter();
        order.clear(); assert(!x.Shutdown());
        assert(!x._lifecycleFailed && !x._objectsDrained && order.empty());
        assert(x._fgContext!=nullptr && x.drainCalls==0 && x._isActive);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
    }
    for(int failAt: {1,2}) {
        XeFG_Dx12 x; x.failDrainAt=failAt; order.clear(); assert(!x.Shutdown());
        assert(x._lifecycleFailed==(failAt==2) && !x._objectsDrained);
        for(char c:order) assert(c!='R');
        if(failAt==1) { for(char c:order) assert(c!='X'); assert(x._isActive);
            assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed()); }
        else { assert(x._fgContext==nullptr && x._swapChainContext==nullptr);
            assert(x._workGate.IsClosed() && x._providerPresentGate.IsClosed() && x._submissionGate.IsClosed()); }
    }
    for(int failure: {0,1,2}) {
        XeFG_Dx12 x; x.disableOk=failure!=0; x.discardOk=failure!=1; x.destroyOk=failure!=2;
        order.clear(); assert(!x.Shutdown());
        assert(x._fgContext!=nullptr && x._swapChainContext!=nullptr && !x._objectsDrained);
        assert(x._isActive && !x._lifecycleFailed);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        for(char c:order) assert(c!='R');
        assert(x.recoveryFaults==(failure==0?1u:0u));
        if(failure==0) assert(x.lastFaultFrame==57 && x.lastFaultStage=="disable" && x.lastFaultResult==-1);
        x.disableOk=x.discardOk=x.destroyOk=true; assert(x.Shutdown());
        assert(x.recoveryFaults==(failure==0?1u:0u));
    }
    {
        XeFG_Dx12 x; State::Instance().isShuttingDown=true; order.clear();
        assert(!x.Shutdown() && order.empty()); State::Instance().isShuttingDown=false;
    }
    {
        // The R4 log showed 51 pending game recordings. A logical reset must
        // preserve them and helper objects without waiting for game submission.
        XeFG_Dx12 x; ID3D12Device device; FG_Constants constants;
        x.CreateObjects(&device); auto saved=x._uiCommandAllocator[0];
        auto calls=device.commandCalls; x._pendingCommandListCount=51;
        for(size_t i=0;i<BUFFER_COUNT;++i){x._frameResources[i][1]=1;x._resourceReady[i][1]=1;}
        order.clear(); auto begin=std::chrono::steady_clock::now(); x.DestroyFGContext();
        assert(std::chrono::steady_clock::now()-begin<std::chrono::milliseconds(250));
        assert((order==std::vector<char>{'H','D','C','H','U'}));
        assert(x._pendingCommandListCount==51 && !x._lifecycleFailed && !x._aliasResetPending);
        assert(x._fgContext==nullptr && x._swapChainContext!=nullptr && x.drainCalls==0);
        assert(x._uiCommandAllocator[0]==saved && saved->releases==0);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        for(size_t i=0;i<BUFFER_COUNT;++i) assert(x._frameResources[i].empty() && x._resourceReady[i].empty() && x._noUi[i] && x._noHudless[i]);
        x.CreateContext(&device,constants);
        assert(x._fgContext==x._swapChainContext && x._lastDispatchedFrame==0 && x._pendingCommandListCount==51);
        assert(device.commandCalls==calls && saved->releases==0);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        // Destructive shutdown instead defers immediately and restores admission.
        assert(!x.Shutdown() && x._pendingCommandListCount==51 && x.drainCalls==0);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        x._pendingCommandListCount=0; assert(x.Shutdown());
    }
    for(int busyGate: {0,1}) {
        XeFG_Dx12 x; auto hold=(busyGate==0?x._workGate:x._providerPresentGate).TryEnter();
        order.clear(); x.DestroyFGContext();
        assert(order.empty() && x._fgContext!=nullptr && x._isActive && x._aliasResetPending);
        assert(!x._lifecycleFailed && !x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
    }
    for(bool disableFails: {false,true}) {
        XeFG_Dx12 x; x.disableOk=!disableFails; x.discardOk=disableFails;
        order.clear(); x.DestroyFGContext();
        assert(x._fgContext!=nullptr && x._isActive && x._aliasResetPending && !x._lifecycleFailed);
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        for(char c:order) assert(c!='U' && c!='R');
        assert(x.recoveryFaults==(disableFails?1u:0u));
        if(disableFails) assert(x.lastFaultFrame==57 && x.lastFaultStage=="disable" && x.lastFaultResult==-1);
    }
    for(int failAt=1;failAt<=20;++failAt) {
        // Exercise every allocator/list/fence/event allocation, including slot0
        // allocator present + list absent and a late slot partially created.
        XeFG_Dx12 x; ID3D12Device device; FG_Constants constants; x._fgContext=nullptr;
        assert(x._workGate.TryCloseWhenIdle()); eventCalls=0;eventFailAt=failAt>18?failAt-18:0;
        device.failCommandAt=failAt<=18?failAt:0;
        x.CreateContext(&device,constants);
        assert(x._fgContext==nullptr && !x.CommandObjectsReady());
        assert(x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        auto saved=x._uiCommandAllocator[0]; device.failCommandAt=0;eventFailAt=0;
        x.CreateContext(&device,constants);
        assert(x._fgContext==x._swapChainContext && x.CommandObjectsReady());
        assert(!x._workGate.IsClosed() && !x._providerPresentGate.IsClosed() && !x._submissionGate.IsClosed());
        if(saved) assert(x._uiCommandAllocator[0]==saved && saved->releases==0);
    }
    {
        XeFG_Dx12 x; ID3D12Device device; FG_Constants constants; x._fgContext=nullptr;
        x._workGate.TryCloseWhenIdle(); ResTrack_Dx12::observersReady=false;
        x.CreateContext(&device,constants); assert(x._fgContext==nullptr && device.commandCalls==0);
        assert(x._workGate.IsClosed() && !x._submissionGate.IsClosed()); ResTrack_Dx12::observersReady=true;
    }
    std::cout << "XeFG allocation and teardown fault injection passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix='xefg_lifetime_') as temp:
    temp=Path(temp)
    cpp=temp/'test.cpp'; exe=temp/('test.exe' if os.name=='nt' else 'test')
    cpp.write_text(harness.replace('// ACTUAL_CONSTRUCTOR',constructor)+'\n'+allocation+'\n'+allocation_sized+
                   '\n'+recovery_bodies+'\n'+shutdown+'\n'+destroy_fg+'\n'+create_fg+'\n'+tests)
    compiler=os.environ.get('CXX') or ('cl' if os.name=='nt' and shutil.which('cl') else 'g++')
    if Path(compiler).name.lower() in ('cl','cl.exe'):
        command=[compiler,'/nologo','/std:c++20','/EHsc','/Od','/UNDEBUG','/I'+str(root/'OptiScaler'),str(cpp),'/Fe:'+str(exe)]
    else:
        command=[compiler,'-std=c++20','-O0','-UNDEBUG','-pthread','-I',str(root/'OptiScaler'),str(cpp),'-o',str(exe)]
    subprocess.run(command,check=True,cwd=temp)
    subprocess.run([str(exe)],check=True)

release_commands = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::ReleaseCommandObjects()')
release_objects = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::ReleaseObjects()')
cleanup_harness = r'''
#include "misc/XeFGWorkDiagnostics.h"
#include "misc/XeFGResourceDiagnostics.h"
#include <cassert>
#include <cstdint>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <iostream>
using UINT64=uint64_t; constexpr size_t BUFFER_COUNT=4;
struct Object { int releases=0; void Release(){ ++releases; } };
#define SAFE_RELEASE(x) do { if ((x)!=nullptr) { (x)->Release(); (x)=nullptr; } } while (0)
static int closes=0;
void CloseHandle(void*){ ++closes; }
struct BorrowedResource { Object* resource=nullptr; Object* copy=nullptr; };
struct XeFG_Dx12 {
    XeFGDiagnostics::Context _resourceDiagnostics;
    struct CopyAllocationInfo { uint64_t bytes=0; bool known=false; };
    std::unordered_map<int,CopyAllocationInfo> _copyAllocationInfo[BUFFER_COUNT];
    bool _objectsDrained=false, _lifecycleFailed=true;
    void* _swapChainContext=nullptr;
    Object* _uiCommandAllocator[BUFFER_COUNT]{}; Object* _uiCommandList[BUFFER_COUNT]{};
    Object* _scCommandAllocator[BUFFER_COUNT]{}; Object* _scCommandList[BUFFER_COUNT]{};
    bool _scCommandListResetted[BUFFER_COUNT]{}; bool _uiCommandListResetted[BUFFER_COUNT]{};
    Object* _uiSlotFences[BUFFER_COUNT]{}; Object* _scSlotFences[BUFFER_COUNT]{};
    bool _uiSubmissionFailed[BUFFER_COUNT]{},_scSubmissionFailed[BUFFER_COUNT]{};
    UINT64 _scAllocatorFenceValues[BUFFER_COUNT]{}; UINT64 _uiAllocatorFenceValues[BUFFER_COUNT]{};
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<int,BorrowedResource> _frameResources[BUFFER_COUNT];
    std::unordered_map<int,Object*> _resourceCopy[BUFFER_COUNT];
    Object* _uiFence=nullptr; Object* _scFence=nullptr;
    void* _uiFenceEvent=nullptr; void* _scFenceEvent=nullptr; UINT64 _uiFenceValue=3;
    struct Entry { Object* fence=nullptr; void* event=nullptr; Object* queue=nullptr; Object* progressFence=nullptr; };
    Entry _lifetimeQueues[8]{}; size_t _lifetimeQueueCount=0; std::mutex _lifetimeQueueMutex;
    std::mutex _gpuProgressMutex; uint64_t _nextGpuProgressPollMs=999;
    unsigned progressPublications=0;
    void PublishGpuProgressLocked(uint64_t) { assert(_lifetimeQueueCount==0); ++progressPublications; }
    Object* _gameCommandQueue=nullptr;
    std::unique_ptr<int> _renderUI,_hudlessCompare,_mvFlip,_depthFlip,_depthInvert;
    void ReleaseCommandObjects(); void ReleaseObjects();
};
'''
cleanup_tests = r'''
int main(){
    XeFG_Dx12 x; Object own,borrowed,uiFence,scFence,queueFence,queue,command,progressFence;
    x._resourceCopy[0][0]=&own;
    x._resourceDiagnostics.BeginContext();
    x._resourceDiagnostics.OnAllocate(65536);
    x._copyAllocationInfo[0][0]={65536,true};
    x._frameResources[0][0]={&borrowed,&own};
    x._uiFence=&uiFence; x._scFence=&scFence;
    x._uiFenceEvent=reinterpret_cast<void*>(1); x._scFenceEvent=reinterpret_cast<void*>(2);
    x._lifetimeQueues[0]={&queueFence,reinterpret_cast<void*>(3),&queue}; x._lifetimeQueueCount=1;
    x._lifetimeQueues[0].progressFence=&progressFence;
    Object uiSlotFence,scSlotFence; x._uiSlotFences[0]=&uiSlotFence;x._scSlotFences[3]=&scSlotFence;
    x._uiSubmissionFailed[0]=x._scSubmissionFailed[3]=true;
    x._uiCommandList[0]=&command; x._gameCommandQueue=&queue;
    x.ReleaseObjects(); assert(own.releases==0 && command.releases==0 && closes==0);
    x._objectsDrained=true; x._swapChainContext=reinterpret_cast<void*>(1);
    x.ReleaseObjects(); assert(own.releases==0 && command.releases==0 && closes==0);
    x._swapChainContext=nullptr; x.ReleaseObjects();
    assert(own.releases==1 && borrowed.releases==0 && command.releases==1);
    assert(uiSlotFence.releases==1 && scSlotFence.releases==1 && !x._uiSubmissionFailed[0] && !x._scSubmissionFailed[3]);
    assert(uiFence.releases==1 && scFence.releases==1 && queueFence.releases==1 && queue.releases==1);
    assert(progressFence.releases==1 && x._nextGpuProgressPollMs==0 && x.progressPublications==1);
    assert(x._frameResources[0].empty() && x._resourceCopy[0].empty() && closes==3);
    assert(!x._lifecycleFailed && x._gameCommandQueue==nullptr);
    assert(x._copyAllocationInfo[0].empty());
    auto counters=x._resourceDiagnostics.Read().counters;
    assert(counters.liveCopies==0 && counters.liveBytes==0 && counters.releases==1);
    assert(counters.releasedBytes==65536 && counters.accountingErrors==0);
    x.ReleaseObjects(); assert(own.releases==1 && borrowed.releases==0 && closes==3);
    assert(progressFence.releases==1);
    assert(x._resourceDiagnostics.Read().counters.releases==1);
    std::cout << "XeFG cleanup ownership/quiescence gates passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix='xefg_cleanup_') as temp:
    temp=Path(temp); cpp=temp/'cleanup.cpp'; exe=temp/('cleanup.exe' if os.name=='nt' else 'cleanup')
    cpp.write_text(cleanup_harness+'\n'+release_commands+'\n'+release_objects+'\n'+cleanup_tests)
    compiler=os.environ.get('CXX') or ('cl' if os.name=='nt' and shutil.which('cl') else 'g++')
    if Path(compiler).name.lower() in ('cl','cl.exe'):
        command=[compiler,'/nologo','/std:c++20','/EHsc','/Od','/UNDEBUG','/I'+str(root/'OptiScaler'),str(cpp),'/Fe:'+str(exe)]
    else:
        command=[compiler,'-std=c++20','-O0','-UNDEBUG','-I',str(root/'OptiScaler'),str(cpp),'-o',str(exe)]
    subprocess.run(command,check=True,cwd=temp)
    subprocess.run([str(exe)],check=True)
