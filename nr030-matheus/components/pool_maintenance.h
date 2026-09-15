// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>

namespace matheus030::components {
// Run before selecting a reusable slot, including on unsupported dispatches.
// The predicate supplies the production fence + Reset proof. Time alone never
// retires a recording. Iterate ALL slots, even behind a reusable first slot.
template<class Slots, class Reusable, class Retire>
void sweep_completed(Slots& slots, Reusable reusable, Retire retire) {
    for (auto& slot : slots)
        if (slot.use && reusable(slot.use)) retire(slot);
}
inline bool trim_idle_scratch(bool retained_use, bool allocated,
    std::uint64_t now_ms, std::uint64_t last_used_ms, unsigned allocated_slots) {
    return !retained_use && allocated && allocated_slots > 2 &&
        now_ms >= last_used_ms && now_ms - last_used_ms >= 2000;
}
} // namespace matheus030::components
