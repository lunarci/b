"""Compile the actual bounded monitor log bodies against their pure counters.

The full Windows build validates DXGI/PSAPI collection; this test validates the
real format argument types, counter integration, labels and total log cap.
"""
import importlib.util
from pathlib import Path
import sys

source = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("monitor_compile_helpers", here.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
monitor = (source / "OptiScaler/misc/LongSessionMonitor.h").read_text(encoding="utf-8-sig")
headers = ["LongSessionState", "LongSessionTiming", "XeFGResourceDiagnostics", "XeFGWorkDiagnostics",
           "XeFGPresentDiagnostics", "GpuAllocationDiagnostics", "ResidencyDiagnostics", "XeFGProgressDiagnostics"]
prefix = "\n".join('#include "misc/' + name + '.h"' for name in headers)
harness = r'''
#include <cassert>
#include <format>
#include <iostream>
#include <string>
#include <utility>
#include <vector>
static std::vector<std::string> lines;
template<class... T> void Capture(std::format_string<T...> text,T&&... args) {
    lines.push_back(std::format(text,std::forward<T>(args)...));
}
// Forward the entire argument list: works with MSVC legacy preprocessing
// and still instantiates Capture(std::format_string<...>) for format checks.
#define LOG_WARN(...) Capture(__VA_ARGS__)
namespace LongSession {
'''
actual = helpers.extract_function(monitor, "struct Sample") + ";\nclass Monitor { public: LogBudget _logBudget; bool _detailLogged=false; uint64_t _lastDetailLogMs=0;\n"
actual += "\n".join(helpers.extract_function(monitor, signature) for signature in
                    ["bool BeginLogEntry()", "void Log(const Sample& sample, bool changed)",
                     "void LogProvider(std::uint64_t elapsedMs)", "void LogAllocations(std::uint64_t elapsedMs)",
                     "void LogProgress(std::uint64_t elapsedMs)", "void LogAllocationDetails(std::uint64_t elapsedMs)",
                     "void LogAllocationGroup(std::uint64_t elapsedMs"])
tests = r'''
}; }
int main() {
    assert(GpuAllocationDiagnostics::PrepareDiagnostics());
    GpuAllocationDiagnostics::InitializeObservation(true);
    std::array<uint64_t,4> tokens{};
    for(unsigned i=0;i<4;++i) {
        GpuAllocationDiagnostics::AllocationMetadata meta;
        meta.moduleBase=0x1000;meta.callerRva=i+1;meta.createdMs=GpuAllocationDiagnostics::MonotonicMilliseconds();
        meta.descriptorKnown=true;meta.dimension=3;meta.width=1920;meta.height=1080;meta.format=28;
        tokens[i]=GpuAllocationDiagnostics::Instance()->Track(GpuAllocationDiagnostics::Caller::Game,
            GpuAllocationDiagnostics::Kind::Committed,GpuAllocationDiagnostics::MemoryClass::Default,
            (i+1)*1024*1024,meta);
        assert(tokens[i]);
    }
    XeFGProgress::Snapshot progress; progress.valid=true;progress.trackedQueues=1;
    progress.sampledAtMs=XeFGDiagnostics::WorkNowMs();progress.contextId=7;
    auto& queue=progress.queues[0];queue.tracked=true;queue.queueId=42;queue.queueType=0;
    queue.fenceReady=true;queue.signalCount=3;queue.completionCount=2;
    queue.pendingSinceMs=progress.sampledAtMs;queue.lastPollTickMs=progress.sampledAtMs;
    XeFGProgress::Publish(progress);
    XeFGProgress::RecordDeactivate(XeFGProgress::DeactivateReason::HudlessChanged,0);
    LongSession::Monitor monitor; LongSession::Sample sample;
    sample.localValid=sample.processValid=sample.physicalValid=true;
    sample.localUsage=32*1024*1024;sample.localBudget=16*1024*1024;
    sample.processWorkingSetBytes=1024*1024;
    sample.processCommitLimitBytes=100*1024*1024;sample.processAvailableCommitBytes=30*1024*1024;
    sample.waitCalls[static_cast<unsigned>(LongSession::WaitStage::ProviderStatus)]=7;
    sample.waitCalls[static_cast<unsigned>(LongSession::WaitStage::NativePresent)]=4;
    sample.waitSumMs[static_cast<unsigned>(LongSession::WaitStage::NativePresent)]=40;
    sample.captureEvent=LongSession::CaptureEvent::PressureEnter;
    sample.pressureEpoch=2;sample.pressureAgeMs=15000;
    sample.memoryWindow={3,1000,3000,10*1024*1024,32*1024*1024,16*1024*1024,16*1024*1024,22*1024*1024,0,1000,0};
    { XeFGDiagnostics::PresentObservation observation; assert(observation.Record(0,true,0,3,0,true)); }
    monitor.Log(sample,false);
    assert(lines.size()==8);
    assert(lines[0].find("local_headroom_MiB=-16.0")!=std::string::npos);
    assert(lines[0].find("process_commit_limit_available_MiB=100.0/30.0")!=std::string::npos);
    assert(lines[0].find("provider_status_calls=7")!=std::string::npos);
    assert(lines[1].find("sdk_queued_frames_total=3")!=std::string::npos);
    assert(lines[1].find("scope=process_cumulative")!=std::string::npos);
    assert(lines[3].find("scope=partial_created_ge1MiB_not_residency")!=std::string::npos);
    assert(lines[0].find("native_present_cpu_mean_sum_ms=10.00/40.00")!=std::string::npos);
    assert(lines[0].find("capture=pressure_enter pressure_epoch_age_ms=2/15000")!=std::string::npos);
    assert(lines[0].find("local_largest_observed_increase_decrease_MiB=22.0/0.0")!=std::string::npos);
    assert(lines[4].find("completion_scope=signal_to_first_cpu_poll_not_gpu_duration")!=std::string::npos);
    assert(lines[4].find("q0=42/0/true/false/3/2/")!=std::string::npos);
    assert(lines[4].find("disable_accepted=0/0/0/0/1/0/0")!=std::string::npos);
    assert(lines[5].find("largest_groups_available_shown=4/2")!=std::string::npos);
    assert(lines[6].find("module_base_rva=1000/4 live_MiB=4.00")!=std::string::npos);
    assert(lines[7].find("rank=2 ranking=live_bytes")!=std::string::npos);
    assert(lines[5].find("growth_baseline_valid=false")!=std::string::npos);
    sample.captureEvent=LongSession::CaptureEvent::NativeSlow;sample.elapsedMs=10000;
    monitor.Log(sample,false);assert(lines.size()==13); // No detail burst on every stall event.
    GpuAllocationDiagnostics::AllocationMetadata growing;
    growing.moduleBase=0x1000;growing.callerRva=1;growing.createdMs=GpuAllocationDiagnostics::MonotonicMilliseconds();
    growing.descriptorKnown=true;growing.dimension=3;growing.width=1920;growing.height=1080;growing.format=28;
    assert(GpuAllocationDiagnostics::Instance()->Track(GpuAllocationDiagnostics::Caller::Game,
        GpuAllocationDiagnostics::Kind::Committed,GpuAllocationDiagnostics::MemoryClass::Default,1024*1024,growing));
    sample.elapsedMs=30000;monitor.Log(sample,false);assert(lines.size()==22);
    assert(lines[18].find("growth_baseline_valid=true")!=std::string::npos);
    assert(lines[21].find("ranking=positive_live_growth")!=std::string::npos);
    assert(lines[21].find("module_base_rva=1000/1 live_MiB=2.00")!=std::string::npos);
    assert(lines[21].find("baseline_live_MiB=1.00 observed_positive_live_delta_MiB=1.00")!=std::string::npos);
    for(unsigned i=0;i<1100;++i) monitor.Log(sample,false);
    assert(lines.size()==LongSession::LogBudget::MaximumEntries);
    assert(lines.back().find("Log entry limit reached")!=std::string::npos);
    std::cout<<"PASS: actual monitor formats, signed headroom, diagnostic scopes and total 1024-line cap\n";
}
'''
helpers.compile_and_run(source, prefix + harness + actual + tests, "actual monitor bounded diagnostic logging")
