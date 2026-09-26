#include "misc/ResidencyDiagnostics.h"
#include <cassert>
#include <cstdint>
#include <iostream>
using HRESULT=int32_t;using UINT=unsigned;using HMODULE=void*;
constexpr HRESULT S_OK=0,E_INVALIDARG=static_cast<int32_t>(0x80070057u);
#define FAILED(x) ((x)<0)
static unsigned logs=0;
#define LOG_WARN(...) (++logs)
struct LUID{uint32_t LowPart=123;int32_t HighPart=0;};
static uint64_t ResidencyLuidKey(LUID id){return (uint64_t(static_cast<uint32_t>(id.HighPart))<<32)|id.LowPart;}
struct ID3D12Device1{LUID luid;LUID GetAdapterLuid(){return luid;}};
struct ID3D12Pageable{};using D3D12_RESIDENCY_PRIORITY=uint32_t;
static std::atomic<bool> residencyAmdKnown{false};static std::atomic<uint64_t> residencyAmdLuid{123};
static HMODULE callerModule=nullptr,xefgModule=reinterpret_cast<void*>(1),xessModule=reinterpret_cast<void*>(2);
static unsigned originalCalls=0;static HRESULT originalResult=0;
void* _ReturnAddress(){return nullptr;}
namespace Util{HMODULE GetCallerModule(void*){return callerModule;}}
namespace XeFGProxy{HMODULE Module(){return xefgModule;}}
namespace XeSSProxy{HMODULE Module(){return xessModule;}}
static HRESULT o_SetResidencyPriority(ID3D12Device1*,UINT count,ID3D12Pageable* const* objects,const D3D12_RESIDENCY_PRIORITY* priorities){
    ++originalCalls;assert(count==999 && objects==nullptr && priorities==nullptr);return originalResult;
}
// ACTUAL_FUNCTION
int main(){
    ID3D12Device1 device;
    const int32_t results[]{0,1,E_INVALIDARG,static_cast<int32_t>(0x8007000Eu),static_cast<int32_t>(0x887A0005u),
        static_cast<int32_t>(0x887A0006u),static_cast<int32_t>(0x887A0007u),static_cast<int32_t>(0x887A0001u),-1};
    for(auto module:{xefgModule,xessModule,reinterpret_cast<void*>(3),static_cast<void*>(nullptr)})
      for(bool known:{false,true})for(bool matchingLuid:{false,true})for(auto result:results){
        callerModule=module;residencyAmdKnown=known;device.luid.LowPart=matchingLuid?123:456;originalResult=result;
        const auto before=originalCalls;const auto reported=hkSetResidencyPriority(&device,999,nullptr,nullptr);
        const bool expectedMask=result==E_INVALIDARG && known && matchingLuid && (module==xefgModule||module==xessModule);
        assert(originalCalls==before+1 && reported==(expectedMask?S_OK:result));
        if(result<0){ResidencyDiagnostics::Snapshot status;assert(ResidencyDiagnostics::TryReadSnapshot(status));
          assert(status.lastFailure==result && status.lastMasked==expectedMask && status.lastObjects==999);}
      }
    callerModule=xefgModule=xessModule=nullptr;residencyAmdKnown=true;device.luid.LowPart=123;originalResult=E_INVALIDARG;
    assert(hkSetResidencyPriority(&device,999,nullptr,nullptr)==E_INVALIDARG);
    for(unsigned repeat=0;repeat<10000;++repeat)hkSetResidencyPriority(&device,999,nullptr,nullptr);
    assert(logs<=32);
    // Independent classes keep a later device-removal report available after a mask storm.
    for(auto& count:ResidencyDiagnostics::logCounts)count=0;
    unsigned maskedLogs=0;for(unsigned i=0;i<1000;++i)maskedLogs+=ResidencyDiagnostics::Record(E_INVALIDARG,ResidencyDiagnostics::Caller::XeFG,1,true);
    assert(maskedLogs==4);
    assert(ResidencyDiagnostics::Record(static_cast<int32_t>(0x887A0005u),ResidencyDiagnostics::Caller::XeFG,1,false));
    std::cout<<"PASS: actual residency native-once forwarding, AMD-only invalidarg exception, original errors and bounded logs\n";
}
