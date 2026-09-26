#!/usr/bin/env python3
"""Execute the actual Windows allocation-observer bodies against COM fakes."""
import argparse
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("allocation_adapter_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

FAKES = r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>
#include "misc/GpuAllocationDiagnostics.h"
using HRESULT = int32_t;
using UINT = unsigned;
using HMODULE = void*;
using LPCWSTR = const wchar_t*;
constexpr HRESULT S_OK=0, S_FALSE=1, E_FAIL=-1;
constexpr int FALSE=0, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS=1, GET_MODULE_HANDLE_EX_FLAG_PIN=2;
#define FAILED(value) ((value)<0)
#define SUCCEEDED(value) ((value)>=0)
#define IID_PPV_ARGS(pointer) reinterpret_cast<void**>(pointer)
bool pinSuccess=true;
unsigned pinCalls=0;
int GetModuleHandleExW(unsigned flags,LPCWSTR address,HMODULE* module) {
    ++pinCalls;
    assert(flags==(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN));
    assert(address!=nullptr);
    *module=pinSuccess?reinterpret_cast<void*>(1):nullptr;
    return pinSuccess;
}
struct IUnknown {
    virtual HRESULT QueryInterface(void** output)=0;
    virtual unsigned Release()=0;
};
using DestructionCallback=void(*)(void*);
struct ID3DDestructionNotifier : IUnknown {
    virtual HRESULT RegisterDestructionCallback(DestructionCallback callback,void* token,UINT* id)=0;
};
struct FakeObject : ID3DDestructionNotifier {
    unsigned refs=1,qiCalls=0,releases=0,registerCalls=0;
    bool supported=true,registrationSuccess=true,synchronous=false;
    DestructionCallback callback=nullptr;
    void* token=nullptr;
    HRESULT QueryInterface(void** output) override {
        ++qiCalls;*output=nullptr;
        if(!supported)return E_FAIL;
        ++refs;*output=static_cast<ID3DDestructionNotifier*>(this);return S_OK;
    }
    unsigned Release() override {++releases;assert(refs>1);return --refs;}
    HRESULT RegisterDestructionCallback(DestructionCallback cb,void* opaque,UINT* id) override {
        ++registerCalls; assert(refs==2);assert(opaque!=nullptr&&opaque!=this);
        callback=cb;token=opaque;*id=9;
        if(synchronous)cb(opaque);
        return registrationSuccess?S_OK:E_FAIL;
    }
    void Fire() {if(callback)callback(token);}
    void Balanced() const {assert(refs==1);assert(releases==(supported?qiCalls:0));}
};
namespace GpuAllocationHooks {
using namespace GpuAllocationDiagnostics;
Caller ClassifyCaller(void* address, AllocationMetadata* = nullptr) {return static_cast<Caller>(reinterpret_cast<uintptr_t>(address));}
// ACTUAL_FUNCTIONS
}
using namespace GpuAllocationDiagnostics;
using namespace GpuAllocationHooks;
Snapshot Read() {Snapshot s;assert(TryReadSnapshot(s));return s;}
CallerSnapshot Stats(Caller caller=Caller::FFX) {return Read().callers[static_cast<size_t>(caller)];}
void Observe(FakeObject& object,uint64_t bytes=MinimumTrackedBytes,Caller caller=Caller::FFX) {
    ObserveObject(&object,bytes,Kind::Committed,MemoryClass::Default,
                  reinterpret_cast<void*>(static_cast<uintptr_t>(caller)));
}
// TEST_BODY
'''

NORMAL = r'''
int main() {
    auto initial=Stats(); assert(initial.liveCount==0);
    FakeObject good; Observe(good);good.Balanced();
    assert(good.registerCalls==1&&Stats().liveCount==1);
    const auto stale=good.token;
    good.Fire();assert(Stats().liveCount==0);
    const auto released=Stats().releasedBytes;
    good.Fire();assert(Stats().releasedBytes==released);
    FakeObject replacement;Observe(replacement);replacement.Balanced();
    assert(replacement.token!=stale&&Stats().liveCount==1);
    OnDestroyed(stale);assert(Stats().liveCount==1);
    replacement.Fire();assert(Stats().liveCount==0);

    FakeObject unsupported;unsupported.supported=false;
    const auto noNotifier=Read().notifierUnsupported;
    Observe(unsupported);unsupported.Balanced();
    assert(unsupported.registerCalls==0&&Read().notifierUnsupported==noNotifier+1);
    const auto noNotifier2=Read().notifierUnsupported;
    ObserveObject(nullptr,MinimumTrackedBytes,Kind::Heap,MemoryClass::Default,nullptr);
    assert(Read().notifierUnsupported==noNotifier2+1);

    FakeObject failed;failed.registrationSuccess=false;
    const auto beforeFailure=Stats();const auto failedCount=Read().registrationFailed;
    Observe(failed);failed.Balanced();
    assert(Stats().liveCount==0&&Stats().allocations==beforeFailure.allocations);
    assert(Stats().allocatedBytes==beforeFailure.allocatedBytes);
    assert(Read().registrationFailed==failedCount+1);
    failed.Fire();assert(Stats().liveCount==0);

    FakeObject synchronous;synchronous.synchronous=true;
    const auto beforeSync=Stats();Observe(synchronous);synchronous.Balanced();
    assert(Stats().liveCount==0&&Stats().releases==beforeSync.releases+1);
    synchronous.Fire();assert(Stats().releases==beforeSync.releases+1);
    // A callback concurrent with a failing registration must not underflow.
    FakeObject syncFailed;syncFailed.synchronous=true;syncFailed.registrationSuccess=false;
    Observe(syncFailed);syncFailed.Balanced();assert(Stats().liveCount==0);

    FakeObject small;const auto skipped=Read().smallSkipped;
    Observe(small,MinimumTrackedBytes-1);assert(small.qiCalls==0&&Read().smallSkipped==skipped+1);
    const auto unknown=Read().sizeUnknown;
    Observe(small,0);Observe(small,UINT64_MAX);assert(small.qiCalls==0&&Read().sizeUnknown==unknown+2);
    void* output=&small;const auto allocationsFailed=Read().allocationFailed;
    assert(!IsCreated(E_FAIL,&output)&&Read().allocationFailed==allocationsFailed+1);
    assert(!IsCreated(S_FALSE,&output)&&!IsCreated(S_OK,nullptr));
    output=nullptr;assert(!IsCreated(S_OK,&output));output=&small;assert(IsCreated(S_OK,&output));

    std::vector<std::unique_ptr<FakeObject>> objects;
    for(size_t i=0;i<SlotCount;++i) {
        objects.push_back(std::make_unique<FakeObject>());
        Observe(*objects.back());objects.back()->Balanced();assert(objects.back()->registerCalls==1);
    }
    assert(Stats().liveCount==SlotCount);
    const auto poolFailures=Read().poolExhausted;
    FakeObject overflow;Observe(overflow);overflow.Balanced();
    assert(overflow.registerCalls==0&&Read().poolExhausted==poolFailures+1);
    for(auto& object:objects)object->Fire();
    assert(Stats().liveCount==0&&Stats().liveCommittedBytes==0);
    assert(pinCalls==1); // process-lifetime module pin is cached, never object pinning
    std::cout<<"PASS: actual allocation observer COM callbacks, QI balance, registration failure, pool exhaustion and ABA\n";
}
'''

PIN_FAILURE = r'''
int main() {
    pinSuccess=false;
    const auto failures=Read().pinFailed;
    FakeObject first;Observe(first);first.Balanced();
    assert(first.registerCalls==0&&Stats().liveCount==0&&Read().pinFailed==failures+1);
    pinSuccess=true; // a failed production static pin must remain consistently unavailable
    FakeObject second;Observe(second);second.Balanced();
    assert(second.registerCalls==0&&Stats().liveCount==0&&Read().pinFailed==failures+2);
    assert(pinCalls==1);
    std::cout<<"PASS: actual observer module-pin failure, cached result and balanced QI reference\n";
}
'''

INSTALL_FAKES = r'''
#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <mutex>
#include <vector>
#include "misc/GpuAllocationDiagnostics.h"
using HRESULT=int32_t;using LONG=int32_t;using PVOID=void*;
constexpr LONG NO_ERROR=0, E_FAIL=-1;
#define SUCCEEDED(value) ((value)>=0)
#define IID_PPV_ARGS(pointer) pointer
#define LOG_INFO(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
using Fn=void(*)();
struct ID3D12Device4 {static constexpr int index=0;void** vtable;unsigned refs=1;unsigned Release(){return --refs;}};
struct ID3D12Device8 {static constexpr int index=1;void** vtable;unsigned refs=1;unsigned Release(){return --refs;}};
struct ID3D12Device10 {static constexpr int index=2;void** vtable;unsigned refs=1;unsigned Release(){return --refs;}};
struct ID3D12Device {
    void** vtable;
    std::array<void*,3> extensions;
    template<class T> HRESULT QueryInterface(T** out) {
        *out=static_cast<T*>(extensions[T::index]);
        if(!*out)return E_FAIL;
        ++(*out)->refs;return NO_ERROR;
    }
};
struct DetourEdit {void** original;bool attach;};
std::vector<DetourEdit> pending;
std::map<void**,void*> live;
unsigned attachCalls=0,detachCalls=0,abortCalls=0,beginCalls=0,commitCalls=0;
unsigned failAttachAt=0,failDetachAt=0;
bool failBegin=false,failUpdate=false,failCommit=false;
uintptr_t nextTrampoline=90000;
void* GetCurrentThread(){return reinterpret_cast<void*>(1);}
LONG DetourTransactionBegin(){++beginCalls;pending.clear();return failBegin?E_FAIL:NO_ERROR;}
LONG DetourUpdateThread(void*){return failUpdate?E_FAIL:NO_ERROR;}
LONG DetourAttach(void** original,void*) {
    ++attachCalls;if(attachCalls==failAttachAt)return E_FAIL;
    assert(*original!=nullptr&&live.find(original)==live.end());
    pending.push_back({original,true});return NO_ERROR;
}
LONG DetourDetach(void** original,void*) {
    ++detachCalls;if(detachCalls==failDetachAt)return E_FAIL;
    assert(*original!=nullptr&&live.find(original)!=live.end());
    pending.push_back({original,false});return NO_ERROR;
}
LONG DetourTransactionCommit(){
    ++commitCalls;
    if(failCommit){pending.clear();return E_FAIL;}
    for(const auto& edit:pending){
        if(edit.attach){live[edit.original]=*edit.original;*edit.original=reinterpret_cast<void*>(nextTrampoline++);}
        else {*edit.original=live.at(edit.original);live.erase(edit.original);}
    }
    pending.clear();return NO_ERROR;
}
LONG DetourTransactionAbort(){++abortCalls;pending.clear();return NO_ERROR;}
void ResetFaults(){attachCalls=detachCalls=abortCalls=beginCalls=commitCalls=0;failAttachAt=failDetachAt=0;failBegin=failUpdate=failCommit=false;}
void hkCreateSampler(){} void hkCreateRootSignature(){} void hkD3D12DeviceRelease(){}
void hkSetResidencyPriority(){} void hkCheckFeatureSupport(){} void hkCreateCommittedResource(){}
void hkCreatePlacedResource(){} void hkGetResourceAllocationInfo(){}
Fn o_CreateSampler=nullptr,o_CreateRootSignature=nullptr,o_D3D12DeviceRelease=nullptr;
Fn o_SetResidencyPriority=nullptr,o_CheckFeatureSupport=nullptr,o_CreateCommittedResource=nullptr;
Fn o_CreatePlacedResource=nullptr,o_GetResourceAllocationInfo=nullptr;
bool coreUeHooksInstalled=false;
namespace GpuAllocationHooks {
using namespace GpuAllocationDiagnostics;
using Committed0Fn=Fn;
inline Fn committed1=nullptr,committed2=nullptr,committed3=nullptr,heap0=nullptr,heap1=nullptr;
inline bool baseCommittedHooked=false,installed=false;
inline std::mutex installationMutex;
inline unsigned installationAttempts=0;
inline uint32_t currentApiMask=0;
void hkCommitted1(){} void hkCommitted2(){} void hkCommitted3(){} void hkHeap0(){} void hkHeap1(){}
// ACTUAL_INSTALL_FUNCTIONS
}
// ACTUAL_UNHOOK_FUNCTION
int main(){
    std::array<void*,77> table{};
    for(size_t i=0;i<table.size();++i)table[i]=reinterpret_cast<void*>(1000+i);
    ID3D12Device4 device4{table.data()};ID3D12Device8 device8{table.data()};ID3D12Device10 device10{table.data()};
    ID3D12Device device{table.data(),{&device4,&device8,&device10}};
    using namespace GpuAllocationHooks;
    Install(nullptr,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(installationAttempts==0&&live.empty());
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(installed&&baseCommittedHooked&&currentApiMask==63&&live.size()==6&&attachCalls==6);
    assert(device4.refs==1&&device8.refs==1&&device10.refs==1);
    auto firstPointers=live;
    std::map<void**,void*> originalValues;
    for(const auto& entry:live)originalValues[entry.first]=*entry.first;
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(installationAttempts==1&&attachCalls==6);

    ResetFaults();failDetachAt=3;
    assert(!UnhookDeviceMethods()&&abortCalls==1&&live==firstPointers&&installed&&currentApiMask==63);
    for(const auto& entry:originalValues)assert(*entry.first==entry.second);
    ResetFaults();failCommit=true;
    assert(!UnhookDeviceMethods()&&live==firstPointers&&installed&&currentApiMask==63);
    for(const auto& entry:originalValues)assert(*entry.first==entry.second);
    ResetFaults();assert(UnhookDeviceMethods()&&live.empty()&&!installed&&!baseCommittedHooked);
    assert(currentApiMask==0&&GpuAllocationDiagnostics::installedApiMask.load()==0&&installationAttempts==0);
    assert(o_CreateCommittedResource==nullptr&&heap0==nullptr&&committed1==nullptr&&heap1==nullptr&&committed2==nullptr&&committed3==nullptr);

    ResetFaults();failAttachAt=3;
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(!installed&&currentApiMask==0&&live.empty()&&abortCalls==1&&o_CreateCommittedResource==nullptr);
    assert(heap0==nullptr&&committed1==nullptr&&heap1==nullptr&&committed2==nullptr&&committed3==nullptr);
    ResetFaults();failBegin=true;Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(!installed&&installationAttempts==2&&live.empty());
    ResetFaults();failUpdate=true;Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(!installed&&installationAttempts==3&&live.empty()&&abortCalls==1);
    ResetFaults();Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(!installed&&installationAttempts==3&&beginCalls==0);
    assert(UnhookDeviceMethods()); // successful empty transaction resets retry budget

    // Unsupported extended interfaces are skipped without retaining QI refs.
    device.extensions={nullptr,nullptr,nullptr};ResetFaults();
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(installed&&currentApiMask==3&&live.size()==2);assert(UnhookDeviceMethods());
    device.extensions={&device4,&device8,&device10};

    // A shared unsupported-method thunk must not be hooked as either signature.
    const auto nativeHeap=table[28];table[28]=table[27];ResetFaults();
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,false);
    assert(installed&&!baseCommittedHooked&&currentApiMask==60&&live.size()==4);
    assert(o_CreateCommittedResource==nullptr&&heap0==nullptr);assert(UnhookDeviceMethods());
    table[28]=nativeHeap;

    // A base hook already installed by the existing device path is not attached
    // twice, survives observer install failure, and is detached exactly once.
    o_CreateCommittedResource=reinterpret_cast<Fn>(table[27]);
    auto base=reinterpret_cast<void**>(&o_CreateCommittedResource);
    live[base]=*base;*base=reinterpret_cast<void*>(nextTrampoline++);const auto baseTrampoline=*base;
    coreUeHooksInstalled=true;ResetFaults();failAttachAt=3;
    Install(&device,&o_CreateCommittedResource,hkCreateCommittedResource,true);
    assert(!installed&&baseCommittedHooked&&currentApiMask==1&&live.size()==1&&*base==baseTrampoline);
    ResetFaults();assert(UnhookDeviceMethods()&&live.empty()&&!coreUeHooksInstalled);
    assert(device4.refs==1&&device8.refs==1&&device10.refs==1);
    std::cout<<"PASS: actual allocation Install/Unhook; transactional rollback, partial API support, duplicate targets and shared base hook\n";
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    source = parser.parse_args().source.resolve()
    hooks = (source / "OptiScaler/hooks/GpuAllocationHooks.h").read_text(encoding="utf-8")
    signatures = ["inline void OnDestroyed(", "inline bool PinCallbackModule(",
                  "inline void ObserveObject(", "inline bool IsCreated("]
    actual = "\n".join(helpers.extract_function(hooks, signature) for signature in signatures)
    for title, body in [("allocation observer real callback adapter", NORMAL),
                        ("allocation observer failed module pin in a fresh process", PIN_FAILURE)]:
        helpers.compile_and_run(source, FAKES.replace("// ACTUAL_FUNCTIONS", actual)
                                .replace("// TEST_BODY", body), title)
    install = "\n".join(helpers.extract_function(hooks, signature) for signature in
                        ["inline void Install(", "inline LONG AppendDetachInTransaction(",
                         "inline void FinishDetachSuccess("])
    device_hooks = (source / "OptiScaler/hooks/D3D12_Hooks.cpp").read_text(encoding="utf-8")
    unhook = helpers.extract_function(device_hooks, "static bool UnhookDeviceMethods(")
    helpers.compile_and_run(source, INSTALL_FAKES.replace("// ACTUAL_INSTALL_FUNCTIONS", install)
                            .replace("// ACTUAL_UNHOOK_FUNCTION", unhook),
                            "allocation observer actual Install/Unhook transactional adapter")


if __name__ == "__main__":
    main()
