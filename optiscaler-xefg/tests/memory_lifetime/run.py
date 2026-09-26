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

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]

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

harness = r'''
#include "framegen/FGWorkGate.h"
#include <cassert>
#include <cstdint>
#include <vector>
#include <string>
#include <iostream>
#include <mutex>
using UINT=unsigned; using UINT64=uint64_t; using HRESULT=int;
constexpr HRESULT S_OK=0;
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
    HRESULT CreateCommittedResource(D3D12_HEAP_PROPERTIES* p,int,Desc* d,int,void*,ID3D12Resource** out) {
        ++calls; assert(p->marker==7);
        if (allocResult<0) { *out=nullptr; return allocResult; }
        fresh.desc=*d; *out=&fresh; return 0;
    }
};
struct IFGFeature_Dx12 {
    bool CreateBufferResource(ID3D12Device*,ID3D12Resource*,int,ID3D12Resource**,bool=false,bool=false);
    bool CreateBufferResourceWithSize(ID3D12Device*,ID3D12Resource*,int,ID3D12Resource**,UINT,UINT,bool=false,bool=false);
};
struct State { bool isShuttingDown=false, fgChanged=false; static State& Instance() { static State s; return s; } };
struct IFGFeature {};
struct FG_Constants {};
struct XeFGProxy { static void* Module(){ return reinterpret_cast<void*>(1); } static bool InitXeFG(){ return true; } };
struct XeFGCtorProbe : IFGFeature_Dx12, IFGFeature {
    FGWorkGate _workGate, _submissionGate;
    // ACTUAL_CONSTRUCTOR
};
static std::vector<char> order;
namespace MenuOverlayDx { void CleanupRenderTarget(bool,void*) { order.push_back('M'); } }
struct XeFG_Dx12 {
    int drainCalls=0, failDrainAt=0; bool destroyOk=true, quiesceOk=true;
    std::mutex _lifecycleMutex;
    FGWorkGate _workGate, _submissionGate;
    bool _lifecycleFailed=false, _objectsDrained=false;
    void* _fgContext=reinterpret_cast<void*>(1);
    void* _swapChainContext=reinterpret_cast<void*>(1);
    ID3D12Device* _device=nullptr;
    int _lastDispatchedFrame=42; bool _isActive=false;
    bool QuiesceWork(){
        order.push_back('A');
        _workGate.CloseAndWait(std::chrono::milliseconds(0));
        _submissionGate.CloseAndWait(std::chrono::milliseconds(0));
        return quiesceOk;
    }
    void DeactivateImpl(){ order.push_back('D'); }
    void Deactivate(){ order.push_back('D'); }
    void CreateObjects(ID3D12Device*){ order.push_back('O'); }
    void UpdateTarget(){ order.push_back('U'); }
    bool DrainLifetimeQueues(){ order.push_back('Q'); return ++drainCalls!=failDrainAt; }
    bool DestroySwapchainContext(){ order.push_back('X'); return destroyOk; }
    void ReleaseObjects(){ order.push_back('R'); assert(_objectsDrained); }
    void ReleaseCommandObjects(){ order.push_back('C'); }
    void DestroyFGContext();
    void CreateContext(ID3D12Device*,FG_Constants&);
    bool Shutdown();
};
'''

