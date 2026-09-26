#!/usr/bin/env python3
"""Compile real R7 allocation adapters/ledger; COM/Detours only are faked."""
import argparse
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('r6_allocation', HERE.parent / 'r6_recovery/allocation_observer_test.py')
r6 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r6)
h = r6.helpers

DESCRIPTORS = r'''
constexpr unsigned D3D12_HEAP_TYPE_DEFAULT=1,D3D12_HEAP_TYPE_UPLOAD=2,D3D12_HEAP_TYPE_READBACK=3;
constexpr unsigned D3D12_RESOURCE_DIMENSION_BUFFER=1;
struct D3D12_HEAP_PROPERTIES {unsigned Type=1,CPUPageProperty=0,MemoryPoolPreference=0,CreationNodeMask=1,VisibleNodeMask=1;};
struct Samples {unsigned Count=1,Quality=0;};
struct D3D12_RESOURCE_DESC {
    unsigned Dimension=2;uint64_t Alignment=65536,Width=2048;
    unsigned Height=1024,DepthOrArraySize=3,MipLevels=7,Format=28;
    Samples SampleDesc{};unsigned Layout=0,Flags=5;
};
struct D3D12_RESOURCE_DESC1 : D3D12_RESOURCE_DESC {};
struct D3D12_HEAP_DESC {uint64_t SizeInBytes=8*1024*1024,Alignment=65536;D3D12_HEAP_PROPERTIES Properties{};unsigned Flags=12;};
struct AllocationInfo {uint64_t SizeInBytes;};
struct ID3D12Device {
    unsigned infoCalls=0;uint64_t bytes=4*1024*1024;
    AllocationInfo GetResourceAllocationInfo(unsigned,unsigned,const D3D12_RESOURCE_DESC*) {++infoCalls;return {bytes};}
};
struct ID3D12Device8 : ID3D12Device {
    unsigned info2Calls=0;
    AllocationInfo GetResourceAllocationInfo2(unsigned,unsigned,const D3D12_RESOURCE_DESC1*,void*) {++info2Calls;return {bytes};}
};
'''

