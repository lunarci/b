#include "misc/XeFGWorkDiagnostics.h"
#include "misc/LongSessionTiming.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>
using namespace XeFGDiagnostics;

int main() {
    WorkDiagnostics diagnostics;
    diagnostics.BeginContext(7);
    const auto firstSeen = WorkNowMs() - 10;
    diagnostics.PublishPendingSnapshot({2, 5, 7, 3, 1, 1, firstSeen});
    diagnostics.OnCleanupAttempt();
    diagnostics.OnCleanupDeferred(CleanupReason::PendingUnsubmitted);
    auto snapshot = diagnostics.Read();
    assert(snapshot.pending.current == 2 && snapshot.pending.oldestObservedTickMs == firstSeen);
    assert(snapshot.state == CleanupState::Deferred && snapshot.cleanupAttempts == 1);
    diagnostics.OnCleanupAttempt();
    diagnostics.OnCleanupDeferred(CleanupReason::CpuBusy);
    diagnostics.OnCleanupRecovered();
    diagnostics.OnCleanupRecovered();
    snapshot = diagnostics.Read();
    assert(snapshot.cleanupAttempts == 2 && snapshot.cleanupDeferred == 2);
    assert(snapshot.cleanupCompleted == 2 && snapshot.cleanupRecovered == 1);
    assert(snapshot.state == CleanupState::Recovered && snapshot.reason == CleanupReason::None);
    diagnostics.BeginContext(8);
    snapshot = diagnostics.Read();
    assert(snapshot.contextId == 8 && snapshot.cleanupAttempts == 0);
    assert(snapshot.pending.current == 2 && snapshot.pending.registered == 7);

    // Diagnostic contention must neither wait nor erase the authoritative data.
    auto& latest = WorkDetail::Latest();
    assert(!latest.guard.test_and_set(std::memory_order_acquire));
    WorkSnapshot latestSnapshot;
    assert(!TryReadLatestWorkSnapshot(latestSnapshot));
    diagnostics.PublishPendingSnapshot({0, 5, 7, 5, 1, 1, 0});
    latest.guard.clear(std::memory_order_release);
    diagnostics.OnCleanupAttempt();
    assert(TryReadLatestWorkSnapshot(latestSnapshot));
    assert(latestSnapshot.contextId == 8 && latestSnapshot.pending.current == 0);
    assert(latestSnapshot.pending.oldestObservedTickMs == 0);

    RecordObserverInstallation(LifetimeObserver::CommandSubmission, false);
    RecordObserverInstallation(LifetimeObserver::CommandSubmission, true);
    RecordObserverInstallation(LifetimeObserver::CommandReset, true);
    RecordObserverInstallation(LifetimeObserver::CommandRelease, true);
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 8; ++i)
        threads.emplace_back([] {
            for (unsigned j = 0; j < 1000; ++j) {
                RecordObserverCallback(LifetimeObserver::CommandSubmission);
                RecordObserverCallback(LifetimeObserver::CommandReset);
                RecordObserverCallback(LifetimeObserver::CommandRelease);
            }
        });
    for (auto& thread : threads) thread.join();
    const auto observers = ReadObserverSnapshot();
    assert(observers.attemptedMask == 7 && observers.installedMask == 7);
    assert(observers.failedMask == 1 && observers.observedMask == 7);
    for (auto count : observers.callbacks) assert(count == 8000);

    static_assert(static_cast<unsigned>(LongSession::WaitStage::Pacing) == 0);
    static_assert(static_cast<unsigned>(LongSession::WaitStage::FrameGeneration) == 3);
    const auto stage = LongSession::WaitStage::Lifecycle;
    auto& counter = LongSession::WaitCounters()[static_cast<unsigned>(stage)];
    LongSession::RecordWait(stage, -1);
    LongSession::RecordWait(stage, std::numeric_limits<double>::quiet_NaN());
    LongSession::RecordWait(stage, std::numeric_limits<double>::infinity());
    assert(counter.calls.load() == 0 && counter.maximumUs.load() == 0);
    LongSession::RecordWait(stage, 0);
    assert(counter.calls.load() == 1 && counter.maximumUs.load() == 0);
    LongSession::RecordWait(stage, 1.25);
    assert(counter.calls.load() == 2 && counter.maximumUs.load() == 1250);
    LongSession::RecordWait(LongSession::WaitStage::NativePresent, 0.01);
    auto& native = LongSession::WaitCounters()[static_cast<unsigned>(LongSession::WaitStage::NativePresent)];
    assert(native.calls.load() == 1 && native.maximumUs.load() == 10);
    std::cout << "Production R5 observer/pending/recovery diagnostics and zero-duration timing calls passed\n";
}
