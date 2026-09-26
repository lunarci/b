// Exercise the actual production admission gate with independent threads.
// No driver or game is simulated here; GPU fences are covered separately.
#include <framegen/FGWorkGate.h>

#include <atomic>
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>
#include <latch>
#include <thread>
#include <utility>

using namespace std::chrono_literals;

template<class Predicate> void await(Predicate predicate)
{
    const auto deadline = std::chrono::steady_clock::now() + 3s;
    while (!predicate())
    {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::yield();
    }
}

static void in_flight_work_prevents_cleanup()
{
    FGWorkGate gate;
    assert(gate.Open());
    std::latch entered{1}, release{1};
    std::atomic<bool> used{false};
    std::thread tagging([&] {
        auto work = gate.TryEnter();
        assert(work);
        auto moved = std::move(work);
        assert(moved && !work);
        entered.count_down();
        release.wait();
        used.store(true);
    });
    entered.wait();
    auto cleanup = std::async(std::launch::async, [&] {
        const bool drained = gate.CloseAndWait(3s);
        assert(drained && used.load());
        return drained;
    });
    await([&] { return gate.IsClosed(); });
    // A closed gate must not let even one late provider call through.
    auto late = std::async(std::launch::async, [&] { return bool(gate.TryEnter()); });
    assert(late.wait_for(1s) == std::future_status::ready && !late.get());
    assert(cleanup.wait_for(0ms) == std::future_status::timeout);
    release.count_down();
    tagging.join();
    assert(cleanup.wait_for(1s) == std::future_status::ready && cleanup.get());
    assert(gate.IsClosed());
    assert(!gate.TryEnter());
    assert(gate.Open());
    assert(gate.TryEnter());
}

static void close_timeout_does_not_permit_reopen_with_users()
{
    FGWorkGate gate;
    assert(gate.Open());
    std::latch entered{1}, release{1};
    std::thread submitting([&] {
        auto work = gate.TryEnter();
        assert(work);
        entered.count_down();
        release.wait();
    });
    entered.wait();
    assert(!gate.CloseAndWait(1ms));
    assert(gate.IsClosed());
    assert(!gate.Open());
    assert(!gate.TryEnter());
    release.count_down();
    submitting.join();
    assert(gate.CloseAndWait(1s));
    assert(gate.Open());
}

static void provider_teardown_does_not_hold_gate_mutex()
{
    FGWorkGate gate;
    assert(gate.Open());
    std::latch provider_entered{1}, provider_release{1};
    std::thread cleanup([&] {
        assert(gate.CloseAndWait(1s));
        provider_entered.count_down();
        // An external provider can callback while teardown is in progress.
        provider_release.wait();
    });
    provider_entered.wait();
    auto callback = std::async(std::launch::async, [&] {
        assert(gate.IsClosed());
        return bool(gate.TryEnter());
    });
    assert(callback.wait_for(1s) == std::future_status::ready && !callback.get());
    provider_release.count_down();
    cleanup.join();
}

static void final_cpu_drain_waits_for_scope_destruction()
{
    FGWorkGate gate;
    std::latch entered{1}, release{1};
    std::thread caller([&] {
        auto work = gate.TryEnter();
        assert(work);
        entered.count_down(); release.wait();
    });
    entered.wait();
    auto destruction = std::async(std::launch::async, [&] { gate.CloseAndWait(); });
    await([&] { return gate.IsClosed(); });
    assert(destruction.wait_for(0ms) == std::future_status::timeout);
    release.count_down(); caller.join();
    assert(destruction.wait_for(1s) == std::future_status::ready);
    destruction.get();
}

int main()
{
    in_flight_work_prevents_cleanup();
    close_timeout_does_not_permit_reopen_with_users();
    provider_teardown_does_not_hold_gate_mutex();
    final_cpu_drain_waits_for_scope_destruction();
    std::cout << "PASS: production lifecycle gate concurrent admission, drain, timeout and callback tests\n";
}
