#!/usr/bin/env python3
"""R8 regression checks run production capacity policy, guards and DLL patcher.

CPU tests verify the allocation contract and count handling. They do not measure
GPU allocation savings, image quality, SDK driver execution or Dogtown FPS.
"""
import argparse
import ast
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("r8_compile_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

POLICY = r'''
#include <cassert>
#include <climits>
#include <iostream>
#include "framegen/xefg/XeFGCapacityPolicy.h"
struct Case {int supported,requested;bool explicitRequest,dynamicApi,lowMemory;int expected;};
int main() {
    const Case cases[] = {
        {5,2,true,true,true,3}, // 3X shares 4X allocation capacity
        {5,3,true,true,true,3}, // 4X uses that same capacity
        {5,1,true,true,true,3}, // 2X can also change to 3X/4X without recreate
        {5,4,true,true,true,5}, // startup 5X reserves full six-total ceiling
        {5,5,true,true,true,5}, // startup 6X remains available
        {5,2,false,true,true,5}, // Auto allows later game-requested higher counts
        {5,3,false,true,true,5},
        {5,2,true,true,false,5}, // compatibility switch restores former capacity
        {5,3,true,true,false,5},
        {3,2,true,true,true,3}, // native lower maximum respected
        {3,4,true,true,true,3},
        {1,2,true,true,true,1}, // failed unlock / 2X-only SDK
        {1,5,false,true,true,1},
        {0,2,true,true,true,1},
        {-1,2,true,true,true,1},
        {5,0,true,true,true,5}, // invalid explicit counts do not underreserve
        {5,-1,true,true,true,5},
        {5,INT_MAX,true,true,true,5},
        {5,2,true,false,true,2}, // legacy SDK controls count through init capacity
        {5,3,true,false,true,3},
        {5,4,true,false,true,4},
        {5,5,true,false,false,5},
        {5,0,true,false,true,1},
        {5,-1,true,false,true,1},
        {3,4,true,false,true,1},
    };
    for (const auto& c : cases)
        assert(XeFGCapacity::SelectInitialCapacity(c.supported,c.requested,c.explicitRequest,
                                                 c.dynamicApi,c.lowMemory)==c.expected);
    const int capacity = XeFGCapacity::SelectInitialCapacity(5,2,true,true,true);
    for (int request : {2,3,2,3,3,2})
        assert(XeFGCapacity::CanApply(request,capacity)); // user 3X <-> 4X path
    for (int request : {4,5,6,INT_MAX,0,-1,INT_MIN})
        assert(!XeFGCapacity::CanApply(request,capacity));
    assert(!XeFGCapacity::CanApply(1,0));
    assert(!XeFGCapacity::CanApply(1,-1));
    assert(XeFGCapacity::CanApply(1,1));
    assert(!XeFGCapacity::CanApply(2,1));
    assert(XeFGCapacity::CanApply(5,5));
    assert(!XeFGCapacity::CanApply(6,5));
    std::cout << "PASS: production capacity policy; explicit 3X/4X, 5X/6X, Auto, opt-out, old SDK and invalid boundaries\n";
}
'''


RUNTIME = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <optional>
#include <vector>
#include "framegen/xefg/XeFGCapacityPolicy.h"
#define DONT_USE_XMX 1
#define LOG_INFO(...) ((void)0)
#define LOG_WARN(...) (++warningCount)
#define LOG_ERROR(...) ((void)0)
template<class T> struct Option {
    T fallback; std::optional<T> selected;
    T value_or_default() const {return selected.value_or(fallback);}
    bool has_value() const {return selected.has_value();}
    Option&operator=(T x){selected=x;return *this;}
};
struct Config {Option<int> FGXeFGInterpolationCount{1,2};
    static Config*Instance(){static Config c;return &c;}};
constexpr int XEFG_SWAPCHAIN_RESULT_SUCCESS=0;
namespace XeFGDiagnostics {int active=0,writes=0;void RecordInterpolationActive(uint32_t n){active=n;++writes;}}
namespace XeFGPacing {int resets=0;void RequestReset(){++resets;}}
namespace XeFGProxy {
bool dynamicAvailable=true;int sdkResult=0,legalCapacity=3;std::vector<int>requests;
int SetCount(void*,int count){assert(count>=1&&count<=legalCapacity);requests.push_back(count);return sdkResult;}
auto SetNumInterpolatedFrames()->int(*)(void*,int){return dynamicAvailable?SetCount:nullptr;}
}
int gameRequest=0;
int GameRequestedInterpolationCount(){return gameRequest;}
struct FakeState {bool WAR_xefgRequestFGToggle=false;};
struct Fixture {
    std::atomic<int> _initializedInterpolationCapacity{3};int _maxInterpolationCount=5;
    int _lastCapacityRequest=-1,_framesToInterpolate=2,warningCount=0,historyResets=0;
    void*_swapChainContext=this;FakeState state;
    void RequestHistoryReset(){++historyResets;}
    void Tick(){
        // ACTUAL_RUNTIME_GUARD
    }
};
int main(){
    Fixture f;auto&cfg=Config::Instance()->FGXeFGInterpolationCount;
    f.Tick();assert(XeFGProxy::requests.empty()); // unchanged 3X never sends redundant SDK calls
    cfg=3;f.Tick();assert(f._framesToInterpolate==3&&XeFGProxy::requests==std::vector<int>{3});
    assert(XeFGDiagnostics::active==3&&XeFGDiagnostics::writes==1&&XeFGPacing::resets==1);
    assert(f.historyResets==1&&f.state.WAR_xefgRequestFGToggle);
    cfg=2;f.Tick();assert(f._framesToInterpolate==2&&XeFGProxy::requests.back()==2);
    auto calls=XeFGProxy::requests.size();auto writes=XeFGDiagnostics::writes;
    for(int request:{4,5,0,-1,6}) {
        cfg=request;f.state.WAR_xefgRequestFGToggle=false;const auto warns=f.warningCount;
        f.Tick();f.Tick();
        assert(cfg.value_or_default()==request); // pending higher selection survives Save settings
        assert(f._framesToInterpolate==2&&XeFGProxy::requests.size()==calls);
        assert(XeFGDiagnostics::writes==writes&&!f.state.WAR_xefgRequestFGToggle);
        assert(f.warningCount==warns+1); // do not flood logs every frame for pending restart
    }
    cfg=3;XeFGProxy::sdkResult=-1;f.Tick();
    assert(f._framesToInterpolate==2&&XeFGDiagnostics::writes==writes);
    assert(!f.state.WAR_xefgRequestFGToggle); // failed SDK call does not advertise success
    XeFGProxy::sdkResult=0;f.Tick();assert(f._framesToInterpolate==3);
    cfg.selected.reset();gameRequest=5;calls=XeFGProxy::requests.size();f.Tick();
    assert(!cfg.has_value()&&XeFGProxy::requests.size()==calls&&f._framesToInterpolate==3);
    gameRequest=2;f.Tick();assert(!cfg.has_value()&&f._framesToInterpolate==2);
    f._initializedInterpolationCapacity=5;XeFGProxy::legalCapacity=5;
    for(int request:{4,5}) {cfg=request;f.Tick();assert(f._framesToInterpolate==request);}
    // A lower real SDK maximum remains binding even with spare initialized capacity.
    f._maxInterpolationCount=1;cfg=2;calls=XeFGProxy::requests.size();f.Tick();
    assert(XeFGProxy::requests.size()==calls&&cfg.value_or_default()==2);
    XeFGProxy::dynamicAvailable=false;cfg=1;f.Tick();assert(XeFGProxy::requests.size()==calls);
    // A new context has no active count yet. An unsupported saved request must
    // not prevent the first safe SDK setup (e.g. the unlock failed to install).
    XeFGProxy::dynamicAvailable=true;XeFGProxy::legalCapacity=1;
    f._framesToInterpolate=-1;f._initializedInterpolationCapacity=1;f._maxInterpolationCount=1;
    cfg=2;f.Tick();
    assert(XeFGProxy::requests.size()==calls+1&&XeFGProxy::requests.back()==1);
    assert(cfg.value_or_default()==2&&f._framesToInterpolate==1);
    calls=XeFGProxy::requests.size();cfg=5;f.Tick();
    assert(XeFGProxy::requests.size()==calls&&cfg.value_or_default()==5&&f._framesToInterpolate==1);
    // If even that first fallback is rejected, keep it unapplied and retry;
    // never claim successful FG or erase the user's higher selection.
    f._framesToInterpolate=-1;XeFGProxy::sdkResult=-1;writes=XeFGDiagnostics::writes;
    f.Tick();assert(f._framesToInterpolate==-1&&XeFGDiagnostics::writes==writes&&cfg.value_or_default()==5);
    XeFGProxy::sdkResult=0;f.Tick();assert(f._framesToInterpolate==1&&cfg.value_or_default()==5);
    std::cout<<"PASS: actual runtime guard; 3X/4X live changes, pending 5X/6X, Auto, failure, lower SDK and legacy\n";
}
'''


UI = r'''
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <iostream>
#include <optional>
#include <string>
#include <vector>
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define IM_ARRAYSIZE(x) (sizeof(x)/sizeof((x)[0]))
template<class T>struct Option {T fallback;std::optional<T> selected;
    T value_or_default()const{return selected.value_or(fallback);}
    bool has_value()const{return selected.has_value();}
    Option&operator=(T v){selected=v;return *this;}
    Option&operator=(std::nullopt_t){selected.reset();return *this;}};
struct Config {Option<int>FGXeFGInterpolationCount{1,2};Option<bool>FGXeFGLowMemoryMode{true,{}};};
struct FG {int active=2,capacity=3,supported=5;
    int GetMaxInterpolationCount(){return supported;}
    int GetInitializedInterpolationCapacity(){return capacity;}
    int GetInterpolatedFrameCount(){return active;}};
namespace XeFGProxy {bool dynamic=true;void*SetNumInterpolatedFrames(){return dynamic?reinterpret_cast<void*>(1):nullptr;}}
struct ImVec4 {ImVec4(float,float,float,float){}};
ImVec4 toneMapColor(ImVec4 c){return c;}
void ShowHelpMarker(const char*){}
namespace ImGui {
std::string click,comboLabel;int typed=0;std::vector<std::string>messages;
bool Checkbox(const char*,bool*){return false;}
void SameLine(float=0,float=0){}
void PushItemWidth(float){}void PopItemWidth(){}
bool BeginCombo(const char*,const char*label){comboLabel=label;return true;}
bool Selectable(const char*label,bool){if(click==label){click.clear();return true;}return false;}
void EndCombo(){}
bool InputInt(const char*,int*p,int,int){if(typed){*p=typed;typed=0;return true;}return false;}
void TextColored(ImVec4,const char*fmt,...){char b[512];va_list a;va_start(a,fmt);vsnprintf(b,sizeof b,fmt,a);va_end(a);messages.emplace_back(b);}
void TextWrapped(const char*fmt,...){char b[512];va_list a;va_start(a,fmt);vsnprintf(b,sizeof b,fmt,a);va_end(a);messages.emplace_back(b);}
}
struct State {bool fgChanged=false;};
void Draw(Config*config,FG*fgOutput,State&state){
    float menuResScale=1;
    // ACTUAL_UI
}
bool contains(const char*text){for(const auto&s:ImGui::messages)if(s.find(text)!=std::string::npos)return true;return false;}
int main(){
    Config cfg;FG fg;State state;
    Draw(&cfg,&fg,state);assert(ImGui::comboLabel=="3X");
    ImGui::click="4X";Draw(&cfg,&fg,state);
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==3&&state.fgChanged);
    fg.active=3;state.fgChanged=false;
    ImGui::click="Custom...";Draw(&cfg,&fg,state);
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==4&&!state.fgChanged);
    ImGui::messages.clear();Draw(&cfg,&fg,state);
    assert(ImGui::comboLabel=="5X (restart)"&&contains("currently 4X"));
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==4&&!state.fgChanged);
    ImGui::typed=6;Draw(&cfg,&fg,state);Draw(&cfg,&fg,state);
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==5&&!state.fgChanged);
    assert(ImGui::comboLabel=="6X (restart)"); // actual active 4X must not overwrite queued 6X
    ImGui::click="3X";Draw(&cfg,&fg,state);
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==2&&state.fgChanged);
    fg.active=2;state.fgChanged=false;ImGui::click="Auto";Draw(&cfg,&fg,state);
    assert(!cfg.FGXeFGInterpolationCount.has_value()&&state.fgChanged);
    ImGui::messages.clear();Draw(&cfg,&fg,state);
    assert(ImGui::comboLabel=="Auto (3X)"&&contains("full 6X range"));
    cfg.FGXeFGInterpolationCount=5;fg.capacity=5;fg.active=5;state.fgChanged=false;
    Draw(&cfg,&fg,state);assert(ImGui::comboLabel=="6X (custom)");
    XeFGProxy::dynamic=false;cfg.FGXeFGInterpolationCount=2;fg.active=2;fg.capacity=2;
    state.fgChanged=false;ImGui::click="4X";Draw(&cfg,&fg,state);
    assert(cfg.FGXeFGInterpolationCount.value_or_default()==3&&!state.fgChanged);
    ImGui::messages.clear();Draw(&cfg,&fg,state);
    assert(contains("currently 3X")); // legacy SDK cannot switch count without recreation
    std::cout<<"PASS: actual UI; selected versus active counts, 3X/4X changes, pending 5X/6X persistence and Auto warning\n";
}
'''


READBACK = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#define DONT_USE_XMX 1
#define LOG_INFO(...) ((void)0)
#define LOG_WARN(...) ((void)0)
constexpr int XEFG_SWAPCHAIN_RESULT_SUCCESS=0;
struct xefg_swapchain_d3d12_init_params_t{uint32_t maxInterpolatedFrames=0;};
struct xefg_swapchain_properties_t{uint64_t tempBufferHeapSize=0,tempTextureHeapSize=0,constantBufferSize=0;
    uint32_t maxSupportedInterpolations=0;};
struct Option{int value_or_default(){return 2;}bool has_value(){return true;}};
struct Config{Option FGXeFGInterpolationCount,FGXeFGLowMemoryMode;static Config*Instance(){static Config c;return &c;}};
namespace XeFGDiagnostics {
int capacity=-1,active=-1,activeWrites=0,heapWrites=0;
void RecordInterpolationCapacity(uint32_t n,int,bool){capacity=n;}
void RecordInterpolationActive(uint32_t n){active=n;++activeWrites;}
void RecordHeapRequirements(uint64_t,uint64_t,uint64_t){++heapWrites;}
}
namespace XeFGProxy {
bool available=true,dynamic=true;int result=0;uint32_t returned=3;
int Read(void*,xefg_swapchain_d3d12_init_params_t*out){out->maxInterpolatedFrames=returned;return result;}
auto D3D12GetInitializationParameters()->int(*)(void*,xefg_swapchain_d3d12_init_params_t*){return available?Read:nullptr;}
void* SetNumInterpolatedFrames(){return dynamic?reinterpret_cast<void*>(1):nullptr;}
int Properties(void*,xefg_swapchain_properties_t*){return 0;}
auto GetProperties(){return Properties;}
}
struct XeFG_Dx12 {
    int _maxInterpolationCount=5,_lastCapacityRequest=5,_framesToInterpolate=2;
    std::atomic<int>_initializedInterpolationCapacity{0};void*_swapChainContext=this;
    void RecordInitializedCapacity(const xefg_swapchain_d3d12_init_params_t&);
};
// ACTUAL_READBACK
int main(){
    XeFG_Dx12 f;xefg_swapchain_d3d12_init_params_t params{3};
    f.RecordInitializedCapacity(params);
    assert(f._initializedInterpolationCapacity==3&&f._lastCapacityRequest==-1);
    assert(f._framesToInterpolate==-1&&XeFGDiagnostics::activeWrites==0); // new context must receive SetNum
    assert(XeFGDiagnostics::capacity==3&&XeFGDiagnostics::heapWrites==1);
    XeFGProxy::returned=5;f.RecordInitializedCapacity(params);
    assert(f._initializedInterpolationCapacity==5&&XeFGDiagnostics::capacity==5); // SDK override wins
    XeFGProxy::returned=1;f.RecordInitializedCapacity(params);
    assert(f._initializedInterpolationCapacity==1); // never use requested 4X above real 2X capacity
    for(auto invalid:{0u,6u,0xffffffffu}){XeFGProxy::returned=invalid;f.RecordInitializedCapacity(params);
        assert(f._initializedInterpolationCapacity==3);}
    XeFGProxy::returned=5;XeFGProxy::result=-1;f.RecordInitializedCapacity(params);
    assert(f._initializedInterpolationCapacity==3);
    XeFGProxy::available=false;f.RecordInitializedCapacity(params);assert(f._initializedInterpolationCapacity==3);
    XeFGProxy::dynamic=false;f.RecordInitializedCapacity(params);
    assert(f._framesToInterpolate==3&&XeFGDiagnostics::active==3&&XeFGDiagnostics::activeWrites==1);
    std::cout<<"PASS: actual initialization readback; requested versus effective capacity, stale count reset, missing API and legacy\n";
}
'''