METADATA = r'''
int main() {
    InitializeObservation(true);InitializeObservation(false);assert(ObservationEnabled());
    assert(PrepareDiagnostics());
    FakeObject object;void* output=&object;ID3D12Device device;D3D12_HEAP_PROPERTIES properties;
    D3D12_RESOURCE_DESC desc;
    ObserveCommitted0(S_OK,&device,&properties,&desc,&output,reinterpret_cast<void*>(3),0x40,true);
    object.Balanced();assert(device.infoCalls==1);
    DetailSnapshot detail;const auto now=MonotonicMilliseconds()+10;assert(TryReadDetailSnapshot(detail,now));
    assert(detail.liveObjects==1&&detail.groupCount==1&&detail.observedBytes==device.bytes);
    const auto group=detail.groups[0];const auto& m=group.metadata;
    assert(group.caller==Caller::FFX&&group.kind==Kind::Committed&&group.memory==MemoryClass::Default);
    assert(m.moduleBase==0x100000&&m.callerRva==3&&m.createdMs==0);
    assert(m.width==2048&&m.height==1024&&m.depthOrArray==3&&m.mipLevels==7&&m.format==28);
    assert(m.sampleCount==1&&m.alignment==65536&&m.resourceFlags==5&&m.heapFlags==0x40);
    assert(m.descriptorKnown&&m.heapFlagsKnown&&m.creationNodeMask==1&&m.visibleNodeMask==1);
    assert(group.oldestAgeMs>=10&&group.oldestAgeMs==group.youngestAgeMs);
    object.Fire();assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);

    FakeObject small;output=&small;desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=MinimumTrackedBytes-1;
    const auto skips=Read().smallSkipped;
    ObserveCommitted0(S_OK,&device,&properties,&desc,&output,nullptr);
    assert(device.infoCalls==1&&small.qiCalls==0&&Read().smallSkipped==skips+1);
    ObserveCommitted0(E_FAIL,&device,&properties,&desc,&output,nullptr);
    assert(device.infoCalls==1&&small.qiCalls==0);
    // Texture dimensions/format never justify skipping the real size query.
    desc.Dimension=2;desc.Width=1;desc.Height=1;device.bytes=MinimumTrackedBytes;
    ObserveCommitted0(S_OK,&device,&properties,&desc,&output,nullptr);
    assert(device.infoCalls==2&&small.registerCalls==1);small.Fire();small.Balanced();

    FakeObject extended;output=&extended;ID3D12Device8 device8;D3D12_RESOURCE_DESC1 desc1;
    ObserveCommitted2(S_OK,&device8,&properties,&desc1,&output,reinterpret_cast<void*>(3),16,true);
    assert(device8.info2Calls==1&&device8.infoCalls==0);extended.Fire();extended.Balanced();
    desc1.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc1.Width=100;
    ObserveCommitted2(S_OK,&device8,&properties,&desc1,&output,nullptr);
    assert(device8.info2Calls==1&&extended.qiCalls==1);

    FakeObject heap;output=&heap;D3D12_HEAP_DESC heapDesc;heapDesc.Properties.Type=D3D12_HEAP_TYPE_UPLOAD;
    ObserveHeap(S_OK,&heapDesc,&output,reinterpret_cast<void*>(3));heap.Balanced();
    assert(TryReadDetailSnapshot(detail));assert(detail.groups[0].kind==Kind::Heap);
    assert(detail.groups[0].memory==MemoryClass::CpuVisible&&detail.groups[0].metadata.heapFlags==12);
    assert(detail.groups[0].metadata.alignment==65536&&detail.groups[0].liveBytes==heapDesc.SizeInBytes);
    heap.Fire();

    FakeObject failed;failed.registrationSuccess=false;output=&failed;
    ObserveCommitted0(S_OK,&device,&properties,&desc,&output,nullptr);
    failed.Balanced();assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);
    failed.Fire();assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);

    auto* ledger=Instance();std::vector<uint64_t> tokens;
    AllocationMetadata a;a.moduleBase=100;a.callerRva=20;a.createdMs=100;a.descriptorKnown=true;
    tokens.push_back(ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,2*MinimumTrackedBytes,a));
    a.createdMs=300;tokens.push_back(ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,3*MinimumTrackedBytes,a));
    // Group ignores time, preserves descriptor/callsite and sorts by total bytes.
    for(unsigned i=0;i<12;++i){a.callerRva=100+i;tokens.push_back(ledger->Track(Caller::Game,Kind::Heap,MemoryClass::Default,MinimumTrackedBytes,a));}
    assert(TryReadDetailSnapshot(detail,1100));
    assert(detail.liveObjects==14&&detail.groupCount==8&&detail.observedBytes==17*MinimumTrackedBytes);
    assert(detail.groups[0].liveCount==2&&detail.groups[0].liveBytes==5*MinimumTrackedBytes);
    assert(detail.groups[0].oldestAgeMs==1000&&detail.groups[0].youngestAgeMs==800);
    const auto old=tokens.front();assert(ledger->Retire(old));a.callerRva=777;a.width=999;
    const auto replacement=ledger->Track(Caller::XeFG,Kind::Heap,MemoryClass::Default,9*MinimumTrackedBytes,a);
    assert(replacement!=old&&!ledger->Retire(old));assert(TryReadDetailSnapshot(detail,200));
    assert(detail.groups[0].metadata.callerRva==777&&detail.groups[0].metadata.width==999);
    assert(detail.groups[0].oldestAgeMs==0); // non-monotonic supplied snapshot time cannot underflow
    assert(ledger->Cancel(replacement));for(auto token:tokens)ledger->Retire(token);
    assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);
    {
        std::lock_guard hold(DetailWorkspaceInstance()->mutex);
        assert(!TryReadDetailSnapshot(detail)); // no reporter waits on another sort
    }
    std::cout<<"PASS: production descriptor copying, real query counts, groups/ages/top8, failed registration, ABA and try-lock\n";
}
'''

