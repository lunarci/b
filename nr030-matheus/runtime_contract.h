#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

// C7 XeFG-compatible Daniel 0.3.0 / af5027d8, statically audited 2026-09-15.
// This is an exact binary contract, not an upstream supported public API.
// No GPU/game runtime validation has been performed. Never apply to another hash.
// Full file hash + image bounds + pristine helper signature MUST pass before hooking.
// ASLR base relocations in this helper: none (verified from the PE relocation directory).
namespace RuntimeContract {
inline constexpr std::uint64_t ExpectedFileSize = 7290880;
inline constexpr char ExpectedSha256Hex[] = "c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de";
inline constexpr std::array<std::uint8_t, 32> ExpectedSha256 = {{
    0xc7, 0xaa, 0xd0, 0x8f, 0x55, 0x5b, 0xb8, 0xa7, 0x65, 0x0f, 0x08, 0x4c, 0x3e, 0x35, 0xaa, 0x18,
    0x85, 0x87, 0x06, 0x07, 0x54, 0xba, 0x0a, 0xc6, 0x53, 0x8a, 0x51, 0x52, 0xc0, 0xa9, 0xf2, 0xde,
    
}};
inline constexpr std::uint32_t ExpectedImageSize = 0x700000;
inline constexpr std::uint32_t HelperRva = 0x1c430;
inline constexpr std::uint32_t HelperEndRva = 0x1c9bc;
inline constexpr std::uint32_t HelperSize = HelperEndRva - HelperRva;
inline constexpr std::array<std::uint8_t, 32> HelperSha256 = {{
    0x75, 0xa5, 0x1d, 0x2c, 0xeb, 0x87, 0x31, 0xd5, 0x06, 0x8a, 0x55, 0x6f, 0x7d, 0x4e, 0x78, 0x27,
    0x10, 0x95, 0x1b, 0x73, 0x0c, 0xcf, 0xae, 0x58, 0x2e, 0xcb, 0x11, 0x4c, 0x74, 0x05, 0xc5, 0xd3,
    
}};
inline constexpr std::uint32_t SignatureRva = HelperRva;
inline constexpr std::array<std::uint8_t, 128> SignatureBytes = {{
    0x55, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x56, 0x57, 0x53, 0x48, 0x81, 0xec, 0x48,
    0x02, 0x00, 0x00, 0x48, 0x8d, 0xac, 0x24, 0x80, 0x00, 0x00, 0x00, 0x48, 0xc7, 0x85, 0xc0, 0x01,
    0x00, 0x00, 0xfe, 0xff, 0xff, 0xff, 0x4c, 0x89, 0xc6, 0x48, 0x89, 0xd7, 0x48, 0x89, 0xcb, 0x8b,
    0x05, 0x03, 0xc3, 0x07, 0x00, 0x65, 0x48, 0x8b, 0x0c, 0x25, 0x58, 0x00, 0x00, 0x00, 0x48, 0x8b,
    0x04, 0xc1, 0x4c, 0x8d, 0xb8, 0x04, 0x00, 0x00, 0x00, 0x44, 0x8b, 0xa8, 0x04, 0x00, 0x00, 0x00,
    0x45, 0x85, 0xed, 0x0f, 0x9f, 0xc0, 0x4d, 0x85, 0xc0, 0x0f, 0x94, 0xc1, 0x08, 0xc1, 0x4c, 0x89,
    0xbd, 0xb8, 0x01, 0x00, 0x00, 0x0f, 0x85, 0xae, 0x02, 0x00, 0x00, 0x48, 0xc7, 0xc0, 0x00, 0x00,
    0xff, 0xff, 0x48, 0x23, 0x06, 0x48, 0x3d, 0x00, 0x00, 0x02, 0x00, 0x0f, 0x84, 0x98, 0x02, 0x00,
    
}};
inline constexpr std::array<std::uint8_t, 128> SignatureMask = [] {
    std::array<std::uint8_t, 128> result{};
    for (auto& byte : result) byte = 0xff;
    return result;
}();
inline constexpr auto signatureBytes = SignatureBytes;
inline constexpr auto signatureMask = SignatureMask;

// Leaf FFX API thunks load the original callback and tail-call the common helper.
// These are evidence locations, not additional hook targets.
inline constexpr std::array<std::uint32_t, 3> FfxThunkRvas = {0x11dc0, 0x11de0, 0x11e00};
inline constexpr std::array<std::uint32_t, 3> OriginalDispatchSlotRvas = {0x97d00, 0x97d08, 0x97d10};
inline constexpr std::uint32_t DispatchThunkTableRva = 0x69440;

// Read-only gating metadata observed in the helper, if the consumer uses it.
// PreUpscale is an int32 nonzero test; Enabled is a bit0 test, not arbitrary bool.
// Never write these fields or use them to replace file/hash/signature validation.
inline constexpr std::uint32_t PreUpscaleRva = 0x976ec;
inline constexpr std::uint32_t EnabledRva = 0x97b1e;
inline constexpr std::uint64_t UpscaleType = 0x10001;
inline constexpr std::size_t DispatchBytes = 0x1b0;
inline constexpr std::size_t HeaderBytes = 0x10;
inline constexpr std::size_t CommandListOffset = 0x10;
inline constexpr std::size_t ColorOffset = 0x18;
inline constexpr std::size_t ColorFormatOffset = 0x24;
inline constexpr std::size_t ColorStateOffset = 0x40;
inline constexpr std::size_t DepthOffset = 0x48;
inline constexpr std::size_t MotionOffset = 0x78;
inline constexpr std::size_t ExposureOffset = 0xa8;
inline constexpr std::size_t OutputOffset = 0x138;
inline constexpr std::size_t JitterOffset = 0x168;
inline constexpr std::size_t MotionScaleOffset = 0x170;
inline constexpr std::size_t RenderSizeOffset = 0x178;
inline constexpr std::size_t UpscaleSizeOffset = 0x180;

// AbiVerified means static x64 calling-convention/dataflow evidence only.
// Keep the runtime-validation state separate in all UI/log/reporting.
inline constexpr bool StaticAbiVerified = true;
inline constexpr bool AbiVerified = StaticAbiVerified;
inline constexpr bool RuntimeValidated = false;
inline constexpr char VerificationScope[] =
    "Exact-C7 PE/disassembly verified; experimental; GPU/game execution unverified";
} // namespace RuntimeContract

// Verified x64 call shape (consumer supplies its matching FFX structures):
// using OriginalFfxFn = uint32_t(__fastcall*)(void** context, const Header* desc);
// using HelperFn = uint32_t(__fastcall*)(OriginalFfxFn original,
//                                      void** context, const UpscaleDispatch* desc);
// FFX type read is uint64_t; clone size is 432 bytes. Helper calls original
// synchronously exactly once along normal paths. It does not retain that function
// pointer. On Record false, original receives the passed low descriptor unchanged.
// On Record true, it receives a stack clone with a different color resource;
// format is additionally set to FFX RGBA16F (4) only on the fallback format path.
// color.state stays unchanged. The corrected output is restored to that mapped
// D3D12 state before the callback's commands. "Corrected path" does NOT mean GPU
// inference succeeded: capture, wait and apply are only recorded at this point.
// Append resolve to the same command list; never CPU-wait before game submission.
// Existing ExecuteCommandLists hook publishes the capture job after submission.

