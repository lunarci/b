// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstddef>
#include <cstdint>

// Narrow layout adapter for FFX 4.1.1's public dispatch ABI, cross-checked with
// the exact C7 runtime's 432-byte clone. Not an SDK replacement or provider ABI.
// Field names/layout follow AMD's MIT-licensed ffx_api_types.h/ffx_upscale.h.
namespace nr030::ffx {
struct Header { std::uint64_t type; Header* next; };
struct Extent { std::uint32_t width, height; };
struct Float2 { float x, y; };
struct ResourceDescription {
    std::uint32_t type, format, width, height, depth, mipCount, flags, usage;
};
struct Resource { void* resource; ResourceDescription description; std::uint32_t state; };
struct UpscaleDispatch {
    Header header;
    void* commandList;
    Resource color, depth, motionVectors, exposure, reactive, transparencyAndComposition, output;
    Float2 jitterOffset, motionVectorScale;
    Extent renderSize, upscaleSize;
    bool enableSharpening;
    float sharpness, frameTimeDelta, preExposure;
    bool reset;
    float cameraNear, cameraFar, cameraFovAngleVertical, viewSpaceToMetersFactor;
    std::uint32_t flags;
};
using DispatchFn = std::uint32_t(__fastcall*)(void**, const Header*);
using HelperFn = std::uint32_t(__fastcall*)(DispatchFn, void**, const UpscaleDispatch*);
constexpr std::uint64_t UpscaleType = 0x10001;
constexpr std::uint32_t ComputeRead = 4;
constexpr std::uint32_t FormatRgba16Float = 4;
constexpr std::uint32_t FormatRg16Float = 18;
constexpr std::uint32_t FormatR32Float = 28;
static_assert(sizeof(void*) == 8, "Only Windows x64 is supported");
static_assert(sizeof(Header) == 16 && sizeof(ResourceDescription) == 32 && sizeof(Resource) == 48);
static_assert(sizeof(UpscaleDispatch) == 0x1b0);
static_assert(offsetof(UpscaleDispatch, commandList) == 0x10);
static_assert(offsetof(UpscaleDispatch, color) == 0x18);
static_assert(offsetof(Resource, state) == 0x28);
static_assert(offsetof(UpscaleDispatch, depth) == 0x48);
static_assert(offsetof(UpscaleDispatch, motionVectors) == 0x78);
static_assert(offsetof(UpscaleDispatch, output) == 0x138);
static_assert(offsetof(UpscaleDispatch, jitterOffset) == 0x168);
static_assert(offsetof(UpscaleDispatch, motionVectorScale) == 0x170);
static_assert(offsetof(UpscaleDispatch, renderSize) == 0x178);
static_assert(offsetof(UpscaleDispatch, upscaleSize) == 0x180);
} // namespace nr030::ffx