DISABLED = r'''
int main() {
    InitializeObservation(false);InitializeObservation(true);
    assert(!ObservationEnabled());auto s=Read();assert(s.observationInitialized&&!s.observationEnabled);
    FakeObject object;void* output=&object;ID3D12Device device;ID3D12Device8 device8;
    D3D12_HEAP_PROPERTIES properties;D3D12_RESOURCE_DESC desc;D3D12_RESOURCE_DESC1 desc1;D3D12_HEAP_DESC heap;
    ObserveCommitted0(S_OK,&device,&properties,&desc,&output,nullptr);
    ObserveCommitted2(S_OK,&device8,&properties,&desc1,&output,nullptr);
    ObserveHeap(S_OK,&heap,&output,nullptr);Observe(object);
    assert(device.infoCalls==0&&device8.info2Calls==0&&object.qiCalls==0&&pinCalls==0);
    DetailSnapshot detail;assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);
    // Callback retirement remains functional regardless of the observation switch.
    const auto token=Instance()->Track(Caller::FFX,Kind::Heap,MemoryClass::Default,MinimumTrackedBytes);
    OnDestroyed(reinterpret_cast<void*>(static_cast<uintptr_t>(token)));
    std::array<CallerSnapshot,CallerCount> counters;assert(Instance()->TryRead(counters));
    assert(counters[static_cast<size_t>(Caller::FFX)].liveCount==0);
    std::cout<<"PASS: startup-off is immutable, adds no COM/driver work, and never blocks existing retirement\n";
}
'''

PURE = r'''
#include <cassert>
#include <thread>
#include <vector>
#include <iostream>
#include "misc/GpuAllocationDiagnostics.h"
using namespace GpuAllocationDiagnostics;
int main(){
    InitializeObservation(true);assert(PrepareDiagnostics());
    for(unsigned i=0;i<63;++i){SampledDiagnosticTimer timer(TimingStage::Observation);}
    Snapshot s;assert(TryReadSnapshot(s)&&s.timing[0].samples==0);
    {SampledDiagnosticTimer timer(TimingStage::Observation);}
    assert(TryReadSnapshot(s)&&s.timing[0].samples==1);
    for(unsigned i=0;i<64;++i){SampledDiagnosticTimer timer(TimingStage::Destruction);}
    assert(TryReadSnapshot(s)&&s.timing[1].samples==1&&s.timing[0].samples==1);
    std::atomic<bool> finished{false};
    std::thread writer([&]{for(unsigned i=0;i<10000;++i){AllocationMetadata m;m.callerRva=i;m.createdMs=MonotonicMilliseconds();
        auto t=Instance()->Track(Caller::Game,Kind::Committed,MemoryClass::Default,MinimumTrackedBytes,m);assert(t);assert(Instance()->Retire(t));}finished=true;});
    while(!finished){DetailSnapshot d;if(TryReadDetailSnapshot(d)){assert(d.liveObjects<=1);assert(d.observedBytes==d.liveObjects*MinimumTrackedBytes);}}
    writer.join();DetailSnapshot detail;assert(TryReadDetailSnapshot(detail)&&detail.liveObjects==0);
    assert(TryReadSnapshot(s)&&s.callers[0].allocations==10000&&s.callers[0].releases==10000);
    std::cout<<"PASS: exact 1/64 per-stage timing and concurrent actual ledger/snapshot consistency\n";
}
'''


