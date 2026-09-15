// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <d3d12.h>
#include <cmath>
#include "ffx_contract.h"
#include "../components/component_contract.h"

// Shared by the production hook and WARP admission checks. A motion texture
// can store XY in either RG16F or RGBA16F. Its SRV must retain the resource's
// channel layout; reinterpreting RGBA16F as RG16F is invalid.
namespace nr030::input {
inline DXGI_FORMAT MotionViewFormat(const ffx::Resource& resource) {
    if (resource.description.format == ffx::FormatRgba16Float)
        return DXGI_FORMAT_R16G16B16A16_FLOAT;
    if (resource.description.format == ffx::FormatRg16Float)
        return DXGI_FORMAT_R16G16_FLOAT;
    return DXGI_FORMAT_UNKNOWN;
}
inline const char* TextureRejection(const ffx::Resource& resource,
                                   matheus030::components::Extent2D extent,
                                   std::uint32_t format, DXGI_FORMAT typed,
                                   DXGI_FORMAT alias) {
    if (!resource.resource) return "resource_missing";
    if (resource.state != ffx::ComputeRead) return "resource_state";
    if (resource.description.type != 2) return "resource_type";
    if (resource.description.format != format) return "resource_format";
    if (resource.description.width != extent.width || resource.description.height != extent.height)
        return "resource_extent";
    const auto actual = static_cast<ID3D12Resource*>(resource.resource)->GetDesc();
    if (actual.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || actual.DepthOrArraySize != 1 ||
        actual.MipLevels != 1 || actual.SampleDesc.Count != 1)
        return "texture_layout";
    if (actual.Width != extent.width || actual.Height != extent.height) return "texture_extent";
    if (actual.Format != typed && actual.Format != alias) return "texture_format";
    if (actual.Flags & D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE) return "texture_no_srv";
    return nullptr;
}
inline const char* Rejection(const ffx::UpscaleDispatch* desc) {
    if (!desc) return "dispatch_missing";
    if (desc->header.type != ffx::UpscaleType) return "dispatch_type";
    if (desc->header.next) return "dispatch_extension";
    if (!desc->commandList) return "command_list_missing";
    const matheus030::components::Extent2D extent{desc->renderSize.width, desc->renderSize.height};
    if (!matheus030::components::valid_extent(extent)) return "render_extent_invalid";
    if (!std::isfinite(desc->motionVectorScale.x) || !std::isfinite(desc->motionVectorScale.y) ||
        !std::isfinite(desc->jitterOffset.x) || !std::isfinite(desc->jitterOffset.y))
        return "motion_or_jitter_nonfinite";
    if (TextureRejection(desc->color, extent, ffx::FormatRgba16Float,
                         DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16B16A16_TYPELESS))
        return "color_input_unsupported";
    if (TextureRejection(desc->depth, extent, ffx::FormatR32Float,
                         DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R32_TYPELESS))
        return "depth_input_unsupported";
    const auto motionView = MotionViewFormat(desc->motionVectors);
    if (motionView == DXGI_FORMAT_UNKNOWN) return "motion_format_unsupported";
    const auto motionAlias = motionView == DXGI_FORMAT_R16G16B16A16_FLOAT
        ? DXGI_FORMAT_R16G16B16A16_TYPELESS : DXGI_FORMAT_R16G16_TYPELESS;
    if (TextureRejection(desc->motionVectors, extent, desc->motionVectors.description.format,
                         motionView, motionAlias)) return "motion_input_unsupported";
    return nullptr;
}
} // namespace nr030::input
