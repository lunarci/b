#include "misc/XeFGResourceDiagnostics.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <thread>
#include <vector>

using namespace XeFGDiagnostics;

static void balancedOwnership()
{
    const auto initialGlobal = GlobalSnapshot();
    Context context;
    context.BeginContext();
    context.OnAllocate(65536);
    context.OnAllocate(131072);
    context.OnAllocate(0, false);
    auto sample = context.Read();
    assert(sample.contextId != 0);
    assert(sample.counters.liveCopies == 3 && sample.counters.peakCopies == 3);
    assert(sample.counters.liveBytes == 196608 && sample.counters.peakBytes == 196608);
    assert(sample.counters.unknownSizeCopies == 1);

    // Failed replacement retains the old allocation and changes no live counts.
    context.OnAllocationFailure();
    sample = context.Read();
    assert(sample.counters.allocationFailures == 1);
    assert(sample.counters.liveCopies == 3 && sample.counters.liveBytes == 196608);

    // A successful replacement allocates first, then releases the old owner.
    context.OnAllocate(262144);
    context.OnRelease(65536);
    sample = context.Read();
    assert(sample.counters.liveCopies == 3 && sample.counters.peakCopies == 4);
    assert(sample.counters.liveBytes == 393216 && sample.counters.peakBytes == 458752);

    const auto oldId = sample.contextId;
    context.BeginContext();
    sample = context.Read();
    assert(sample.contextId != oldId);
    assert(sample.startLiveCopies == 3 && sample.startLiveBytes == 393216);
    assert(sample.startUnknownSizeCopies == 1);
    assert(sample.counters.allocations == 0 && sample.counters.allocationFailures == 0);
    assert(sample.counters.liveCopies == 3 && sample.counters.liveBytes == 393216);

    context.OnRelease(131072);
    context.OnRelease(262144);
    context.OnRelease(0, false);
    sample = context.Read();
    assert(sample.counters.liveCopies == 0 && sample.counters.liveBytes == 0);
    assert(sample.counters.unknownSizeCopies == 0 && sample.counters.accountingErrors == 0);
    const auto afterGlobal = GlobalSnapshot();
    assert(afterGlobal.liveCopies == initialGlobal.liveCopies);
    assert(afterGlobal.liveBytes == initialGlobal.liveBytes);
    assert(afterGlobal.allocations - initialGlobal.allocations == 4);
    assert(afterGlobal.releases - initialGlobal.releases == 4);
    assert(afterGlobal.allocatedBytes - initialGlobal.allocatedBytes == 458752);
    assert(afterGlobal.releasedBytes - initialGlobal.releasedBytes == 458752);

    // An invalid release in one context must not subtract another context's live copy.
    Context other;
    other.BeginContext();
    other.OnAllocate(1234);
    context.OnRelease(65536);
    assert(context.Read().counters.accountingErrors == 1);
    assert(GlobalSnapshot().liveCopies == initialGlobal.liveCopies + 1);
    assert(GlobalSnapshot().liveBytes == initialGlobal.liveBytes + 1234);
    other.OnRelease(1234);
}

static void concurrentAccounting()
{
    Context context;
    context.BeginContext();
    const auto before = GlobalSnapshot();
    std::vector<std::thread> workers;
    for (unsigned worker = 0; worker < 8; ++worker)
        workers.emplace_back([&context] {
            for (unsigned iteration = 0; iteration < 1000; ++iteration)
            {
                context.OnAllocate(4096);
                context.OnAliasPreserved();
                context.OnRelease(4096);
            }
        });
    for (auto& worker : workers)
        worker.join();
    const auto sample = context.Read().counters;
    assert(sample.allocations == 8000 && sample.releases == 8000);
    assert(sample.aliasPreserved == 8000);
    assert(sample.liveCopies == 0 && sample.liveBytes == 0 && sample.accountingErrors == 0);
    assert(sample.allocatedBytes == 8000ULL * 4096 && sample.releasedBytes == sample.allocatedBytes);
    const auto after = GlobalSnapshot();
    assert(after.liveCopies == before.liveCopies && after.liveBytes == before.liveBytes);
}

static void inputBursts()
{
    Context context;
    context.BeginContext();
    context.OnMissingInputs(false, false);
    assert(context.Read().counters.missingFrames == 0);
    context.OnMissingInputs(true, false);
    context.OnMissingInputs(false, true);
    context.OnMissingInputs(true, true);
    auto sample = context.Read().counters;
    assert(sample.missingDepthOnly == 1 && sample.missingVelocityOnly == 1 && sample.missingBoth == 1);
    assert(sample.missingFrames == 3 && sample.missingBursts == 1);
    assert(sample.currentMissingBurst == 3 && sample.peakMissingBurst == 3);
    context.OnInputsReady();
    context.OnInputsReady();
    sample = context.Read().counters;
    assert(sample.recoveredBursts == 1 && sample.currentMissingBurst == 0);
    context.OnMissingInputs(true, true);
    sample = context.Read().counters;
    assert(sample.missingBursts == 2 && sample.currentMissingBurst == 1 && sample.peakMissingBurst == 3);
}

static void reportRateAndCap()
{
    ReportGate gate;
    assert(gate.Take(1000, false));
    assert(!gate.Take(5999, true));
    assert(gate.Take(6000, true));
    assert(!gate.Take(35999, false));
    assert(gate.Take(36000, false));
    assert(!gate.Take(1, true));

    Context context;
    context.BeginContext();
    Report report;
    unsigned reports = 0;
    if (context.TryReport(0, report)) ++reports; else assert(false);
    // 1000 missing frames produce one burst, not 1000 log entries.
    for (unsigned i = 1; i <= 1000; ++i)
    {
        context.OnMissingInputs(true, true);
        assert(!context.TryReport(i, report));
    }
    assert(context.TryReport(5000, report)); ++reports;
    assert(report.counters.missingFrames == 1000 && report.counters.missingBursts == 1);
    assert(!context.TryReport(10000, report));
    context.OnInputsReady();
    assert(context.TryReport(10000, report)); ++reports;
    assert(report.counters.recoveredBursts == 1);
    assert(!context.TryReport(39999, report));
    assert(context.TryReport(40000, report)); ++reports;

    // The lifetime cap must survive context generations and large time jumps.
    for (std::uint64_t index = 1; index <= 1500; ++index)
    {
        if (index % 2 == 0) context.BeginContext();
        if (context.TryReport(40000 + index * 30000, report)) ++reports;
    }
    assert(reports == 1024);
    assert(!context.TryReport(100000000, report));
}

int main()
{
    balancedOwnership();
    concurrentAccounting();
    inputBursts();
    reportRateAndCap();
    std::cout << "Production XeFG accounting, concurrency, missing-input bursts and log limits passed\n";
}
