#!/usr/bin/env python3
"""R7 ResTrack regression: run actual callback bodies against admission fakes."""
import argparse
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("r7_tracking_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

EXECUTE_HARNESS = r'''
#include <cassert>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "framegen/FGWorkGate.h"
using UINT=unsigned;
struct ID3D12CommandQueue {}; // No AddRef/Release: this hook must retain nothing.
struct ID3D12CommandList {};
enum class FG_ResourceType { Depth,Velocity,UIColor,HudlessColor };
#define LOG_TRACK(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_WARN(...) ((void)0)
namespace XeFGDiagnostics {
enum class LifetimeObserver {CommandSubmission};
unsigned observerCalls=0;
void RecordObserverCallback(LifetimeObserver){++observerCalls;}
}
std::mutex _resourceCommandListMutex;
std::unordered_set<ID3D12CommandList*> _notFoundCmdLists;
std::unordered_map<FG_ResourceType,ID3D12CommandList*> _resCmdList[4];
std::vector<std::string> events;
bool hudFix=false,nativeReturned=false,expectAdmission=false;
unsigned nativeCalls=0;
struct FakeFG {
    FGWorkGate submissionGate,workGate;
    bool active=true,paused=false;
    unsigned before=0,after=0,observed=0,hudWrites=0;
    auto AcquireSubmissionWork(){return submissionGate.TryEnter();}
    auto AcquireWork(){return workGate.TryEnter();}
    bool IsActive(){return active;} bool IsPaused(){return paused;} unsigned GetIndex(){return 0;}
    uint64_t BeforeCommandSubmission(ID3D12CommandQueue*,UINT,ID3D12CommandList*const*) {
        assert(!submissionGate.TryCloseWhenIdle());++before;events.push_back("before");
        return 77;
    }
    void AfterCommandSubmission(UINT,ID3D12CommandList*const*,uint64_t generation) {
        assert(generation==77&&"same pre-native generation boundary reaches completion");
        assert(nativeReturned&&!submissionGate.TryCloseWhenIdle());++after;events.push_back("after");
    }
    void ObserveSubmittedQueue(ID3D12CommandQueue*) {
        assert(nativeReturned&&!submissionGate.TryCloseWhenIdle());
        assert(!events.empty()&&events.back()=="after");++observed;events.push_back("observe");
    }
    void SetResourceReady(FG_ResourceType){++hudWrites;}
    void SetCommandQueue(FG_ResourceType,ID3D12CommandQueue*){++hudWrites;}
};
struct State {FakeFG*currentFG=nullptr;static State&Instance(){static State s;return s;}};
void NativeExecute(ID3D12CommandQueue*,UINT,ID3D12CommandList*const*) {
    ++nativeCalls;events.push_back("native");assert(!nativeReturned);
    if(expectAdmission)assert(!State::Instance().currentFG->submissionGate.TryCloseWhenIdle());
    bool mutexFree=false;
    std::thread other([&]{mutexFree=_resourceCommandListMutex.try_lock();if(mutexFree)_resourceCommandListMutex.unlock();});
    other.join();assert(mutexFree&&"registry lock must not span native Execute");
    nativeReturned=true;
}
auto o_ExecuteCommandLists=NativeExecute;
struct ResTrack_Dx12 {
    static bool IsHudFixActive(){return hudFix;}
    static void hkExecuteCommandLists(ID3D12CommandQueue*,UINT,ID3D12CommandList*const*);
};
// ACTUAL_EXECUTE
void Run(FakeFG*fg,ID3D12CommandQueue*queue,UINT count,ID3D12CommandList*const*lists,bool admitted) {
    State::Instance().currentFG=fg;events.clear();nativeReturned=false;expectAdmission=admitted;
    const auto calls=nativeCalls;const auto before=fg?fg->before:0;const auto after=fg?fg->after:0;
    const auto observed=fg?fg->observed:0;
    ResTrack_Dx12::hkExecuteCommandLists(queue,count,lists);
    assert(nativeCalls==calls+1&&nativeReturned);
    const std::vector<std::string> wanted=admitted?std::vector<std::string>{"before","native","after","observe"}:std::vector<std::string>{"native"};
    assert(events==wanted);
    if(fg){assert(fg->before==before+admitted&&fg->after==after+admitted&&fg->observed==observed+admitted);
        assert(fg->submissionGate.TryCloseWhenIdle());assert(fg->submissionGate.Open());}
}
int main(){
    FakeFG fg;ID3D12CommandQueue queue;ID3D12CommandList list;ID3D12CommandList*lists[]={&list};
    Run(&fg,&queue,1,lists,true); // ordinary non-HUD path
    hudFix=true;_resCmdList[0][FG_ResourceType::Depth]=&list;
    Run(&fg,&queue,1,lists,true);assert(fg.hudWrites==2&&_resCmdList[0].empty()); // HUD early return
    Run(&fg,&queue,1,lists,true); // active HUD, no matched command list
    assert(fg.workGate.TryCloseWhenIdle());_resCmdList[0][FG_ResourceType::Velocity]=&list;
    Run(&fg,&queue,1,lists,true);assert(fg.hudWrites==2&&_resCmdList[0].size()==1); // soft transition
    assert(fg.workGate.Open());fg.paused=true;
    Run(&fg,&queue,1,lists,true);assert(fg.hudWrites==2);fg.paused=false;
    assert(fg.submissionGate.TryCloseWhenIdle());Run(&fg,&queue,1,lists,false); // full admission closed
    Run(nullptr,&queue,1,lists,false); // no provider
    hudFix=false;Run(&fg,&queue,0,nullptr,true); // empty call forwards once, callback owns filtering
    assert(XeFGDiagnostics::observerCalls==8);
    std::cout<<"PASS: actual Execute callback; post-native observation, both HUD branches, admission lifetime and no registry lock across native call\n";
}
'''


RELEASE_HARNESS = r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "misc/LongSessionTiming.h"
using ULONG=unsigned long;
using UINT=unsigned;
struct TrackingMutex {
    std::mutex mutex; bool held=false;
    void lock(){mutex.lock();assert(!held);held=true;}
    void unlock(){assert(held);held=false;mutex.unlock();}
} _trackedResourcesMutex;
struct ID3D12Resource {
    ULONG refs=1;bool live=true;unsigned adds=0,releases=0;
    ULONG AddRef(){assert(live&&_trackedResourcesMutex.held);++adds;return ++refs;}
};
struct HeapInfo {
    ID3D12Resource*current=nullptr;unsigned clears=0;
    void ClearSlotIfMatches(UINT,ID3D12Resource*resource){
        assert(!_trackedResourcesMutex.held&&"descriptor cleanup must not hold reverse-index mutex");
        assert(resource->live&&resource->refs==1&&"temporary pin survives descriptor cleanup");
        ++clears;if(current==resource)current=nullptr;
    }
};
struct TrackedResourceSlot {std::weak_ptr<HeapInfo>heap;uint64_t heapVersion;UINT index;};
std::unordered_map<ID3D12Resource*,std::vector<TrackedResourceSlot>>_trackedResources;
struct State {bool isShuttingDown=false;std::unordered_set<ID3D12Resource*>capturedHudlesses;
    static State&Instance(){static State state;return state;}};
unsigned ordinaryCalls=0,lifetimeCalls=0;
ULONG NativeRelease(ID3D12Resource*r){
    assert(r->live&&r->refs>0);++r->releases;
    const bool probe=(r->releases&1)!=0&&!State::Instance().isShuttingDown;
    assert(_trackedResourcesMutex.held==probe&&"nonfinal probe stays locked; final release stays unlocked");
    --r->refs;if(!r->refs)r->live=false;return r->refs;
}
ULONG ResourceRelease(ID3D12Resource*r){++ordinaryCalls;return NativeRelease(r);}
ULONG CommandRelease(ID3D12Resource*r){++lifetimeCalls;return NativeRelease(r);}
auto o_Release=ResourceRelease;
auto o_CommandListRelease=CommandRelease;
struct ResTrack_Dx12 {static ULONG ReleaseTrackedResource(ID3D12Resource*,bool);};
// ACTUAL_RELEASE
void Track(ID3D12Resource&r,const std::shared_ptr<HeapInfo>&heap){
    _trackedResources[&r].push_back({heap,1,0});State::Instance().capturedHudlesses.insert(&r);
}
int main(){
    auto heap=std::make_shared<HeapInfo>();ID3D12Resource final;heap->current=&final;Track(final,heap);
    assert(ResTrack_Dx12::ReleaseTrackedResource(&final,false)==0);
    assert(!final.live&&final.adds==1&&final.releases==2&&heap->clears==1&&heap->current==nullptr);
    assert(!_trackedResources.contains(&final)&&!State::Instance().capturedHudlesses.contains(&final));
    assert(ordinaryCalls==2&&lifetimeCalls==0);

    ID3D12Resource retained;retained.refs=2;heap->current=&retained;Track(retained,heap);
    assert(ResTrack_Dx12::ReleaseTrackedResource(&retained,true)==1);
    assert(retained.live&&retained.adds==1&&retained.releases==2&&heap->clears==1);
    assert(_trackedResources.contains(&retained)&&State::Instance().capturedHudlesses.contains(&retained));
    assert(lifetimeCalls==2&&ordinaryCalls==2);
    assert(ResTrack_Dx12::ReleaseTrackedResource(&retained,true)==0);
    assert(!retained.live&&retained.adds==2&&retained.releases==4&&heap->clears==2);

    ID3D12Resource expired;{auto gone=std::make_shared<HeapInfo>();Track(expired,gone);}
    assert(ResTrack_Dx12::ReleaseTrackedResource(&expired,false)==0&&!_trackedResources.contains(&expired));
    ID3D12Resource old,replacement;heap->current=&replacement;Track(old,heap);
    assert(ResTrack_Dx12::ReleaseTrackedResource(&old,false)==0&&heap->current==&replacement);

    // Use actual production counters and sampling: exactly 2 of 128 calls.
    for(auto&counter:LongSession::WaitCounters()){counter.calls=0;counter.totalUs=0;counter.maximumUs=0;}
    ID3D12Resource many;many.refs=129;
    for(unsigned i=0;i<128;++i)assert(ResTrack_Dx12::ReleaseTrackedResource(&many,false)==128-i);
    assert(many.live&&many.refs==1&&many.adds==128&&many.releases==256);
    for(auto stage:{LongSession::WaitStage::TrackedReleaseMutex,LongSession::WaitStage::TrackedReleaseProbe,
                    LongSession::WaitStage::TrackedReleaseNative})
        assert(LongSession::WaitCounters()[static_cast<unsigned>(stage)].calls==2);

    ID3D12Resource shutdown;State::Instance().isShuttingDown=true;
    assert(ResTrack_Dx12::ReleaseTrackedResource(&shutdown,true)==0);
    assert(shutdown.adds==0&&shutdown.releases==1&&!shutdown.live&&!_trackedResourcesMutex.held);
    for(auto stage:{LongSession::WaitStage::TrackedReleaseMutex,LongSession::WaitStage::TrackedReleaseProbe,
                    LongSession::WaitStage::TrackedReleaseNative})
        assert(LongSession::WaitCounters()[static_cast<unsigned>(stage)].calls==2);
    std::cout<<"PASS: actual tracked Release; unchanged pin/probe/final refcounts, mutex coverage, weak-slot cleanup, callback dispatch and 1/64 sampled timing\n";
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    source = parser.parse_args().source.resolve()
    hooks = (source / "OptiScaler/resource_tracking/ResTrack_dx12.cpp").read_text(encoding="utf-8")
    function = helpers.extract_function(hooks, "void ResTrack_Dx12::hkExecuteCommandLists(")
    helpers.compile_and_run(source, EXECUTE_HARNESS.replace("// ACTUAL_EXECUTE", function),
                            "R7 actual ResTrack post-Execute observation ordering")
    release = helpers.extract_function(hooks, "ULONG ResTrack_Dx12::ReleaseTrackedResource(")
    helpers.compile_and_run(source, RELEASE_HARNESS.replace("// ACTUAL_RELEASE", release),
                            "R7 actual tracked Release lifetime and sampled timing")


if __name__ == "__main__":
    main()
