#!/usr/bin/env python3
"""Compile the production heap-create hook and HeapInfo constructor with D3D12 stubs.

The concurrency check blocks actual ResourceInfo array construction and verifies
that an existing heap can still be read. No GPU or timing benchmark is simulated.
Pass --source <baseline cpp> --expect-blocked to prove the regression check fails
for the original lock scope while the functional checks still pass.
"""
import argparse
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('source_root', type=pathlib.Path)
p.add_argument('--source', type=pathlib.Path)
p.add_argument('--header', type=pathlib.Path)
p.add_argument('--expect-blocked', action='store_true')
a = p.parse_args()
if a.source is None:
    a.source = a.source_root / 'OptiScaler/resource_tracking/ResTrack_dx12.cpp'
if a.header is None:
    a.header = a.source.with_suffix('.h')
    if not a.header.is_file():
        raise FileNotFoundError(a.header)
source = a.source.read_text()
header = a.header.read_text()

def extract(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

hook = extract(source, 'HRESULT ResTrack_Dx12::hkCreateDescriptorHeap(')
ctor = extract(header, '    HeapInfo(ID3D12DescriptorHeap* heap,')
# Exact production statements are tested, not a rewritten publication algorithm.
if not a.expect_blocked:
    assert hook.count('std::make_shared<HeapInfo>') == 1
    assert hook.index('std::make_shared<HeapInfo>') < hook.index('std::unique_lock lock(_heapRegistryMutex)')
assert hook.count('gHeapGeneration.fetch_add(1, std::memory_order_release)') == 2
assert 'DeactivateAndClear' not in hook

preamble = r'''
#include <misc/LongSessionTiming.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <iostream>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>
#include <stdexcept>
#include <thread>
#include <vector>
using namespace std::chrono_literals;
using UINT = unsigned;
using SIZE_T = std::size_t;
using HRESULT = int;
using ULONG = unsigned long;
using PVOID = void*;
using REFIID = int;
constexpr HRESULT S_OK = 0;
constexpr int NO_ERROR = 0;
template<class... Args> void TestLog(Args&&...) {}
#define LOG_TRACE(...) TestLog(__VA_ARGS__)
#define LOG_DEBUG(...) TestLog(__VA_ARGS__)
#define LOG_ERROR(...) TestLog(__VA_ARGS__)
enum D3D12_DESCRIPTOR_HEAP_TYPE { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
                                D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
                                D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER };
struct D3D12_DESCRIPTOR_HEAP_DESC { D3D12_DESCRIPTOR_HEAP_TYPE Type; UINT NumDescriptors; };
struct Handle { SIZE_T ptr; };
struct ID3D12DescriptorHeap
{
    SIZE_T cpu = 0;
    SIZE_T gpu = 0;
    Handle GetCPUDescriptorHandleForHeapStart() { return {cpu}; }
    Handle GetGPUDescriptorHandleForHeapStart() { return {gpu}; }
};
struct ID3D12Device { UINT GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE) { return 32; } };
struct State
{
    bool skipHeapCapture = false;
    static State& Instance() { static State state; return state; }
};
static ULONG hkHeapRelease(ID3D12DescriptorHeap*) { return 1; }
using PFN_HeapRelease = ULONG(*)(ID3D12DescriptorHeap*);
static PFN_HeapRelease o_HeapRelease = hkHeapRelease;
static void DetourTransactionBegin() {}
static void DetourUpdateThread(int) {}
static int GetCurrentThread() { return 0; }
static void DetourAttach(PVOID*, PFN_HeapRelease) {}
static int DetourTransactionCommit() { return NO_ERROR; }
static HRESULT nativeResult = S_OK;
static ID3D12DescriptorHeap* nativeHeap = nullptr;
static unsigned nativeCalls = 0;
static HRESULT o_CreateDescriptorHeap(ID3D12Device*, D3D12_DESCRIPTOR_HEAP_DESC*, REFIID, void** out)
{
    ++nativeCalls;
    *out = nativeResult == S_OK ? nativeHeap : nullptr;
    return nativeResult;
}
struct ConstructionGate
{
    std::atomic<bool> blockNext { false };
    std::atomic<bool> failNext { false };
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool proceed = false;
} gate;
struct ResourceInfo
{
    void* buffer = reinterpret_cast<void*>(1);
    ResourceInfo()
    {
        if (gate.failNext.exchange(false))
            throw std::bad_alloc();
        if (gate.blockNext.exchange(false))
        {
            std::unique_lock lock(gate.mutex);
            gate.entered = true;
            gate.cv.notify_all();
            gate.cv.wait(lock, [] { return gate.proceed; });
        }
    }
};
struct HeapInfo
{
    ID3D12DescriptorHeap* heap;
    SIZE_T cpuStart, cpuEnd, gpuStart, gpuEnd;
    UINT numDescriptors, increment, type;
    std::shared_ptr<ResourceInfo[]> info;
    std::atomic<bool> active { true };
    std::atomic<uint64_t> version { 0 };
'''
tail = r'''
};
static std::shared_mutex _heapRegistryMutex;
static std::vector<std::shared_ptr<HeapInfo>> fgHeaps;
static std::atomic<unsigned> gHeapGeneration { 1 };
struct ResTrack_Dx12
{
    static HRESULT hkCreateDescriptorHeap(ID3D12Device*, D3D12_DESCRIPTOR_HEAP_DESC*, REFIID, void**);
};
'''
tests = r'''
static void require(bool value, const char* name)
{
    if (!value) throw std::runtime_error(name);
}
static void reset()
{
    fgHeaps.clear();
    fgHeaps.shrink_to_fit();
    gHeapGeneration = 1;
    nativeResult = S_OK;
    State::Instance().skipHeapCapture = false;
}
static void create(ID3D12DescriptorHeap& heap, UINT count = 16,
                   D3D12_DESCRIPTOR_HEAP_TYPE type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)
{
    ID3D12Device device;
    D3D12_DESCRIPTOR_HEAP_DESC desc {type, count};
    nativeHeap = &heap;
    void* out = nullptr;
    require(ResTrack_Dx12::hkCreateDescriptorHeap(&device, &desc, 0, &out) == nativeResult, "HRESULT changed");
    require(out == (nativeResult == S_OK ? &heap : nullptr), "native output changed");
}
int main()
{
    try
    {
        reset();
        ID3D12DescriptorHeap first {0x1000, 0x100000};
        create(first, 65536);
        require(fgHeaps.size() == 1 && fgHeaps[0]->heap == &first, "first heap missing");
        require(gHeapGeneration == 2, "append generation");
        require(fgHeaps.capacity() >= 65536, "registry reserve changed");
        for (UINT i = 0; i < fgHeaps[0]->numDescriptors; ++i)
            require(fgHeaps[0]->info[i].buffer == nullptr, "published before initialization");
        std::cout << "PASS append and complete large metadata initialization\n";

        auto stale = fgHeaps[0];
        stale->active = false;
        ID3D12DescriptorHeap replacement {0x1000, 0x100000};
        create(replacement);
        require(fgHeaps.size() == 1 && fgHeaps[0]->heap == &replacement, "inactive slot not reused");
        require(gHeapGeneration == 3 && !stale->active, "reuse generation or old lifetime changed");
        require(stale->version != fgHeaps[0]->version, "stale version collision");
        std::cout << "PASS inactive reuse and stale shared-owner/version isolation\n";

        ID3D12DescriptorHeap second {0x2000, 0x200000};
        create(second, 8, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        require(fgHeaps.size() == 2 && fgHeaps[0]->heap == &replacement, "active entry overwritten");
        require(gHeapGeneration == 4, "second append generation");
        std::cout << "PASS active entries retained and RTV captured\n";

        State::Instance().skipHeapCapture = true;
        create(second);
        State::Instance().skipHeapCapture = false;
        create(second, 8, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
        nativeResult = -1;
        create(second);
        nativeResult = S_OK;
        require(fgHeaps.size() == 2 && gHeapGeneration == 4, "skip/failure published");
        std::cout << "PASS capture bypass, untracked type and native failure\n";

        gate.failNext = true;
        bool allocationFailed = false;
        try { create(second); } catch (const std::bad_alloc&) { allocationFailed = true; }
        require(allocationFailed, "metadata failure swallowed");
        require(fgHeaps.size() == 2 && gHeapGeneration == 4, "failed allocation changed registry");
        // Failure must not leak the exclusive registry lock.
        { std::shared_lock lock(_heapRegistryMutex); }
        std::cout << "PASS metadata allocation failure leaves publication unchanged\n";

        gate.entered = false;
        gate.proceed = false;
        gate.blockNext = true;
        ID3D12DescriptorHeap third {0x3000, 0x300000};
        auto creator = std::async(std::launch::async, [&] { create(third, 65536); });
        {
            std::unique_lock lock(gate.mutex);
            if (!gate.cv.wait_for(lock, 2s, [] { return gate.entered; }))
                throw std::runtime_error("constructor gate not reached");
        }
        auto reader = std::async(std::launch::async, [&]
        {
            std::shared_lock lock(_heapRegistryMutex);
            return fgHeaps.size() == 2 && fgHeaps[0]->heap == &replacement && gHeapGeneration == 4;
        });
        const bool readerProgressed = reader.wait_for(200ms) == std::future_status::ready;
        [[maybe_unused]] const bool correctlyUnpublished = readerProgressed ? reader.get() : false;
        {
            std::lock_guard lock(gate.mutex);
            gate.proceed = true;
            gate.cv.notify_all();
        }
        creator.get();
        if (!readerProgressed) reader.get();
#ifdef EXPECT_BLOCKED
        require(!readerProgressed, "baseline did not reproduce registry stall");
        std::cout << "PASS baseline reproduces reader stall during metadata construction\n";
#else
        require(readerProgressed && correctlyUnpublished, "metadata construction blocked existing lookup");
        std::cout << "PASS existing lookup progresses while new metadata remains private\n";
#endif
        require(fgHeaps.size() == 3 && fgHeaps[2]->heap == &third && gHeapGeneration == 5,
                "post-construction publication changed");
        std::cout << "PASS completed concurrent construction publishes once\n";
        return 0;
    }
    catch (const std::exception& e)
    {
        std::cerr << "FAIL " << e.what() << '\n';
        return 1;
    }
}
'''
with tempfile.TemporaryDirectory(prefix='optiscaler-heap-publication-') as tmp:
    cpp = pathlib.Path(tmp) / 'test.cpp'
    binary = pathlib.Path(tmp) / ('test.exe' if os.name == 'nt' else 'test')
    cpp.write_text(preamble + ctor + tail + hook + tests)
    if os.name == 'nt':
        command = ['cl', '/nologo', '/std:c++20', '/EHsc', '/O2', '/I' + str(a.source_root / 'OptiScaler'), str(cpp), '/Fe:' + str(binary)]
    else:
        command = ['g++', '-std=c++20', '-O2', '-pthread', '-Wall', '-Wextra', '-Werror', '-I' + str(a.source_root / 'OptiScaler'), str(cpp), '-o', str(binary)]
    if a.expect_blocked:
        command.insert(1, '/DEXPECT_BLOCKED' if os.name == 'nt' else '-DEXPECT_BLOCKED')
    subprocess.run(command, check=True, cwd=tmp)
    subprocess.run([str(binary)], check=True, timeout=10)