PATCH_MAIN = r'''
int32_t readImm(const std::vector<uint8_t>& bytes, size_t offset) {
    int32_t value;memcpy(&value, bytes.data()+offset, sizeof(value));return value;
}
int main(int argc,char**argv) {
    const std::string mode=argv[1];auto bytes=image();const auto original=bytes;
    int capacity=3,reported=5;
    if(mode=="full")capacity=5;
    if(mode=="default")capacity=0;
    if(mode=="invalid_negative")capacity=-1;
    if(mode=="invalid_high")capacity=6;
    if(mode=="lower_sdk")reported=3;
    Config::Instance()->FGXeFGMaxInterpolatedFrames.value=reported;
    if(mode=="u4_write_failure")failRequest=4;
    if(mode=="u4_corruption")corruptFlush=4;
    if(mode=="pacing_failure")failRequest=7;
    assert(!XeFGUnlock::Applied());
    assert(XeFGUnlock::InitialCapacityOverride()==0&&XeFGUnlock::InterpolationLimit()==0);
    const bool ok=XeFGUnlock::Apply(bytes.data(),capacity);
    if(mode=="u4_write_failure"||mode=="u4_corruption"||mode=="pacing_failure") {
        assert(!ok&&bytes==original&&!XeFGUnlock::Applied());
        assert(XeFGUnlock::InitialCapacityOverride()==0&&XeFGUnlock::InterpolationLimit()==0);
        assert(!XeFGPacing::g_enabled);
    } else {
        const int expected=capacity>=1&&capacity<=reported?capacity:reported;
        assert(ok&&XeFGUnlock::Applied()&&XeFGPacing::g_enabled);
        assert(readImm(bytes,0x1a517e)==reported); // U3 remains support ceiling
        assert(readImm(bytes,0x1a45c8)==expected); // U4 actual SDK allocation override
        assert(readImm(bytes,0x20973c)==reported); // U5 remains reported ceiling
        assert(XeFGUnlock::InterpolationLimit()==reported);
        assert(XeFGUnlock::InitialCapacityOverride()==expected);
        const auto initialized=bytes;
        const auto writes=writeRequests;
        assert(XeFGUnlock::Apply(bytes.data(),5)); // changing config cannot hot-patch live SDK
        assert(bytes==initialized&&writeRequests==writes);
        assert(XeFGUnlock::InitialCapacityOverride()==expected);
    }
    std::cout<<"PASS: production DLL capacity patch "<<mode<<"\n";
}
'''


