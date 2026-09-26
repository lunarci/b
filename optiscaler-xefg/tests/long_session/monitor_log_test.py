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
           "XeFGPresentDiagnostics", "GpuAllocationDiagnostics", "ResidencyDiagnostics"]
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
actual = helpers.extract_function(monitor, "struct Sample") + ";\nclass Monitor { public: LogBudget _logBudget;\n"
actual += "\n".join(helpers.extract_function(monitor, signature) for signature in
                    ["bool BeginLogEntry()", "void Log(const Sample& sample, bool changed)",
                     "void LogProvider(std::uint64_t elapsedMs)", "void LogAllocations(std::uint64_t elapsedMs)"])
tests = r'''
}; }
int main() {
    LongSession::Monitor monitor; LongSession::Sample sample;
    sample.localValid=sample.processValid=sample.physicalValid=true;
    sample.localUsage=32*1024*1024;sample.localBudget=16*1024*1024;
    sample.processWorkingSetBytes=1024*1024;
    sample.processCommitLimitBytes=100*1024*1024;sample.processAvailableCommitBytes=30*1024*1024;
    sample.waitCalls[static_cast<unsigned>(LongSession::WaitStage::ProviderStatus)]=7;
    { XeFGDiagnostics::PresentObservation observation; assert(observation.Record(0,true,0,3,0,true)); }
    monitor.Log(sample,false);
    assert(lines.size()==4);
    assert(lines[0].find("local_headroom_MiB=-16.0")!=std::string::npos);
    assert(lines[0].find("process_commit_limit_available_MiB=100.0/30.0")!=std::string::npos);
    assert(lines[0].find("provider_status_calls=7")!=std::string::npos);
    assert(lines[1].find("sdk_queued_frames_total=3")!=std::string::npos);
    assert(lines[1].find("scope=process_cumulative")!=std::string::npos);
    assert(lines[3].find("scope=partial_created_ge1MiB_not_residency")!=std::string::npos);
    for(unsigned i=0;i<1100;++i) monitor.Log(sample,false);
    assert(lines.size()==LongSession::LogBudget::MaximumEntries);
    assert(lines.back().find("Log entry limit reached")!=std::string::npos);
    std::cout<<"PASS: actual monitor formats, signed headroom, diagnostic scopes and total 1024-line cap\n";
}
'''
helpers.compile_and_run(source, prefix + harness + actual + tests, "actual monitor bounded diagnostic logging")