GROWTH = r'''
#include <cassert>
#include <iostream>
#include <vector>
#include "misc/GpuAllocationDiagnostics.h"
using namespace GpuAllocationDiagnostics;
int main(){
    InitializeObservation(true);assert(PrepareDiagnostics());auto* ledger=Instance();
    AllocationMetadata stable;stable.callerRva=1;stable.createdMs=100;
    AllocationMetadata growing=stable;growing.callerRva=2;
    const auto large=ledger->Track(Caller::Game,Kind::Heap,MemoryClass::Default,100*MinimumTrackedBytes,stable);
    const auto small=ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,MinimumTrackedBytes,growing);
    DetailSnapshot d;assert(TryReadDetailSnapshot(d,1000));
    assert(!d.growthBaselineAvailable&&d.growthGroupCount==0&&d.growthIntervalMs==0);
    const auto addition=ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,2*MinimumTrackedBytes,growing);
    assert(TryReadDetailSnapshot(d,2000)&&d.growthBaselineAvailable&&d.growthIntervalMs==1000);
    assert(d.growthBaselineCapturedMs==1000&&d.groups[0].metadata.callerRva==1);
    assert(d.growthGroupCount==1&&d.growthGroups[0].group.metadata.callerRva==2);
    assert(d.growthGroups[0].baselineBytes==MinimumTrackedBytes&&d.growthGroups[0].growthBytes==2*MinimumTrackedBytes);
    assert(d.growthGroups[0].group.liveBytes==3*MinimumTrackedBytes);
    const auto later=ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,4*MinimumTrackedBytes,growing);
    {std::lock_guard hold(DetailWorkspaceInstance()->mutex);assert(!TryReadDetailSnapshot(d,3000));}
    assert(TryReadDetailSnapshot(d,4500)&&d.growthIntervalMs==2500&&d.growthBaselineCapturedMs==2000);
    assert(d.growthGroups[0].growthBytes==4*MinimumTrackedBytes);
    assert(ledger->Retire(small)&&ledger->Retire(addition)&&ledger->Retire(later));
    assert(TryReadDetailSnapshot(d,5000)&&d.growthGroupCount==0&&d.liveObjects==1);
    const auto recreated=ledger->Track(Caller::Game,Kind::Committed,MemoryClass::Default,3*MinimumTrackedBytes,growing);
    assert(TryReadDetailSnapshot(d,6000)&&d.growthGroupCount==1&&d.growthIntervalMs==1000);
    assert(d.growthGroups[0].baselineBytes==0&&d.growthGroups[0].growthBytes==3*MinimumTrackedBytes);
    assert(TryReadDetailSnapshot(d,7000)&&d.growthGroupCount==0); // stable group is never reported as growth
    std::vector<uint64_t> extra;
    for(unsigned i=0;i<20;++i){auto m=growing;m.callerRva=10+i;
        extra.push_back(ledger->Track(Caller::Game,Kind::Heap,MemoryClass::Default,(i+1)*MinimumTrackedBytes,m));}
    assert(TryReadDetailSnapshot(d,8000)&&d.growthGroupCount==8);
    assert(d.growthGroups[0].growthBytes==20*MinimumTrackedBytes&&d.growthGroups[7].growthBytes==13*MinimumTrackedBytes);
    // Aggregate compaction preserves sorted keys, including multi-object groups.
    const auto doubled=ledger->Track(Caller::Game,Kind::Heap,MemoryClass::Default,5*MinimumTrackedBytes,stable);
    assert(TryReadDetailSnapshot(d,9000)&&d.growthGroupCount==1&&d.growthGroups[0].baselineBytes==100*MinimumTrackedBytes);
    assert(d.growthGroups[0].growthBytes==5*MinimumTrackedBytes);
    assert(TryReadDetailSnapshot(d,10000)&&d.growthGroupCount==0);
    // A regressing supplied timestamp cannot yield an invented positive interval.
    assert(TryReadDetailSnapshot(d,9500)&&!d.growthBaselineAvailable&&d.growthIntervalMs==0);
    for(auto token:extra)ledger->Retire(token);ledger->Retire(large);ledger->Retire(doubled);ledger->Retire(recreated);
    assert(TryReadDetailSnapshot(d,11000)&&d.liveObjects==0&&d.growthGroupCount==0);
    std::cout<<"PASS: growth detects smaller growing group, bounded top8, disappearance/recreation and successful-snapshot intervals\n";
}
'''


