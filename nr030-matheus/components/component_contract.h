// SPDX-License-Identifier: GPL-3.0-only
// Source attribution and pinned upstream commit: see NOTICE.
#pragma once
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace matheus030::components {

struct Extent2D { std::uint32_t width; std::uint32_t height; };
enum class FixedScale : std::uint32_t { Percent100 = 100, Percent85 = 85, Percent75 = 75 };
inline bool valid_extent(Extent2D extent) {
    return extent.width && extent.height && extent.width <= 16384 && extent.height <= 16384;
}

// Matches the four uint values at b0 in the three guide/copy shaders.
struct ResampleConstants {
    std::uint32_t width, height, source_width, source_height;
};
// Matches b0 in matched_residual_resolve.hlsl.
struct ResolveConstants {
    std::uint32_t width, height, low_width, low_height;
    float colour_preservation;
    std::uint32_t depth_protection;
    float effect_strength;
    std::uint32_t luma_stability_percent;
};
static_assert(sizeof(ResampleConstants) == 16);
static_assert(sizeof(ResolveConstants) == 32);
static_assert(offsetof(ResolveConstants, luma_stability_percent) == 28);

struct ScalePlan {
    Extent2D input;
    Extent2D neural;
    bool scaled;
    ResampleConstants colour_constants() const {
        return {neural.width, neural.height, input.width, input.height};
    }
    ResampleConstants guide_constants(Extent2D active_guide) const {
        if (!valid_extent(active_guide))
            throw std::invalid_argument("Active guide extent must fit a nonzero D3D12 2D texture");
        return {neural.width, neural.height, active_guide.width, active_guide.height};
    }
    ResolveConstants resolve_constants(float colour_preservation = 1.0f,
        bool depth_protection = true, float effect_strength = 1.0f,
        std::uint32_t luma_stability_percent = 0) const {
        return {input.width, input.height, neural.width, neural.height,
                colour_preservation, depth_protection ? 1u : 0u, effect_strength,
                luma_stability_percent};
    }
};

inline ScalePlan make_scale_plan(Extent2D input, FixedScale choice) {
    if (!valid_extent(input))
        throw std::invalid_argument("Input extent must fit a nonzero D3D12 2D texture");
    const auto percent = static_cast<std::uint32_t>(choice);
    if (percent != 100 && percent != 85 && percent != 75)
        throw std::invalid_argument("Only fixed 100%, 85% and 75% scales are supported");
    // Reproduces positive lround(native * scale) and the upstream 32-pixel
    // minimum without floating-point rounding differences in the host plan.
    const auto dimension = [percent](std::uint32_t native) {
        auto value = (native * percent + 50u) / 100u;
        if (value < 32u) value = 32u;
        return value > native ? native : value;
    };
    const Extent2D neural{dimension(input.width), dimension(input.height)};
    return {input, neural, input.width != neural.width || input.height != neural.height};
}

struct MotionMultiplier { float x; float y; };

// Contract: raw vector * units_to_source_grid_pixels is the displacement in
// ACTIVE SOURCE-GUIDE PIXELS, in the direction required by the NR backend.
// The shader only resamples positions; it does not multiply vector values.
// Pass the returned factors once to the eventual NR invocation. Never also
// multiply the shader output. No FFX/NGX ABI or motion convention is inferred.
inline MotionMultiplier neural_motion_multiplier(
    Extent2D source_guide, Extent2D neural,
    MotionMultiplier units_to_source_grid_pixels) {
    if (!valid_extent(source_guide) || !valid_extent(neural) ||
        !std::isfinite(units_to_source_grid_pixels.x) ||
        !std::isfinite(units_to_source_grid_pixels.y))
        throw std::invalid_argument("Invalid motion extent or conversion");
    const MotionMultiplier result{
        units_to_source_grid_pixels.x * (float(neural.width) / float(source_guide.width)),
        units_to_source_grid_pixels.y * (float(neural.height) / float(source_guide.height))
    };
    if (!std::isfinite(result.x) || !std::isfinite(result.y))
        throw std::invalid_argument("Motion conversion overflowed");
    return result;
}

inline std::uint32_t dispatch_groups(std::uint32_t pixels) {
    return pixels / 8u + (pixels % 8u != 0u);
}
} // namespace matheus030::components