tests = r'''
int main() {
    {
        XeFGCtorProbe startup;
        assert(startup._workGate.IsClosed() && !startup._submissionGate.IsClosed());
        assert(!startup._workGate.TryEnter() && startup._submissionGate.TryEnter());
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
        assert((order==std::vector<char>{'A','D','Q','M','X','Q','R'}));
        assert(x._fgContext==nullptr);
        assert(x._workGate.IsClosed() && x._submissionGate.IsClosed());
    }
    {
        XeFG_Dx12 x; x.quiesceOk=false; order.clear(); assert(!x.Shutdown());
        assert(x._lifecycleFailed && !x._objectsDrained);
        assert((order==std::vector<char>{'A'}));
        assert(x._fgContext!=nullptr && x.drainCalls==0);
    }
    for(int failAt: {1,2}) {
        XeFG_Dx12 x; x.failDrainAt=failAt; order.clear(); assert(!x.Shutdown());
        assert(x._lifecycleFailed && !x._objectsDrained);
        for(char c: order) assert(c!='R');
        if(failAt==1) for(char c: order) assert(c!='X');
    }
    {
        XeFG_Dx12 x; x.destroyOk=false; order.clear(); assert(!x.Shutdown());
        assert(x._fgContext!=nullptr && !x._objectsDrained && x.drainCalls==1);
        for(char c: order) assert(c!='R');
    }
    {
        XeFG_Dx12 x; State::Instance().isShuttingDown=true; order.clear();
        assert(!x.Shutdown() && order.empty());
        State::Instance().isShuttingDown=false;
    }
    {
        XeFG_Dx12 x; order.clear(); x.DestroyFGContext();
        assert((order==std::vector<char>{'A','D','Q','C'}));
        assert(x._fgContext==nullptr && x._workGate.IsClosed());
        assert(!x._submissionGate.IsClosed() && x._submissionGate.TryEnter());
        ID3D12Device device; FG_Constants constants; order.clear();
        x.CreateContext(&device,constants);
        assert((order==std::vector<char>{'A','O'}));
        assert(x._fgContext==x._swapChainContext && x._device==&device && x._lastDispatchedFrame==0);
        assert(!x._workGate.IsClosed() && !x._submissionGate.IsClosed());
    }
    for(bool failAdmission: {false,true}) {
        XeFG_Dx12 x; x.quiesceOk=!failAdmission; x.failDrainAt=1;
        order.clear(); x.DestroyFGContext();
        assert(x._lifecycleFailed && x._fgContext!=nullptr);
        assert(x._workGate.IsClosed() && x._submissionGate.IsClosed());
        for(char c: order) assert(c!='C' && c!='R');
    }
    std::cout << "XeFG allocation and teardown fault injection passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix='xefg_lifetime_') as temp:
    temp=Path(temp)
    cpp=temp/'test.cpp'; exe=temp/('test.exe' if os.name=='nt' else 'test')
    cpp.write_text(harness.replace('// ACTUAL_CONSTRUCTOR',constructor)+'\n'+allocation+'\n'+allocation_sized+
                   '\n'+shutdown+'\n'+destroy_fg+'\n'+create_fg+'\n'+tests)
    compiler=os.environ.get('CXX') or ('cl' if os.name=='nt' and shutil.which('cl') else 'g++')
    if Path(compiler).name.lower() in ('cl','cl.exe'):
        command=[compiler,'/nologo','/std:c++20','/EHsc','/Od','/I'+str(root/'OptiScaler'),str(cpp),'/Fe:'+str(exe)]
    else:
        command=[compiler,'-std=c++20','-O0','-pthread','-I',str(root/'OptiScaler'),str(cpp),'-o',str(exe)]
    subprocess.run(command,check=True,cwd=temp)
    subprocess.run([str(exe)],check=True)

release_commands = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::ReleaseCommandObjects()')
release_objects = body('OptiScaler/framegen/xefg/XeFG_Dx12.cpp', 'void XeFG_Dx12::ReleaseObjects()')
cleanup_harness = r'''
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
    UINT64 _scAllocatorFenceValues[BUFFER_COUNT]{}; UINT64 _uiAllocatorFenceValues[BUFFER_COUNT]{};
    std::shared_mutex _resourceMutex[BUFFER_COUNT];
    std::unordered_map<int,BorrowedResource> _frameResources[BUFFER_COUNT];
    std::unordered_map<int,Object*> _resourceCopy[BUFFER_COUNT];
    Object* _uiFence=nullptr; Object* _scFence=nullptr;
    void* _uiFenceEvent=nullptr; void* _scFenceEvent=nullptr; UINT64 _uiFenceValue=3;
    struct Entry { Object* fence=nullptr; void* event=nullptr; Object* queue=nullptr; };
    Entry _lifetimeQueues[8]{}; size_t _lifetimeQueueCount=0; std::mutex _lifetimeQueueMutex;
    Object* _gameCommandQueue=nullptr;
    std::unique_ptr<int> _renderUI,_hudlessCompare,_mvFlip,_depthFlip,_depthInvert;
    void ReleaseCommandObjects(); void ReleaseObjects();
};
'''
cleanup_tests = r'''
int main(){
    XeFG_Dx12 x; Object own,borrowed,uiFence,scFence,queueFence,queue,command;
    x._resourceCopy[0][0]=&own;
    x._resourceDiagnostics.BeginContext();
    x._resourceDiagnostics.OnAllocate(65536);
    x._copyAllocationInfo[0][0]={65536,true};
    x._frameResources[0][0]={&borrowed,&own};
    x._uiFence=&uiFence; x._scFence=&scFence;
    x._uiFenceEvent=reinterpret_cast<void*>(1); x._scFenceEvent=reinterpret_cast<void*>(2);
    x._lifetimeQueues[0]={&queueFence,reinterpret_cast<void*>(3),&queue}; x._lifetimeQueueCount=1;
    x._uiCommandList[0]=&command; x._gameCommandQueue=&queue;
    x.ReleaseObjects(); assert(own.releases==0 && command.releases==0 && closes==0);
    x._objectsDrained=true; x._swapChainContext=reinterpret_cast<void*>(1);
    x.ReleaseObjects(); assert(own.releases==0 && command.releases==0 && closes==0);
    x._swapChainContext=nullptr; x.ReleaseObjects();
    assert(own.releases==1 && borrowed.releases==0 && command.releases==1);
    assert(uiFence.releases==1 && scFence.releases==1 && queueFence.releases==1 && queue.releases==1);
    assert(x._frameResources[0].empty() && x._resourceCopy[0].empty() && closes==3);
    assert(!x._lifecycleFailed && x._gameCommandQueue==nullptr);
    assert(x._copyAllocationInfo[0].empty());
    auto counters=x._resourceDiagnostics.Read().counters;
    assert(counters.liveCopies==0 && counters.liveBytes==0 && counters.releases==1);
    assert(counters.releasedBytes==65536 && counters.accountingErrors==0);
    x.ReleaseObjects(); assert(own.releases==1 && borrowed.releases==0 && closes==3);
    assert(x._resourceDiagnostics.Read().counters.releases==1);
    std::cout << "XeFG cleanup ownership/quiescence gates passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix='xefg_cleanup_') as temp:
    temp=Path(temp); cpp=temp/'cleanup.cpp'; exe=temp/('cleanup.exe' if os.name=='nt' else 'cleanup')
    cpp.write_text(cleanup_harness+'\n'+release_commands+'\n'+release_objects+'\n'+cleanup_tests)
    compiler=os.environ.get('CXX') or ('cl' if os.name=='nt' and shutil.which('cl') else 'g++')
    if Path(compiler).name.lower() in ('cl','cl.exe'):
        command=[compiler,'/nologo','/std:c++20','/EHsc','/Od','/I'+str(root/'OptiScaler'),str(cpp),'/Fe:'+str(exe)]
    else:
        command=[compiler,'-std=c++20','-O0','-I',str(root/'OptiScaler'),str(cpp),'-o',str(exe)]
    subprocess.run(command,check=True,cwd=temp)
    subprocess.run([str(exe)],check=True)