CALLER_FAKES = r'''
unsigned callerQueries=0,ownQueries=0,gameQueries=0;
namespace Util {
void* GetCallerModule(void* address){
    ++callerQueries;const auto value=reinterpret_cast<uintptr_t>(address);
    if(value==0)return nullptr;
    if(value>=0x100000&&value<0xC01000)return reinterpret_cast<void*>(value&~uintptr_t(0xFFF));
    ++ownQueries;return reinterpret_cast<void*>(0x600000);
}}
void* GetModuleHandleW(const wchar_t*){++gameQueries;return reinterpret_cast<void*>(0x100000);}
struct XeFGProxy {static void* Module(){return reinterpret_cast<void*>(0x200000);}};
struct XeSSProxy {static void* Module(){return reinterpret_cast<void*>(0x300000);}};
struct StreamlineProxy {static void* Module(){return reinterpret_cast<void*>(0x500000);}};
struct FfxApiProxy {
static void* Dx12Module(){return reinterpret_cast<void*>(0x400000);}
static void* Dx12Module_SR(){return reinterpret_cast<void*>(0x800000);}
static void* Dx12Module_FG(){return reinterpret_cast<void*>(0x900000);}
static void* Dx12Module_Denoiser(){return reinterpret_cast<void*>(0xA00000);}
static void* Dx12Module_Radiance(){return reinterpret_cast<void*>(0xB00000);}
};
'''
CALLER_TEST = r'''
int main(){
    AllocationMetadata metadata;
    assert(ClassifyCaller(reinterpret_cast<void*>(0x100123),&metadata)==Caller::Game);
    assert(metadata.moduleBase==0x100000&&metadata.callerRva==0x123&&callerQueries==2);
    for(unsigned i=0;i<10;++i)assert(ClassifyCaller(reinterpret_cast<void*>(0x100456),&metadata)==Caller::Game);
    assert(callerQueries==12&&ownQueries==1&&gameQueries==1); // one immediate-module query per later object
    assert(ClassifyCaller(reinterpret_cast<void*>(0x200010),&metadata)==Caller::XeFG);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x300010),&metadata)==Caller::XeSS);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x400010),&metadata)==Caller::FFX);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x500010),&metadata)==Caller::Streamline);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x600010),&metadata)==Caller::OptiScaler);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x700ABC),&metadata)==Caller::Other);
    assert(metadata.moduleBase==0x700000&&metadata.callerRva==0xABC);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x800010),&metadata)==Caller::FFX);
    assert(ClassifyCaller(reinterpret_cast<void*>(0x900010),&metadata)==Caller::FFX);
    assert(ClassifyCaller(reinterpret_cast<void*>(0xA00010),&metadata)==Caller::FFX);
    assert(ClassifyCaller(reinterpret_cast<void*>(0xB00010),&metadata)==Caller::FFX);
    assert(ClassifyCaller(nullptr,&metadata)==Caller::Unknown&&metadata.moduleBase==0&&metadata.callerRva==0);
    assert(ownQueries==1&&gameQueries==1);
    std::cout<<"PASS: actual caller/RVA classification and removed repeated own-module lookups\n";
}
'''


