#!/usr/bin/env python3
"""Compile the actual R3 wait and timestamp callbacks with a deterministic clock.

Run with the production source directory. --emit writes a translation unit
for the portable suite runner; no Windows/GPU dependencies or callback copies.
"""
from pathlib import Path
import os
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("source_dir", type=Path)
parser.add_argument("--emit", type=Path)
args = parser.parse_args()
root = args.source_dir.resolve()
source = (root / "OptiScaler/proxies/XeFGPacing.h").read_text(encoding="utf-8-sig")


def function(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    cursor = brace + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


cpp = r'''
#include "XeFGPacingGuard.h"
#include <misc/LongSessionTiming.h>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>
struct LARGE_INTEGER { int64_t QuadPart; };
std::vector<int64_t> clockValues;
size_t clockIndex = 0;
uint64_t g_measurementEpoch = 1;
std::atomic<uint64_t> g_requestedEpoch {1};
int sleepCalls = 0;
bool cancelOnYield = false;
bool QueryPerformanceCounter(LARGE_INTEGER* out) {
    if (clockIndex >= clockValues.size()) return false;
    out->QuadPart = clockValues[clockIndex++]; return true;
}
void Sleep(int) { ++sleepCalls; if (cancelOnYield) ++g_requestedEpoch; }
void YieldProcessor() { Sleep(0); }
int64_t QpcFromNs(int64_t ns) { return ns; }
int64_t g_periodNs = 30000000;
bool g_enabled = true, g_bypassDeadlineCorrection = false;
uint32_t g_lastTsIndex = 0, g_lastTsCountPlus1 = 0;
uint32_t g_guardDeadlineRejects = 0;
int g_sampleCount = 15;
int64_t g_tsCalls = 0, g_tsClamped = 0, g_tsRebased = 0;
int64_t g_nextDeadlineNs = 0, g_burstStepNs = 0;
uint8_t* g_ring = nullptr;
constexpr uint32_t RingMeasuredOffset = 0x1B8;
int guardReports = 0, nativeCalls = 0;
int64_t nativeDeadline = 1000000000;
void ReportGuard() { ++guardReports; }
void* NativeTimestamp(void*, int64_t* out, void*, void*, uint32_t, uint32_t) {
    ++nativeCalls; if (out) *out = nativeDeadline;
    return reinterpret_cast<void*>(uintptr_t{1234});
}
auto g_tsNative = &NativeTimestamp;
'''
cpp += function("inline bool WaitUntil(int64_t targetQpc)") + "\n"
cpp += function("inline void* TsDetour(") + "\n"
cpp += r'''
void ResetClock(std::vector<int64_t> values) {
    clockValues = values; clockIndex = 0; sleepCalls = 0;
    cancelOnYield = false; g_requestedEpoch = g_measurementEpoch;
}
void ResetTimestamp() {
    g_enabled = true; g_bypassDeadlineCorrection = false;
    g_lastTsIndex = 0; g_lastTsCountPlus1 = 0;
    g_nextDeadlineNs = 0; g_burstStepNs = 0;
    g_periodNs = 30000000; g_sampleCount = 15;
    g_requestedEpoch = g_measurementEpoch;
    nativeDeadline = 1000000000;
}
int main() {
    constexpr int64_t ms = 1000000;
    ResetClock({0, 2*ms, 5*ms});
    assert(WaitUntil(5*ms) && sleepCalls == 2);
    ResetClock({0, ms}); cancelOnYield = true;
    assert(!WaitUntil(5*ms) && sleepCalls == 1);
    ResetClock({5*ms, 4*ms});
    assert(!WaitUntil(6*ms));
    ResetClock({0});
    assert(!WaitUntil(1000*ms) && sleepCalls == 0);
    // Stable 1 FPS is not classified as corrupt timing.
    g_periodNs = 1000*ms;
    ResetClock({0, 500*ms});
    assert(WaitUntil(500*ms));
    ResetTimestamp();
    alignas(16) int64_t timing[4] {15, 30000000, 0, 0};
    int64_t out = 0;
    auto result = TsDetour(nullptr, &out, nullptr, timing, 1, 6);
    assert(result == reinterpret_cast<void*>(uintptr_t{1234}));
    assert(out == nativeDeadline);
    for (uint32_t i = 2; i <= 5; ++i) {
        TsDetour(nullptr, &out, nullptr, timing, i, 6);
        assert(out == nativeDeadline + (i - 1)*5000000);
    }
    // A lifecycle change during a burst preserves the provider's result.
    ++g_requestedEpoch;
    TsDetour(nullptr, &out, nullptr, timing, 5, 6);
    assert(out == nativeDeadline);
    ResetTimestamp(); timing[1] = 1000*ms;
    TsDetour(nullptr, &out, nullptr, timing, 1, 6);
    assert(out == nativeDeadline && g_bypassDeadlineCorrection);
    TsDetour(nullptr, &out, nullptr, timing, 2, 6);
    assert(out == nativeDeadline);
    ResetTimestamp(); timing[1] = 30*ms;
    nativeDeadline = (std::numeric_limits<int64_t>::max)() - 1;
    TsDetour(nullptr, &out, nullptr, timing, 1, 6);
    TsDetour(nullptr, &out, nullptr, timing, 2, 6);
    assert(out == nativeDeadline && g_bypassDeadlineCorrection);
    ResetTimestamp(); g_enabled = false;
    TsDetour(nullptr, &out, nullptr, timing, 5, 6);
    assert(out == nativeDeadline);
    assert(nativeCalls == 11);
    std::cout << "XeFG extracted callback tests passed\n";
}
'''

if args.emit:
    args.emit.write_text(cpp, encoding="utf-8")
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix="xefg-pacing-tests-") as temp:
    cpp_path = Path(temp) / "callbacks.cpp"
    cpp_path.write_text(cpp)
    executable = Path(temp) / "callbacks"
    subprocess.run([os.environ.get("CXX", "g++"), "-std=c++20", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=undefined", "-fno-sanitize-recover=all",
                    "-I", str(root / "OptiScaler/proxies"), "-I", str(root / "OptiScaler"), str(cpp_path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
