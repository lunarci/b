// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d12.h>
#include <atomic>
#include <cstdint>

namespace nr030::xefg {
struct Version { std::uint32_t major = 0, minor = 0, patch = 0; };
struct Policy {
    bool verified = false;
    std::uintptr_t expectedReturn = 0;
    Version version{};
};
enum class Decision { OtherCall, Unverified, PatternMismatch, OldOrUnknownVersion, Suppress };
using BarrierFn = void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*, UINT,
                                           const D3D12_RESOURCE_BARRIER*);
using LogFn = void(*)(const char*);

// Shared pure decision/forwarding logic. Production trust is established only
// by Guard::Initialize; this interface does not configure or enable the hook.
Decision Decide(const Policy&, std::uintptr_t caller, ID3D12GraphicsCommandList*,
                UINT count, const D3D12_RESOURCE_BARRIER*) noexcept;
Decision Forward(const Policy&, std::uintptr_t caller, BarrierFn,
                 ID3D12GraphicsCommandList*, UINT count, const D3D12_RESOURCE_BARRIER*);

struct CounterSnapshot {
    bool attempted = false, ready = false;
    std::uint64_t exactSiteSeen = 0, suppressed = 0;
    std::uint64_t patternMismatch = 0, oldOrUnknownForwarded = 0;
    Version version{};
};
class Guard {
public:
    // Optional guard: any validation/hook failure returns false and must not
    // disable the existing NR adapter. No settings or files are modified.
    bool Initialize(ID3D12GraphicsCommandList*, LogFn) noexcept;
    CounterSnapshot Counters() const noexcept;
    void Report() const noexcept;
private:
    static void STDMETHODCALLTYPE Hook(ID3D12GraphicsCommandList*, UINT,
                                       const D3D12_RESOURCE_BARRIER*);
    void Emit(const char*) const noexcept;
    Version CurrentVersion() const noexcept;
    static Guard* instance_;
    HMODULE module_ = nullptr;
    const volatile std::uint32_t* version_ = nullptr;
    std::uintptr_t expectedReturn_ = 0;
    void* target_ = nullptr;
    BarrierFn original_ = nullptr;
    LogFn log_ = nullptr;
    std::atomic<bool> attempted_{false}, ready_{false};
    std::atomic<std::uint64_t> exactSiteSeen_{0}, suppressed_{0};
    std::atomic<std::uint64_t> patternMismatch_{0}, oldOrUnknownForwarded_{0};
};
} // namespace nr030::xefg
