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
    const auto default_resolve = p75.resolve_constants();
    require(default_resolve.luma_stability_percent == 0, "Legacy resolve defaults to luma stability off");
    const auto stable_resolve = p75.resolve_constants(1.0f, true, 0.5f, 70);
    require(sizeof(stable_resolve) == 32 && offsetof(ResolveConstants, luma_stability_percent) == 28 &&
            stable_resolve.luma_stability_percent == 70 && stable_resolve.effect_strength == 0.5f,
            "Luma stability must occupy the final uint without changing the b0 ABI");
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

using Rgb = std::array<double, 3>;
using FourTaps = std::array<Rgb, 4>;

// Test-only double reference. Explicit tensor-product weights keep this
// independent of HLSL's nested lerps. Production correctness is separately
// checked by the WARP HDR-outlier and area-baseline cancellation fixtures.
Rgb residual_reference(const Rgb& native, const FourTaps& baseline,
                       const FourTaps& edited, const std::array<double, 4>& weights) {
    Rgb result{};
    for (std::size_t tap = 0; tap < weights.size(); ++tap) {
        double mismatch = 0;
        for (std::size_t c = 0; c < native.size(); ++c) {
            const double magnitude = std::max({std::abs(native[c]), std::abs(baseline[tap][c]), 1e-5});
            mismatch = std::max(mismatch, std::abs(native[c] - baseline[tap][c]) / magnitude);
        }
        const double t = std::clamp((mismatch - 0.15) / 0.6, 0.0, 1.0);
        const double confidence = 1 - t * t * (3 - 2 * t);
        for (std::size_t c = 0; c < native.size(); ++c) {
            const double limit = 0.5 * std::max(std::abs(native[c]), std::abs(baseline[tap][c]));
            const double delta = std::clamp(edited[tap][c] - baseline[tap][c], -limit, limit);
            result[c] += weights[tap] * confidence * delta;
        }
    }
    return result;
}

void residual_support_checks() {
    const double q = (6.0 + 0.5) * 34 / 40 - 0.5;
    const double x = q - std::floor(q), y = 0.375;
    const std::array<double, 4> weights{(1-x)*(1-y), x*(1-y), (1-x)*y, x*y};
    near(x, 0.025, 1e-12, "85% outlier support fixture");
    const Rgb native{1, 1, 1};
    const FourTaps baseline{native, native, native, native};
    for (const double outlier : {-65504.0, 0.0, 65504.0}) {
        auto edited = baseline;
        edited[1] = edited[3] = Rgb{outlier, outlier, outlier};
        const auto delta = residual_reference(native, baseline, edited, weights);
        for (const double component : delta)
            near(component, (outlier > 1 ? 0.5 : -0.5) * x, 1e-12,
                 "An isolated outlier must retain its interpolation support");
    }
    const Rgb black{0, 0, 0}, bright{40, 40, 40}, changed{60, 60, 60};
    const FourTaps different{black, bright, black, bright};
    const FourTaps edited{black, changed, black, changed};
    near(40 * x, 1, 1e-12, "Dissimilar tap average matches native fixture");
    for (const double component : residual_reference(native, different, edited, weights))
        near(component, 0, 0, "Averaging rejected taps must not create confidence");

    // HDR values remain in scene units. The reference applies no display-range
    // clamp; production TransferColour owns its separate FP16 output bound.
    for (const double level : {0.125, 1.0, 100.0, 40000.0}) {
        const Rgb original{level, level / 2, level / 4};
        const Rgb correction{1.5 * level, 0.75 * level, 0.375 * level};
        const FourTaps flat{original, original, original, original};
        const FourTaps changedFlat{correction, correction, correction, correction};
        const auto delta = residual_reference(original, flat, changedFlat, weights);
        for (std::size_t c = 0; c < original.size(); ++c)
            near(delta[c], original[c] * 0.5, 1e-10, "Matched HDR correction must be homogeneous");
    }
    const Rgb signedNative{-2, 0.125, 8};
    const FourTaps signedFlat{signedNative, signedNative, signedNative, signedNative};
    for (const double component : residual_reference(signedNative, signedFlat, signedFlat, weights))
        near(component, 0, 0, "Signed edited-equals-baseline identity");

    // Independent convex-support bound across every phase of both fixed grids.
    // No reconstructed component can spend more than the weighted tap budgets.
    const Rgb scene{2, 4, 8};
    const FourTaps varied{{{1, 2, 4}, {2, 4, 8}, {3, 6, 12}, {20, 40, 80}}};
    const FourTaps extreme{{{65504, -65504, 65504}, {-65504, 65504, -65504},
                           {65504, -65504, -65504}, {-65504, 65504, 65504}}};
    for (const unsigned low : {60u, 68u}) for (unsigned pixel = 0; pixel < 80; ++pixel) {
        const double position = (pixel + 0.5) * low / 80 - 0.5;
        const double tx = position - std::floor(position), ty = 1 - tx;
        const std::array<double, 4> support{(1-tx)*(1-ty), tx*(1-ty), (1-tx)*ty, tx*ty};
        near(support[0] + support[1] + support[2] + support[3], 1, 1e-12,
             "Reconstruction support partitions unity");
        const auto delta = residual_reference(scene, varied, extreme, support);
        for (std::size_t c = 0; c < scene.size(); ++c) {
            double budget = 0;
            for (std::size_t tap = 0; tap < support.size(); ++tap)
                budget += support[tap] * 0.5 * std::max(std::abs(scene[c]), std::abs(varied[tap][c]));
            require(std::isfinite(delta[c]) && std::abs(delta[c]) <= budget + 1e-12,
                    "Reconstructed residual exceeds its convex support budget");
        }
    }
}

