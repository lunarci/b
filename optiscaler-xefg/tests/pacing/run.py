#!/usr/bin/env python3
"""Compile the production pacing header and timing selection with Windows mocks."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("source_dir", type=Path)
args = parser.parse_args()
source = args.source_dir.resolve() / "OptiScaler"
cpp = (source / "framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8-sig")
start = cpp.index("    auto frameRenderTime = _ftDelta[fIndex];")
end = cpp.index("    // Report what the provider actually got", start)
selection = cpp[start:end]

with tempfile.TemporaryDirectory(prefix="xefg-pacing-") as directory:
    tmp = Path(directory)
    shutil.copy2(source / "proxies/XeFGPacing.h", tmp / "XeFGPacing.h")
    shutil.copy2(source / "proxies/XeFGPacingGuard.h", tmp / "XeFGPacingGuard.h")
    if os.name != "nt":
        (tmp / "intrin.h").write_text("#pragma once\ninline void* _ReturnAddress(){return nullptr;}\n")
    (tmp / "Logger.h").write_text(
        "#pragma once\n#define LOG_INFO(...) ((void)0)\n#define LOG_WARN(...) ((void)0)\n"
        "#define LOG_ERROR(...) ((void)0)\n")
    (tmp / "Config.h").write_text(r'''#pragma once
enum class FrameTimeSource { Input, Opti, Zero };
template<class T> struct Opt { T value; T value_or_default() const { return value; } };
struct Config {
    Opt<bool> FGXeFGExtraPacing {true};
    Opt<FrameTimeSource> FTInput {FrameTimeSource::Input};
    static Config* Instance() { static Config config; return &config; }
};
''')
    (tmp / "SysUtils.h").write_text(r'''#pragma once
#include <cstdint>
#include <cstring>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <thread>
using DWORD = uint32_t;
struct LARGE_INTEGER { int64_t QuadPart; };
constexpr DWORD PAGE_EXECUTE_READWRITE = 0x40;
inline int64_t mockClock = 100000;
inline bool VirtualProtect(void*, size_t, DWORD, DWORD* old) { *old=0x20; return true; }
inline bool FlushInstructionCache(void*, void*, size_t) { return true; }
inline void* GetCurrentProcess() { return nullptr; }
inline void QueryPerformanceFrequency(LARGE_INTEGER* out) { out->QuadPart=1000000; }
inline bool QueryPerformanceCounter(LARGE_INTEGER* out) { out->QuadPart=mockClock; mockClock+=100; return true; }
inline void Sleep(int) {} inline void YieldProcessor() {}
''')
    test = r'''#include "XeFGPacing.h"
using namespace XeFGPacing;
bool NativeSchedule(void*,void*,uint8_t,void*,uint32_t) { return true; }
void* NativeTimestamp(void*,int64_t* out,void*,void*,uint32_t,uint32_t) {
    *out=1000; return reinterpret_cast<void*>(0x1234);
}
double SelectTime(double input, double opti, FrameTimeSource mode=FrameTimeSource::Input) {
    double _ftDelta[] {input}; const int fIndex=0;
    struct { double lastFGFrameTime; } state {opti};
    struct { float frameRenderTime=0; } constData;
    Config::Instance()->FTInput.value=mode;
__SELECTION__
    return constData.frameRenderTime;
}
void ConsumeOnProviderThread() { SchedForwarder(nullptr,nullptr,0,nullptr,1); }
void LearnPeriod(int64_t periodUs=12000) {
    NoteFrame(1,2,100000);
    NoteFrame(1,2,100000+periodUs);
}
void Reset() { RequestReset(); ConsumeOnProviderThread(); }
int main() {
    QueryPerformanceFrequency(&g_freq);
    g_enabled=true; g_schedNative=&NativeSchedule; g_tsNative=&NativeTimestamp;
    Reset(); LearnPeriod(10000);
    assert(RenderTimeMs()==10.0);
    // Execute the production frame-time selection, including explicit overrides.
    assert(SelectTime(16,25)==16);
    assert(SelectTime(0,25)==10);
    assert(SelectTime(-1,25)==10);
    assert(SelectTime(std::numeric_limits<double>::quiet_NaN(),25)==10);
    assert(SelectTime(16,25,FrameTimeSource::Opti)==25);
    assert(SelectTime(16,25,FrameTimeSource::Zero)==0);
    g_nextDeadlineNs=999999; g_targetQpc=888888;
    uint8_t oldRing[0x200] {}; g_ring=oldRing;
    const auto oldSampleCount=g_sampleCount;
    const auto oldEpoch=g_measurementEpoch;
    RequestReset(); RequestReset();
    // Requests invalidate the cross-thread estimate without mutating owner state.
    assert(RenderTimeMs()==0 && SelectTime(0,25)==25);
    assert(g_measurementEpoch==oldEpoch && g_sampleCount==oldSampleCount);
    assert(g_nextDeadlineNs==999999 && g_targetQpc==888888 && g_ring==oldRing);
    ConsumeOnProviderThread();
    assert(g_measurementEpoch==g_requestedEpoch.load());
    assert(g_periodNs==0 && g_sampleCount==0 && g_intervalQpc==0);
    assert(g_nextDeadlineNs==0 && g_targetQpc==0 && g_ring==nullptr);
    // The map's long pause must never become the first new timing sample.
    NoteFrame(1,2,9000000);
    assert(g_sampleCount==0 && RenderTimeMs()==0);
    NoteFrame(1,2,9012000);
    assert(g_sampleCount==1 && RenderTimeMs()==12);
    ConsumeOnProviderThread();
    assert(g_sampleCount==1); // No new request: do not repeatedly reset learning.
    std::cout << "timing selection and lifecycle epoch: PASS\n";

    // Start each multiplier from a fresh burst; keep all 3X..6X deadline steps.
    for(uint32_t count=2;count<=5;++count) {
        Reset();
        alignas(16) int64_t timing[] {15,24000000};
        int64_t out=0;
        TsDetour(nullptr,&out,nullptr,timing,2,count+1);
        assert(out==1000 && g_lastTsIndex==0); // Partial burst: no stale anchor.
        for(uint32_t index=1;index<=count;++index) {
            auto result=TsDetour(nullptr,&out,nullptr,timing,index,count+1);
            assert(result==reinterpret_cast<void*>(0x1234));
            assert(out==1000+int64_t(index-1)*(24000000/(count+1)));
        }
        RequestReset(); ConsumeOnProviderThread();
        TsDetour(nullptr,&out,nullptr,timing,count,count+1);
        assert(out==1000 && g_lastTsIndex==0);
    }
    std::cout << "3X-6X deadline sequences and partial-burst resets: PASS\n";

    // Exercise actual TryPace/PaceFrame with a deterministic clock and disabled
    // native scheduler/limiter; count 5 must still pace all five generated frames.
    for(uint64_t count=1;count<=5;++count) {
        Reset(); mockClock=1000000;
        for(int n=0;n<15;++n) PushPeriod(12000000);
        g_lastBurstQpc=mockClock-12000;
        uint8_t ctx[0x400] {}; alignas(16) uint8_t burst[0x100] {};
        uint8_t frames[8*6] {}; auto* framePtr=frames;
        memcpy(burst,&framePtr,sizeof(framePtr)); memcpy(burst+8,&count,sizeof(count));
        const auto begin=mockClock;
        for(uint64_t index=1;index<=count;++index)
            TryPace(ctx,burst+0x38,frames+index*8,index==count?0:1,index==count);
        if(count==1) assert(g_pacedFrames==0);
        else {
            assert(g_pacedFrames==int64_t(count));
            assert(mockClock-begin>=int64_t(12000*count/(count+1)));
        }
    }
    std::cout << "2X bypass and 3X-6X wall-clock pacing: PASS\n";

    // Only atomic requests/reads occur off the provider thread. Multiple
    // requests may coalesce, but the final request must never be lost.
    Reset();
    std::thread requester([] {
        for(int i=0;i<20000;++i) {
            RequestReset();
            assert(RenderTimeMs()>=0);
            NoteFedFrameTime(16.0);
        }
    });
    for(int i=0;i<20000;++i) {
        ConsumeOnProviderThread();
        NoteFrame(1,2,1000000+int64_t(i)*12000);
    }
    requester.join();
    RequestReset();
    assert(RenderTimeMs()==0);
    ConsumeOnProviderThread();
    assert(g_measurementEpoch==g_requestedEpoch.load() && g_sampleCount==0);
    std::cout << "concurrent reset requests/publication: PASS\n";
}
'''.replace("__SELECTION__", selection)
    (tmp / "test.cpp").write_text(test, encoding="utf-8")
    binary = tmp / ("test.exe" if os.name == "nt" else "test")
    if os.name == "nt":
        command = ["cl", "/nologo", "/std:c++20", "/EHsc", "/I" + str(tmp), "/I" + str(source),
                   str(tmp / "test.cpp"), "/Fe:" + str(binary)]
    else:
        command = ["g++", "-std=c++20", "-fpermissive", "-w", "-O0", "-pthread",
                   "-I", str(tmp), "-I", str(source), str(tmp / "test.cpp"), "-o", str(binary)]
    subprocess.run(command, cwd=tmp, check=True)
    subprocess.run([str(binary)], check=True)
print("Scope: production pacing code with deterministic CPU mocks; no GPU/game performance claim.")
