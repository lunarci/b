// SPDX-License-Identifier: GPL-3.0-only
// Mathematical/host-contract checks, NOT a neural model or a game benchmark.
#include "component_contract.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using namespace matheus030::components;

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void near(double a, double b, double epsilon, const char* message) {
    require(std::abs(a - b) <= epsilon, message);
}
template<class Fn> void rejects(Fn&& fn, const char* message) {
    bool threw = false;
    try { fn(); } catch (const std::invalid_argument&) { threw = true; }
    require(threw, message);
}

void geometry_checks() {
    const auto native = make_scale_plan({1921, 1081}, FixedScale::Percent100);
    require(!native.scaled && native.neural.width == 1921 && native.neural.height == 1081,
            "100% must bypass the scale component");
    const auto p75 = make_scale_plan({2560, 1440}, FixedScale::Percent75);
    require(p75.scaled && p75.neural.width == 1920 && p75.neural.height == 1080,
            "1440p game input must map to 1080p NR at 75%");
    const auto p85 = make_scale_plan({2560, 1440}, FixedScale::Percent85);
    require(p85.neural.width == 2176 && p85.neural.height == 1224, "85% geometry");
    const auto odd75 = make_scale_plan({1921, 1081}, FixedScale::Percent75);
    require(odd75.neural.width == 1441 && odd75.neural.height == 811, "odd 75% rounding");
    const auto odd85 = make_scale_plan({1921, 1081}, FixedScale::Percent85);
    require(odd85.neural.width == 1633 && odd85.neural.height == 919, "odd 85% rounding");
    const auto tiny = make_scale_plan({7, 5}, FixedScale::Percent75);
    require(!tiny.scaled, "upstream minimum must not upscale a tiny image");
    const auto small = make_scale_plan({51, 37}, FixedScale::Percent85);
    require(small.neural.width == 43 && small.neural.height == 32, "minimum/odd geometry");
    require(dispatch_groups(811) == 102 && dispatch_groups(1080) == 135, "ceil dispatch");
    const auto constants = p75.colour_constants();
    require(constants.width == 1920 && constants.source_width == 2560, "b0 contract");
    rejects([] { make_scale_plan({0, 1080}, FixedScale::Percent75); }, "zero extent");
    rejects([] { make_scale_plan({20000, 1080}, FixedScale::Percent75); }, "oversized extent");
    rejects([] { make_scale_plan({1920, 1080}, static_cast<FixedScale>(67)); }, "unsupported scale");
}

void motion_contract_checks() {
    const Extent2D source{2560, 1440}, neural{1920, 1080};
    const auto pixels = neural_motion_multiplier(source, neural, {1.0f, 1.0f});
    near(16.0 * pixels.x, 12.0, 1e-6, "source-pixel X motion must scale once");
    near(-8.0 * pixels.y, -6.0, 1e-6, "motion sign must be preserved");
    // Raw normalized UV vectors need source-grid pixel conversion BEFORE
    // requesting the multiplier. The shader must keep their stored values.
    const auto uv = neural_motion_multiplier(source, neural, {2560.0f, 1440.0f});
    near(0.01 * uv.x, 19.2, 1e-5, "normalized UV -> neural pixel X");
    near(0.01 * uv.y, 10.8, 1e-5, "normalized UV -> neural pixel Y");
    const auto identity = neural_motion_multiplier(source, source, {-1.0f, 2.0f});
    near(identity.x, -1.0, 0.0, "identity multiplier X");
    near(identity.y, 2.0, 0.0, "identity multiplier Y");
    rejects([&] { neural_motion_multiplier({0, 1440}, neural, {1.0f, 1.0f}); },
            "zero guide extent");
    rejects([&] { neural_motion_multiplier(source, neural,
              {std::numeric_limits<float>::infinity(), 1.0f}); }, "non-finite motion contract");
    rejects([&] { neural_motion_multiplier({20000, 1440}, neural, {1.0f, 1.0f}); },
            "oversized guide extent");
    rejects([&] { neural_motion_multiplier({1, 1}, neural,
              {std::numeric_limits<float>::max(), 1.0f}); }, "finite motion multiplier overflow");
    const auto plan = make_scale_plan(source, FixedScale::Percent75);
    rejects([&] { plan.guide_constants({2560, 20000}); }, "oversized active guide");
}

double overlap(double a, double b, double c, double d) {
    return std::max(0.0, std::min(b, d) - std::max(a, c));
}

// Independent finite-volume invariant: destination footprints partition every
// source cell, including fractional right/bottom edges. This does not execute
// HLSL; the actual compute executor must separately compare GPU readback.
void area_partition_check(unsigned sw, unsigned sh, unsigned dw, unsigned dh) {
    std::vector<double> covered(std::size_t(sw) * sh, 0.0);
    double output_integral = 0.0;
    double source_integral = 0.0;
    for (unsigned sy = 0; sy < sh; ++sy)
        for (unsigned sx = 0; sx < sw; ++sx)
            source_integral += ((sx == sw - 1 || sy == sh - 1) ? 1000.0 : 0.0) +
                               double(sx) * 0.75 + double(sy) * 0.125;
    for (unsigned y = 0; y < dh; ++y) {
        const double y0 = double(y) * sh / dh, y1 = double(y + 1) * sh / dh;
        for (unsigned x = 0; x < dw; ++x) {
            const double x0 = double(x) * sw / dw, x1 = double(x + 1) * sw / dw;
            double weight_sum = 0.0, weighted_sum = 0.0;
            for (unsigned sy = 0; sy < sh; ++sy) {
                for (unsigned sx = 0; sx < sw; ++sx) {
                    const double weight = overlap(x0, x1, sx, sx + 1.0) *
                                          overlap(y0, y1, sy, sy + 1.0);
                    const double value = ((sx == sw - 1 || sy == sh - 1) ? 1000.0 : 0.0) +
                                         double(sx) * 0.75 + double(sy) * 0.125;
                    covered[std::size_t(sy) * sw + sx] += weight;
                    weight_sum += weight;
                    weighted_sum += weight * value;
                }
            }
            near(weight_sum, (x1 - x0) * (y1 - y0), 1e-10, "footprint complete coverage");
            const double average = weighted_sum / weight_sum;
            require(std::isfinite(average), "finite HDR average");
            output_integral += average * weight_sum;
        }
    }
    for (double v : covered) near(v, 1.0, 1e-10, "source edge/cell lost or duplicated");
    near(output_integral, source_integral, 1e-7, "HDR/edge energy conservation");
}
} // namespace

int main() {
    try {
        geometry_checks();
        motion_contract_checks();
        area_partition_check(9, 7, 7, 5);
        area_partition_check(17, 11, 13, 8);
        area_partition_check(9, 7, 9, 7);
        std::cout << "PASS: fixed-scale geometry, motion units, fractional area conservation\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