// Scalar moment oracle for independently chosen neighborhoods. GPU fixtures
// separately exercise sampling, RGB/depth guides, borders and malformed data.
// These checks specify which edits may shrink, rather than treating native
// texture itself as the signal to be spatially averaged.
double stability_from_moments(double center_b, double center_d,
                              const std::array<double, 4>& neighbor_b,
                              const std::array<double, 4>& neighbor_d,
                              const std::array<double, 4>& weights, unsigned percent) {
    double total_weight = 0, average_b = 0, average_d = 0;
    for (std::size_t i = 0; i < weights.size(); ++i) {
        total_weight += weights[i];
        average_b += weights[i] * neighbor_b[i];
        average_d += weights[i] * neighbor_d[i];
    }
    if (total_weight <= 1e-5) return 1;
    average_b /= total_weight;
    average_d /= total_weight;
    const double old_detail = center_b - average_b;
    const double new_detail = old_detail + center_d - average_d;
    const double excess = std::max(0.0, std::abs(new_detail) - std::abs(old_detail)) /
                          std::max({std::abs(center_b), std::abs(average_b), 1e-5});
    const double t = std::clamp((excess - 0.02) / 0.08, 0.0, 1.0);
    const double support = std::min(total_weight, 1.0);
    const double guide_confidence = support * support * (3 - 2 * support);
    return 1 - std::min(percent / 100.0, 1.0) * guide_confidence * t * t * (3 - 2 * t);
}

void luma_stability_checks() {
    const std::array<double, 4> equal_weights{1, 1, 1, 1};
    const std::array<double, 4> flat{1, 1, 1, 1};
    const std::array<double, 4> negative_noise{-0.1, -0.1, -0.1, -0.1};
    near(stability_from_moments(1, 0.1, flat, negative_noise, equal_weights, 0), 1, 0,
         "Disabled luma stability retains the guarded edit");
    near(stability_from_moments(1, 0.1, flat, negative_noise, equal_weights, 70), 0.3, 1e-12,
         "Added checker contrast attenuates an edit by the selected amount");
    near(stability_from_moments(1, 0.1, flat, negative_noise, equal_weights, 100), 0, 0,
         "Full stability rejects a saturated added-contrast fixture");
    near(stability_from_moments(1, 0.1, flat, negative_noise, equal_weights, 1000), 0, 0,
         "Malformed oversized percentage cannot reverse an edit");
    near(stability_from_moments(1, 0.03, flat, {-0.03, -0.03, -0.03, -0.03},
                               equal_weights, 70), 0.65, 1e-12,
         "Six-percent excess is the midpoint of the relative contrast ramp");
    near(stability_from_moments(1, 0.005, flat, {-0.005, -0.005, -0.005, -0.005},
                               equal_weights, 100), 1, 0,
         "Small residual contrast stays below the relative threshold");
    near(stability_from_moments(1, 0.1, flat, negative_noise, {0, 0, 0, 0}, 100), 1, 0,
         "Rejected neighbors cannot suppress the surviving center edit");

    for (const double level : {0.125, 1.0, 100.0, 40000.0}) {
        const std::array<double, 4> baseline{level, level, level, level};
        const std::array<double, 4> down{-0.1 * level, -0.1 * level, -0.1 * level, -0.1 * level};
        near(stability_from_moments(level, 0.1 * level, baseline, down, equal_weights, 70),
             0.3, 1e-12, "Added-contrast attenuation must be homogeneous in HDR scene units");
        for (const double dc : {-0.4 * level, 0.0, 0.4 * level}) {
            near(stability_from_moments(level, dc, baseline, {dc, dc, dc, dc}, equal_weights, 100),
                 1, 0, "Uniform edits, identity and coherent frame-wide flicker are retained");
        }
    }

    // Common weighted moments preserve a legitimate cancellation even when
    // the baseline/depth guides select an asymmetric neighborhood.
    const std::array<double, 4> textured{0.96, 1.0, 1.02, 0.94};
    const std::array<double, 4> weighted{1.0, 0.1, 0.5, 0.0};
    for (const double amount : {0.0, 0.25, 0.5, 1.0}) {
        std::array<double, 4> cancellation{};
        for (std::size_t i = 0; i < cancellation.size(); ++i)
            cancellation[i] = amount * (1 - textured[i]);
        near(stability_from_moments(1.08, amount * (1 - 1.08), textured, cancellation,
                                   weighted, 100), 1, 0,
             "Edits that remove baseline high-frequency noise must survive");
    }

    // Multiplication preserves each signed tap's support before reconstruction;
    // a filtered neighboring edit must never be added to an unchanged tap.
    for (const unsigned percent : {0u, 20u, 70u, 100u}) {
        const double factor = stability_from_moments(1, 0.1, flat, negative_noise, equal_weights, percent);
        require(factor >= 0 && factor <= 1, "Stability factor must be a contraction");
        for (const double original_edit : {-0.5, 0.0, 0.5}) {
            const double stable_edit = original_edit * factor;
            require(std::abs(stable_edit) <= std::abs(original_edit) && stable_edit * original_edit >= 0,
                    "Stability cannot enlarge or reverse a signed tap");
            if (original_edit == 0) near(stable_edit, 0, 0, "Zero tap keeps its exact native identity");
        }
    }
}

