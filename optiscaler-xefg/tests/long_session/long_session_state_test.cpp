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
    assert(WaitCounters()[static_cast<unsigned>(WaitStage::Pacing)].totalUs.load() == 86400015500ULL);
    unsigned selected = 0;
    auto& probe = WaitCounters()[static_cast<unsigned>(WaitStage::TrackedReleaseProbe)];
    for (unsigned i = 0; i < 128; ++i)
    {
        const bool timed = ShouldSampleWait(WaitStage::TrackedReleaseMutex);
        selected += timed ? 1 : 0;
        SampledWaitScope scope(WaitStage::TrackedReleaseProbe, timed);
    }
    assert(selected == 2 && probe.calls == 2);
    assert(!ShouldSampleWait(WaitStage::Count));

    constexpr std::uint64_t mib = 1024 * 1024;
    MemoryWindow window;
    window.Observe(1000, true, 1000 * mib, 2000 * mib);
    window.Observe(2000, true, 1800 * mib, 1900 * mib);
    window.Observe(6000, true, 900 * mib, 2000 * mib);
    auto memory = window.Snapshot();
    assert(memory.samples == 3 && memory.firstTickMs == 1000 && memory.lastTickMs == 6000);
    assert(memory.usageMin == 900 * mib && memory.usageMax == 1800 * mib);
    assert(memory.budgetMin == 1900 * mib && memory.budgetMax == 2000 * mib);
    assert(memory.observedIncrease == 800 * mib && memory.increaseIntervalMs == 1000);
    assert(memory.observedDecrease == 900 * mib && memory.decreaseIntervalMs == 4000);
    window.ResetWindow();
    window.Observe(7000, true, 800 * mib, 2000 * mib);
    assert(window.Snapshot().samples == 1 && window.Snapshot().observedDecrease == 100 * mib);
    window.Observe(8000, false, 0, 0);
    window.Observe(9000, true, 1600 * mib, 2000 * mib);
    assert(window.LatestObservedChange() == 0); // Cannot compare across an unavailable sample.
    window.Observe(8500, true, 1700 * mib, 2000 * mib);
    assert(window.LatestObservedChange() == 0); // No unsigned time underflow.

    CapturePolicy capture;
    assert(capture.Observe(0, Pressure::Normal, false, 0, 0) == CaptureEvent::Initial);
    assert(capture.Observe(1000, Pressure::Normal, false, 100, 1000 * mib) == CaptureEvent::None);
    assert(capture.Observe(10000, Pressure::Normal, false, 100, 0) == CaptureEvent::NativeSlow);
    assert(capture.Observe(11000, Pressure::Elevated, false, 100, 0) == CaptureEvent::PressureEnter);
    assert(capture.Epoch() == 1 && capture.PressureAgeMs(12000) == 1000);
    assert(capture.Observe(12000, Pressure::Critical, false, 0, 0) == CaptureEvent::PressureWorsened);
    assert(capture.Observe(13000, Pressure::Critical, false, 0, 900 * mib) == CaptureEvent::None);
    assert(capture.Observe(22000, Pressure::Critical, false, 0, 900 * mib) == CaptureEvent::MemoryStep);
    assert(capture.Observe(23000, Pressure::Elevated, false, 0, 0) == CaptureEvent::PressureEased);
    assert(capture.Observe(24000, Pressure::Normal, false, 0, 0) == CaptureEvent::PressureNormalized);
    assert(capture.PressureAgeMs(25000) == 0);
    assert(capture.Observe(54000, Pressure::Normal, false, 0, 0) == CaptureEvent::Periodic);
    assert(capture.Observe(55000, Pressure::Critical, false, 0, 0) == CaptureEvent::PressureEnter);
    assert(capture.Epoch() == 2);
    assert(capture.Observe(56000, Pressure::Critical, true, 0, 0) == CaptureEvent::HitchStart);
    assert(capture.Observe(59000, Pressure::Critical, false, 0, 0) == CaptureEvent::HitchEnd);
    assert(capture.Observe(100, Pressure::Normal, false, 0, 0) == CaptureEvent::Initial);

    // Worst case both live and both growth groups exist: 30 min normal + 10 min sustained
    // slow calls retain coverage within 1024 lines (no extra state oscillations).
    CapturePolicy session;
    unsigned lines = 0;
    std::uint64_t detailAt = 0;
    bool detailed = false;
    for (std::uint64_t time = 0; time <= 2400000; time += 1000)
    {
        const bool critical = time >= 1800000;
        const auto event = session.Observe(time, critical ? Pressure::Critical : Pressure::Normal,
                                           false, critical ? 100.0 : 20.0, 0);
        if (event == CaptureEvent::None) continue;
        lines += 5;
        if (!detailed || event == CaptureEvent::PressureEnter || time - detailAt >= 30000)
        {
            lines += 5;
            detailed = true;
            detailAt = time;
        }
    }
    assert(lines < LogBudget::MaximumEntries && lines > 900);

    std::cout << "PASS: production memory/hitch hysteresis, log cap and bounded timing counters\n";
}
