#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <thread>
#include <unordered_map>
#include <vector>

// Compile the exact production locking helper. The provider/Windows API is not
// involved; the underlying container has the same external synchronization need.
#include "proxies/FfxContextRegistry.h"

enum class Kind { General, Upscale, FrameGeneration, Unknown };
using Registry = FfxContextRegistry<std::unordered_map<uintptr_t, Kind>>;

int main()
{
    Registry registry;
    Kind type = Kind::General;
    assert(!registry.Find(77, type) && type == Kind::General);
    type = Kind::Unknown;
    assert(!registry.Take(77, type) && type == Kind::Unknown);

    // Preserve existing insert-or-replace and caller fallback semantics.
    registry.Set(0, Kind::Upscale);
    registry.Set(0, Kind::FrameGeneration);
    assert(registry.Find(0, type) && type == Kind::FrameGeneration);
    assert(registry.Take(0, type) && type == Kind::FrameGeneration);
    assert(!registry.Find(0, type));

    // Render-thread creation/configuration can overlap delayed destruction of
    // many unrelated contexts. Bulk publication also forces container growth.
    constexpr unsigned workers = 8, perWorker = 2000;
    std::atomic<unsigned> ready { 0 };
    std::atomic<bool> start { false };
    std::vector<std::thread> threads;
    for (unsigned worker = 0; worker < workers; ++worker)
    {
        threads.emplace_back([&, worker] {
            ready.fetch_add(1);
            while (!start.load()) std::this_thread::yield();
            const Kind expected = worker % 2 ? Kind::Upscale : Kind::FrameGeneration;
            const uintptr_t base = 1 + uintptr_t(worker) * perWorker;
            for (unsigned index = 0; index < perWorker; ++index)
                registry.Set(base + index, expected);
            for (unsigned index = 0; index < perWorker; ++index)
            {
                Kind found = Kind::Unknown;
                assert(registry.Find(base + index, found) && found == expected);
                assert(registry.Take(base + index, found) && found == expected);
                found = Kind::General;
                assert(!registry.Find(base + index, found) && found == Kind::General);
            }
        });
    }
    while (ready.load() != workers) std::this_thread::yield();
    start = true;
    for (auto& thread : threads) thread.join();
    threads.clear();

    // Lookup plus erase must be atomic: simultaneous destroy paths can route
    // a registered context exactly once, without inserting a default entry.
    registry.Set(99, Kind::Upscale);
    std::atomic<unsigned> winners { 0 };
    start = false;
    ready = 0;
    for (unsigned worker = 0; worker < workers; ++worker)
        threads.emplace_back([&] {
            ready.fetch_add(1);
            while (!start.load()) std::this_thread::yield();
            Kind found = Kind::Unknown;
            if (registry.Take(99, found))
            {
                assert(found == Kind::Upscale);
                winners.fetch_add(1);
            }
            else
                assert(found == Kind::Unknown);
        });
    while (ready.load() != workers) std::this_thread::yield();
    start = true;
    for (auto& thread : threads) thread.join();
    assert(winners.load() == 1);
    type = Kind::Unknown;
    assert(!registry.Find(99, type) && type == Kind::Unknown);

    // A provider may re-enter the proxy after a routing lookup. Each operation
    // must release its lock before returning control to provider call sites.
    registry.Set(120, Kind::Upscale);
    assert(registry.Find(120, type));
    registry.Set(121, Kind::FrameGeneration);
    assert(registry.Take(120, type));
    assert(registry.Take(121, type));
    std::cout << "PASS: production FFX registry; 16000 concurrent context lifetimes, atomic take and fallbacks\n";
}