def patch_test(source):
    # Reuse only the mature Windows/PE fixtures. Compile this revision's complete
    # production patcher; no replacement implementation or expected-state model.
    fixture_tree = ast.parse((HERE.parent / "unlock/run.py").read_text(encoding="utf-8"))
    fixtures = {}
    for node in ast.walk(fixture_tree):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "write_text" and isinstance(node.func.value, ast.BinOp)
                and isinstance(node.func.value.right, ast.Constant)):
            fixtures[node.func.value.right.value] = ast.literal_eval(node.args[0])
    with tempfile.TemporaryDirectory(prefix="r8-dll-capacity-") as folder:
        temporary = Path(folder)
        for filename in ("XeFGUnlock.h", "XeLLUnLock.h", "XeFGPacing.h", "XeFGPacingGuard.h"):
            shutil.copy2(source / "OptiScaler/proxies" / filename, temporary / filename)
        for filename in ("Logger.h", "Config.h", "SysUtils.h"):
            (temporary / filename).write_text(fixtures[filename], encoding="utf-8")
        if os.name != "nt":
            (temporary / "intrin.h").write_text(fixtures["intrin.h"], encoding="utf-8")
        cpp = temporary / "test.cpp"
        cpp.write_text(fixtures["test.cpp"].split("int main(", 1)[0] + PATCH_MAIN, encoding="utf-8")
        binary = temporary / ("test.exe" if os.name == "nt" else "test")
        if os.name == "nt":
            command = ["cl", "/nologo", "/std:c++20", "/EHsc", "/UNDEBUG", "/I" + str(temporary),
                       "/I" + str(source / "OptiScaler"), str(cpp), "/Fe:" + str(binary)]
        else:
            command = [os.environ.get("CXX", "g++"), "-std=c++20", "-fpermissive", "-w", "-O0", "-UNDEBUG",
                       "-I", str(temporary), "-I", str(source / "OptiScaler"), str(cpp), "-o", str(binary)]
        subprocess.run(command, cwd=temporary, check=True)
        for mode in ("low_memory", "full", "default", "invalid_negative", "invalid_high", "lower_sdk",
                     "u4_write_failure", "u4_corruption", "pacing_failure"):
            subprocess.run([str(binary), mode], cwd=temporary, timeout=30, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    source = parser.parse_args().source.resolve()
    helpers.compile_and_run(source, POLICY, "R8 actual capacity policy")
    backend = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8")
    guard = helpers.extract_function(backend, "if (XeFGProxy::SetNumInterpolatedFrames() != nullptr)")
    helpers.compile_and_run(source, RUNTIME.replace("// ACTUAL_RUNTIME_GUARD", guard),
                            "R8 actual runtime SDK capacity guard")
    readback = helpers.extract_function(backend, "void XeFG_Dx12::RecordInitializedCapacity(")
    helpers.compile_and_run(source, READBACK.replace("// ACTUAL_READBACK", readback),
                            "R8 actual initialization readback")
    menu = (source / "OptiScaler/menu/menu_common.cpp").read_text(encoding="utf-8")
    start = menu.rindex("        auto maxInterpolationCount =", 0,
                        menu.index("const int initializedCapacity = fgOutput->GetInitializedInterpolationCapacity();"))
    end = menu.index("        ImGui::BeginDisabled(!fgOutput->IsUsingHudlessAny()", start)
    helpers.compile_and_run(source, UI.replace("// ACTUAL_UI", menu[start:end]),
                            "R8 actual multiplier selection UI")
    patch_test(source)


if __name__ == "__main__":
    main()