def main():
    parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);source=parser.parse_args().source.resolve()
    hooks=(source/'OptiScaler/hooks/GpuAllocationHooks.h').read_text()
    fake_classifier=h.extract_function(r6.FAKES,'Caller ClassifyCaller(')
    fake=r6.FAKES.replace(fake_classifier,
        'Caller ClassifyCaller(void* address, AllocationMetadata* metadata=nullptr) {if(metadata){metadata->moduleBase=0x100000;metadata->callerRva=reinterpret_cast<uintptr_t>(address);}return static_cast<Caller>(reinterpret_cast<uintptr_t>(address));}')
    basic='\n'.join(h.extract_function(hooks,signature) for signature in
        ['inline void OnDestroyed(', 'inline bool PinCallbackModule(', 'inline void ObserveObject(', 'inline bool IsCreated('])
    for title,body in [('R6 COM ownership/failure/ABA regressions',r6.NORMAL),('module pin failure fresh process',r6.PIN_FAILURE)]:
        h.compile_and_run(source,fake.replace('// ACTUAL_FUNCTIONS',basic).replace('// TEST_BODY',body),title)
    metadata='\n'.join([h.extract_function(hooks,'inline MemoryClass ClassifyMemory('),
        h.extract_function(hooks,'inline void CopyHeapProperties('),
        'template<class Description>\n'+h.extract_function(hooks,'inline AllocationMetadata CopyResourceMetadata('),
        h.extract_function(hooks,'inline void ObserveCommitted0('),
        h.extract_function(hooks,'inline void ObserveCommitted2('),h.extract_function(hooks,'inline void ObserveHeap(')])
    full=fake.replace('namespace GpuAllocationHooks {',DESCRIPTORS+'\nnamespace GpuAllocationHooks {').replace('// ACTUAL_FUNCTIONS',basic+'\n'+metadata)
    h.compile_and_run(source,full.replace('// TEST_BODY',METADATA),'R7 actual metadata/query/callback adapter')
    h.compile_and_run(source,full.replace('// TEST_BODY',DISABLED),'R7 startup-off actual observation adapter')
    h.compile_and_run(source,PURE,'R7 production ledger metadata/concurrency/timing')
    h.compile_and_run(source,GROWTH,'R7 production group growth/delta-baseline semantics')
    classifier=h.extract_function(hooks,'inline Caller ClassifyCaller(')
    caller_harness=r6.FAKES.replace('namespace GpuAllocationHooks {',CALLER_FAKES+'\nnamespace GpuAllocationHooks {')
    caller_harness=caller_harness.replace(fake_classifier,classifier)
    h.compile_and_run(source,caller_harness.replace('// ACTUAL_FUNCTIONS',basic).replace('// TEST_BODY',CALLER_TEST),
                      'R7 actual module classification/RVA and query optimization')
    install='\n'.join(h.extract_function(hooks,signature) for signature in
        ['inline void Install(', 'inline LONG AppendDetachInTransaction(', 'inline void FinishDetachSuccess('])
    dh=(source/'OptiScaler/hooks/D3D12_Hooks.cpp').read_text()
    unhook=h.extract_function(dh,'static bool UnhookDeviceMethods(')
    install_harness=r6.INSTALL_FAKES.replace('// ACTUAL_INSTALL_FUNCTIONS',install).replace('// ACTUAL_UNHOOK_FUNCTION',unhook)
    h.compile_and_run(source,install_harness,'R7 actual install/unhook rollback regression')
    before_main=install_harness[:install_harness.index('int main()')]
    offmain=r'''
int main(){
    GpuAllocationDiagnostics::InitializeObservation(false);
    std::array<void*,77> table{};ID3D12Device device{table.data(),{nullptr,nullptr,nullptr}};
    GpuAllocationHooks::Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(beginCalls==0&&attachCalls==0&&GpuAllocationHooks::installationAttempts==0);
    assert(!GpuAllocationHooks::installed&&GpuAllocationDiagnostics::installedApiMask.load()==0);
    std::cout<<"PASS: startup-off skips actual Install before device QI/Detours\n";
}
'''
    h.compile_and_run(source,before_main+offmain,'R7 startup-off actual detour installer')

if __name__=='__main__':main()
