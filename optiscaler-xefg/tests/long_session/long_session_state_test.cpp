#include "LongSessionState.h"
#include "LongSessionTiming.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <limits>
#include <iostream>

int main()
{
    using namespace LongSession;
    PressureState pressure;
    assert(pressure.Update(89, 100) == Pressure::Normal);
    assert(pressure.Update(90, 100) == Pressure::Elevated);
    assert(pressure.Update(89, 100) == Pressure::Elevated);
    assert(pressure.Update(95, 100) == Pressure::Critical);
    assert(pressure.Update(89, 100) == Pressure::Critical);
    assert(pressure.Update(89, 100) == Pressure::Critical);
    assert(pressure.Update(89, 100) == Pressure::Elevated);
    assert(pressure.Update(84, 100) == Pressure::Elevated);
    assert(pressure.Update(84, 100) == Pressure::Elevated);
    assert(pressure.Update(0, 0) == Pressure::Elevated); // Unknown must not count as recovery.
    assert(pressure.Update(84, 100) == Pressure::Elevated);
    assert(pressure.Update(84, 100) == Pressure::Elevated);
    assert(pressure.Update(84, 100) == Pressure::Normal);
    assert(pressure.Update(120, 100) == Pressure::Critical); // Over budget is a valid reading.
    assert(pressure.Update(0, 0) == Pressure::Critical);
    assert(pressure.Update(1, 100) == Pressure::Critical);
    assert(pressure.Update(1, 100) == Pressure::Critical);
    assert(pressure.Update(1, 100) == Pressure::Normal);
    assert(pressure.Update(std::numeric_limits<std::uint64_t>::max(),
                           std::numeric_limits<std::uint64_t>::max()) == Pressure::Critical);

    HitchState hitch;
    assert(!hitch.Update(16, 16));
    assert(hitch.Update(251, 16));
    assert(hitch.Update(16, 16));
    assert(hitch.Update(16, 16));
    assert(!hitch.Update(16, 16));
    assert(hitch.Update(16, 501));
    assert(hitch.Update(16, 16));
    assert(hitch.Update(251, 16)); // A new stall restarts the recovery streak.
    assert(hitch.Update(16, 16));
    assert(hitch.Update(16, 16));
    assert(!hitch.Update(16, 16));

    LogBudget logs;
    for (unsigned i = 1; i <= LogBudget::MaximumEntries; ++i)
    {
        assert(logs.Take());
        assert(logs.IsFinalEntry() == (i == LogBudget::MaximumEntries));
    }
    assert(!logs.Take());
    assert(!logs.Take());

    auto& pacing = WaitCounters()[static_cast<unsigned>(WaitStage::Pacing)].maximumUs;
    assert(pacing.load() == 0);
    RecordWait(WaitStage::Pacing, -1.0);
    RecordWait(WaitStage::Pacing, 0.0);
    RecordWait(WaitStage::Pacing, std::numeric_limits<double>::quiet_NaN());
    RecordWait(WaitStage::Pacing, std::numeric_limits<double>::infinity());
    RecordWait(WaitStage::Count, 5.0);
    assert(pacing.load() == 0);
    RecordWait(WaitStage::Pacing, 12.5);
    assert(pacing.load() == 12500);
    RecordWait(WaitStage::Pacing, 1.0);
    assert(pacing.load() == 12500);
    RecordWait(WaitStage::GpuFence, 30.0);
    assert(pacing.load() == 12500);
    assert(WaitCounters()[static_cast<unsigned>(WaitStage::GpuFence)].maximumUs.load() == 30000);
    assert(pacing.exchange(0) == 12500);
    RecordWait(WaitStage::Pacing, 2.0);
    assert(pacing.load() == 2000);
    RecordWait(WaitStage::Pacing, 1.0e100);
    assert(pacing.load() == 86400000000ULL);

    std::cout << "PASS: production memory/hitch hysteresis, log cap and bounded timing counters\n";
}
