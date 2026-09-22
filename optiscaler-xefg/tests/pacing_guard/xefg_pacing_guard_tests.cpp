#include "XeFGPacingGuard.h"
#include <cassert>
#include <cstdint>
#include <iostream>

int main()
{
    using namespace XeFGPacingGuard;
    constexpr int64_t ms = 1000000;
    constexpr int64_t max = (std::numeric_limits<int64_t>::max)();

    // A repeated, genuinely slow game must remain eligible for pacing.
    assert(!Discontinuous(500 * ms, 500 * ms, 15));
    assert(!Discontinuous(1000 * ms, 1000 * ms, 15));
    assert(!Discontinuous(45 * ms, 30 * ms, 15));
    assert(!Discontinuous(250 * ms, 30 * ms, 15));
    // The loading gap and the later return to fast frames invalidate the
    // old history; warm-up has no reliable baseline and must not reject it.
    assert(Discontinuous(500 * ms, 30 * ms, 15));
    assert(Discontinuous(30 * ms, 500 * ms, 15));
    assert(!Discontinuous(500 * ms, 30 * ms, 2));

    int64_t value = 42;
    assert(Add(max - 1, 1, value) && value == max);
    assert(!Add(max, 1, value));
    assert(!Multiply(max, 2, value));
    assert(!Add(-1, 5, value));
    // This 30-minute QPC conversion overflowed the old intermediate
    // multiplication even though its final nanosecond value fits.
    assert(Scale(18000000000LL, 1000000000LL, 10000000LL) == 1800000000000LL);
    assert(Scale(max, max, 1) == max);
    assert(Scale(123, 1, 0) == 0);
    assert(Scale(-1, 1000, 1) == 0);
    assert(WaitBudget(1000 * ms) == 2250 * ms);
    assert(WaitBudget(max) == max);

    assert(CheckWait(1, 1, 100, 110, 120, 50) == WaitDecision::Continue);
    assert(CheckWait(1, 2, 100, 110, 120, 50) == WaitDecision::Abort);
    assert(CheckWait(1, 1, 100, 99, 120, 50) == WaitDecision::Abort);
    assert(CheckWait(1, 1, 100, 110, 200, 50) == WaitDecision::Abort);
    assert(CheckWait(1, 1, 100, 150, 151, 50) == WaitDecision::Abort);
    assert(CheckWait(1, 1, 100, 151, 151, 50) == WaitDecision::Complete);
    assert(CheckWait(1, 1, 100, 110, 200, 0) == WaitDecision::Abort);

    assert(FirstDeadline(100, 20, 10, 5, value) && value == 150);
    assert(!FirstDeadline(max - 1, 20, 10, 1, value));
    assert(!FirstDeadline(100, max, 0, 5, value));
    assert(!FirstDeadline(100, 20, 30, 1, value));
    assert(!FirstDeadline(100, 20, 10, 6, value));
    uint32_t counter = (std::numeric_limits<uint32_t>::max)();
    Increment(counter);
    assert(counter == (std::numeric_limits<uint32_t>::max)());
    std::cout << "XeFG pacing guard policy tests passed\n";
}
