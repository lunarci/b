static void At(uint64_t now) { XeFGDiagnostics::testClock = now; }
static void Submit(XeFG_Dx12& subject, ID3D12CommandQueue& queue) {
    auto admission = subject.AcquireSubmissionWork();
    assert(admission);
    subject.ObserveSubmittedQueue(&queue);
}
static void Setup(XeFG_Dx12& subject, ID3D12Device& device, ID3D12CommandQueue& queue) {
    At(1); State::Instance().isShuttingDown = false;
    queue.device = &device; subject._device = &device; subject.TrackLifetimeQueue(&queue);
    assert(subject._lifetimeQueueCount == 1 && queue.refs == 2);
}
static void ReleaseAfterSeparateDrain(XeFG_Dx12& subject) {
    // The production lifecycle's separate GPU drain is deliberately not faked
    // by a progress marker. Here it is an explicit external test precondition.
    assert(subject._submissionGate.TryCloseWhenIdle());
    subject._objectsDrained = true; subject._swapChainContext = nullptr;
    subject.ReleaseObjects();
}
int main() {
    {
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue);
        // Tracking alone is not a submitted marker or a stalled GPU.
        subject.PollGpuProgress();
        auto empty = XeFGProgress::ReadSnapshot();
        assert(empty.valid && empty.trackedQueues == 1 && empty.queues[0].signalCount == 0);
        assert(device.createCalls == 0 && queue.signals == 0);
        Submit(subject, queue);
        auto& entry = subject._lifetimeQueues[0];
        assert(entry.progress.signalCount == 1 && entry.progress.completionCount == 0);
        assert(entry.progress.pendingSinceMs == 1 && entry.progressFence != nullptr);
        for(uint64_t now = 2; now <= 10000; ++now) { At(now); Submit(subject, queue); subject.PollGpuProgress(); }
        assert(queue.signals == 1 && device.createCalls == 1 && entry.progressFence->reads <= 10);
        assert(entry.progress.coalesced <= 10 && entry.progress.pendingSinceMs == 1);
        assert(entry.progress.completionCount == 0 && !entry.progress.stopped);
        // An incomplete diagnostic marker never authorizes resource release.
        subject._swapChainContext = nullptr; subject.ReleaseObjects();
        assert(queue.refs == 2 && entry.progressFence->releases == 0 && subject.commandReleases == 0);
        auto fence = entry.progressFence;
        fence->completed = entry.progressValue; At(10001); subject.PollGpuProgress();
        assert(entry.progress.completionCount == 1 && entry.progress.pendingSinceMs == 0);
        assert(entry.progress.completionObservationMaxMs == 10000);
        Submit(subject, queue);
        assert(queue.signals == 2 && entry.progressValue == 2 && entry.progress.pendingSinceMs == 10001);
        assert(entry.fence == nullptr && entry.value == 0); // separate cleanup evidence untouched
        ReleaseAfterSeparateDrain(subject);
        assert(queue.refs == 1 && fence->releases == 1 && subject._lifetimeQueueCount == 0);
    }
    {
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue); Submit(subject, queue);
        auto& entry = subject._lifetimeQueues[0]; auto fence = entry.progressFence;
        fence->completed = UINT64_MAX; At(1001); subject.PollGpuProgress();
        assert(entry.progress.deviceRemoved == 1 && entry.progress.stopped);
        assert(entry.progress.completionCount == 0 && entry.progress.pendingSinceMs == 1);
        for(uint64_t now = 2001; now < 10001; now += 1000) { At(now); Submit(subject, queue); subject.PollGpuProgress(); }
        assert(queue.signals == 1 && fence->reads == 1 && entry.progress.deviceRemoved == 1);
    }
    {
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue); queue.signalResult = DXGI_ERROR_DEVICE_REMOVED;
        Submit(subject, queue); auto& entry = subject._lifetimeQueues[0];
        assert(entry.progress.stopped && entry.progress.signalFailures == 1);
        assert(entry.progress.lastError == DXGI_ERROR_DEVICE_REMOVED);
        assert(entry.progress.signalCount == 0 && entry.progress.pendingSinceMs == 0 && entry.progressValue == 0);
        for(uint64_t now = 1001; now < 100001; now += 1000) { At(now); Submit(subject, queue); subject.PollGpuProgress(); }
        assert(queue.signals == 1 && entry.progressFence->reads == 0);
    }
    {
        // Slow native CreateFence cannot make a just-issued marker eligible
        // for another Signal immediately; its deadline starts at Signal.
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue); device.createDelayMs = 2000;
        Submit(subject, queue); auto& entry = subject._lifetimeQueues[0];
        assert(queue.signals == 1 && entry.progress.pendingSinceMs == 2001);
        assert(entry.nextProgressAttemptMs == 3001);
        queue.lastFence->completed = queue.lastValue;
        At(2002); Submit(subject, queue);
        assert(queue.signals == 1 && entry.progress.completionCount == 1);
        At(3000); Submit(subject, queue); assert(queue.signals == 1);
        At(3001); Submit(subject, queue); assert(queue.signals == 2);
    }
    for(bool missingDevice : {false, true}) {
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue); device.createResult = E_FAIL;
        if(missingDevice) queue.device = nullptr;
        for(uint64_t now = 1; now < 10001; ++now) { At(now); Submit(subject, queue); }
        const auto& entry = subject._lifetimeQueues[0];
        assert(entry.progressCreateAttempts == 3 && entry.progress.createFailures == 3 && entry.progress.stopped);
        assert(entry.progress.signalCount == 0 && queue.signals == 0);
        assert(device.createCalls == (missingDevice ? 0u : 3u));
        assert(device.releases == device.createCalls);
    }
    {
        XeFG_Dx12 subject; ID3D12Device device;
        std::array<ID3D12CommandQueue, 9> queues;
        At(1); subject.ObserveSubmittedQueue(nullptr);
        for(auto& queue : queues) { queue.device = &device; Submit(subject, queue); }
        assert(subject._lifetimeQueueCount == 0 && device.createCalls == 0);
        for(auto& queue : queues) subject.TrackLifetimeQueue(&queue);
        assert(subject._lifetimeQueueCount == 8 && !subject._queueTrackingComplete);
        for(auto& queue : queues) Submit(subject, queue);
        assert(device.createCalls == 8 && queues[8].signals == 0 && queues[8].refs == 1);
        auto snapshot = XeFGProgress::ReadSnapshot();
        assert(snapshot.valid && snapshot.trackedQueues == 8 && !snapshot.queueTrackingComplete);
        for(size_t i = 1; i < 8; ++i) assert(snapshot.queues[i].queueId != snapshot.queues[i-1].queueId);
    }
    {
        // Sparse successful work stays capped even with 100,000 callbacks.
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue);
        for(uint64_t now = 1; now <= 100000; ++now) {
            At(now); if(queue.lastFence) queue.lastFence->completed = queue.lastValue;
            Submit(subject, queue); subject.PollGpuProgress();
        }
        const auto& entry = subject._lifetimeQueues[0];
        assert(queue.signals == 100 && device.createCalls == 1 && entry.progress.completionCount == 99);
        assert(entry.progressFence->reads == 99);
    }
    {
        // A marker Signal in flight is covered by the real submission gate.
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue);
        std::latch entered(1), resume(1); queue.signalEntered = &entered; queue.signalContinue = &resume;
        std::thread worker([&] { Submit(subject, queue); }); entered.wait();
        assert(!subject._submissionGate.TryCloseWhenIdle());
        subject.PollGpuProgress(); assert(subject._gpuProgressBusy == 1);
        assert(queue.refs == 2 && device.fences[0].releases == 0);
        resume.count_down(); worker.join();
        ReleaseAfterSeparateDrain(subject);
        assert(queue.refs == 1 && device.fences[0].releases == 1);
        const auto calls = queue.signals; At(2001); subject.PollGpuProgress();
        assert(queue.signals == calls && subject._lifetimeQueueCount == 0);
        // The same object/queue can be recreated without stale pending state.
        assert(subject._submissionGate.Open()); subject._swapChainContext = reinterpret_cast<void*>(1);
        subject.TrackLifetimeQueue(&queue); queue.signalEntered = queue.signalContinue = nullptr;
        Submit(subject, queue);
        assert(subject._lifetimeQueues[0].progress.signalCount == 1 && subject._lifetimeQueues[0].progressValue == 1);
        assert(subject._lifetimeQueues[0].progressFence != &device.fences[0] && device.createCalls == 2);
        assert(XeFGProgress::ReadSnapshot().trackedQueues == 1);
    }
    {
        // Neither a busy diagnostic mutex nor a busy queue registry may wait.
        XeFG_Dx12 subject; ID3D12Device device; ID3D12CommandQueue queue;
        Setup(subject, device, queue);
        for(bool progressMutex : {true, false}) {
            std::latch locked(1), unlock(1);
            std::thread holder([&] { std::unique_lock lock(progressMutex ? subject._gpuProgressMutex : subject._lifetimeQueueMutex); locked.count_down(); unlock.wait(); });
            locked.wait();
            auto observer = std::async(std::launch::async, [&] { Submit(subject, queue); subject.PollGpuProgress(); });
            assert(observer.wait_for(std::chrono::seconds(1)) == std::future_status::ready);
            observer.get(); unlock.count_down(); holder.join();
        }
        assert(queue.signals == 0 && subject._gpuProgressBusy == 2);
        Submit(subject, queue); assert(queue.signals == 1);
        State::Instance().isShuttingDown = true; At(1001); Submit(subject, queue); subject.PollGpuProgress();
        assert(queue.signals == 1 && queue.lastFence->reads == 0);
        State::Instance().isShuttingDown = false;
    }
    {
        const auto before = XeFGProgress::ReadLifecycleSnapshot();
        std::vector<std::thread> workers;
        for(unsigned thread = 0; thread < 8; ++thread) workers.emplace_back([] {
            for(unsigned i = 0; i < 1000; ++i) XeFGProgress::RecordDeactivate(XeFGProgress::DeactivateReason::SettingsChanged, i % 2 ? 0 : -14);
        });
        for(auto& worker : workers) worker.join();
        const auto after = XeFGProgress::ReadLifecycleSnapshot();
        const auto index = static_cast<unsigned>(XeFGProgress::DeactivateReason::SettingsChanged);
        assert(after.attempted[index] - before.attempted[index] == 8000);
        assert(after.accepted[index] - before.accepted[index] == 4000 && after.nonzero[index] - before.nonzero[index] == 4000);
    }
    std::cout << "PASS: actual R7 sparse marker progress/error paths, bounded work, CPU admission, teardown guards and recreation\n";
}
