// SPDX-License-Identifier: GPL-3.0-only
// Portable pool ownership regression fixtures, not an NR or game simulation.
#include "pool_maintenance.h"
#include <array>
#include <iostream>
#include <memory>
#include <stdexcept>

struct Use { bool provenComplete; };
struct Slot { std::shared_ptr<Use> use; };
void Require(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
int main() {
    try {
        std::array<Slot, 8> slots{};
        slots[0].use = std::make_shared<Use>(Use{true});
        slots[1].use = std::make_shared<Use>(Use{false});
        slots[6].use = std::make_shared<Use>(Use{true});
        slots[7].use = std::make_shared<Use>(Use{true});
        std::weak_ptr<Use> tail = slots[7].use;
        unsigned retired = 0;
        auto sweep = [&] {
            matheus030::components::sweep_completed(slots,
                [](const auto& use) { return use->provenComplete; },
                [&](auto& slot) { ++retired; slot.use.reset(); });
        };
        sweep();
        Require(retired == 3 && tail.expired(), "Completed tail uses remain behind first reusable slot");
        Require(bool(slots[1].use), "Unproven recording was released");
        sweep();
        Require(retired == 3, "Already retired use counted twice");
        slots[1].use->provenComplete = true;
        sweep();
        Require(retired == 4 && !slots[1].use, "Previously busy use did not recover");
        using matheus030::components::trim_idle_scratch;
        Require(trim_idle_scratch(false, true, 5000, 3000, 8), "Idle high-water scratch not trimmed");
        Require(!trim_idle_scratch(true, true, 9000, 0, 8), "Age alone retired an in-flight recording");
        Require(!trim_idle_scratch(false, true, 4999, 3000, 8), "Warm scratch trimmed too early");
        Require(!trim_idle_scratch(false, true, 9000, 0, 2), "Warm pool floor was lost");
        Require(!trim_idle_scratch(false, false, 9000, 0, 8), "Empty slot counted as freed storage");
        Require(!trim_idle_scratch(false, true, 1000, 3000, 8), "Clock reversal caused underflow trim");
        std::cout << "PASS: full-pool retirement, recovery, no double retirement, idle trim and lifetime gate\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n'; return 1;
    }
}