void luma_guide_support_checks() {
    const std::array<double, 4> flat{1, 1, 1, 1};
    const std::array<double, 4> negative_noise{-0.1, -0.1, -0.1, -0.1};
    const auto factor_at = [&](double support, unsigned percent) {
        return stability_from_moments(1, 0.1, flat, negative_noise,
                                      {support / 4, support / 4, support / 4, support / 4}, percent);
    };

    // An arbitrarily weak neighborhood must not switch straight from no
    // suppression to full suppression just because its normalized mean exists.
    // The cubic support ramp has a maximum slope of 1.5 on [0,1].
    double previous = factor_at(0, 100);
    near(previous, 1, 0, "No guide support leaves the guarded edit unchanged");
    for (unsigned i = 1; i <= 1000; ++i) {
        const double support = i / 1000.0;
        const double factor = factor_at(support, 100);
        require(factor <= previous + 1e-12 && factor >= 0 && factor <= 1,
                "Increasing guide support must strengthen bounded rejection monotonically");
        require(previous - factor <= 0.0015 + 1e-12,
                "A small guide change must not switch the full rejection budget");
        previous = factor;
    }
    near(factor_at(0.99e-5, 100), factor_at(1.01e-5, 100), 4e-10,
         "The no-support threshold must have negligible rejection discontinuity");
    require(static_cast<float>(factor_at(1.01e-5, 100)) == 1.0f,
            "Negligible cutoff rejection must round to identity in float precision");
    for (const double support : {1.0, 1.25, 2.0, 4.0})
        near(factor_at(support, 70), 0.3, 1e-12,
             "At least one aggregate guide unit retains the previous rejection strength");

    // Do not replace the contrast test with raw sign rejection: at Effect50 a
    // mirrored NR detail can cancel the baseline texture rather than add noise.
    const std::array<double, 4> textured{0.96, 0.96, 0.96, 0.96};
    const std::array<double, 4> mirrored{0.08, 0.08, 0.08, 0.08};
    for (const double support : {0.0, 1.01e-5, 0.1, 0.5, 1.0, 4.0}) {
        const std::array<double, 4> weights{support / 4, support / 4, support / 4, support / 4};
        const double factor = stability_from_moments(1.04, -0.08, textured, mirrored, weights, 100);
        near(factor, 1, 0, "Guide confidence must retain beneficial mirrored-detail correction");
        near(1.04 - 0.5 * 0.08 * factor, 1, 1e-12,
             "Default Effect50 must retain baseline texture cancellation");
        near(stability_from_moments(1, 0.1, flat, {0.1, 0.1, 0.1, 0.1}, weights, 100), 1, 0,
             "Guide confidence must preserve spatially uniform corrections");
        for (const unsigned percent : {0u, 20u, 70u, 100u}) {
            const double contraction = factor_at(support, percent);
            for (const double edit : {-0.5, 0.0, 0.5}) {
                const double result = edit * contraction;
                require(std::isfinite(result) && std::abs(result) <= std::abs(edit) && result * edit >= 0,
                        "Weak guide support must preserve each guarded tap's magnitude and sign bounds");
                if (edit == 0) near(result, 0, 0, "Weak guides cannot populate a zero residual tap");
            }
        }
    }
}
} // namespace

int main() {
    try {
        geometry_checks();
        motion_contract_checks();
        area_partition_check(9, 7, 7, 5);
        area_partition_check(17, 11, 13, 8);
        area_partition_check(9, 7, 9, 7);
        residual_support_checks();
        luma_stability_checks();
        luma_guide_support_checks();
        std::cout << "PASS: fixed-scale geometry, motion units, fractional area conservation, "
                     "per-tap residual support, HDR, added-luma-contrast and guide-support continuity invariants\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
