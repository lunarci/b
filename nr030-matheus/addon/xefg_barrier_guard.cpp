// SPDX-License-Identifier: GPL-3.0-only
#include "xefg_barrier_guard.h"
#include <MinHook.h>
#include <bcrypt.h>
#include <tlhelp32.h>
#include <intrin.h>
#include <array>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(_MSC_VER)
#pragma intrinsic(_ReturnAddress)
#endif

namespace nr030::xefg {
namespace {
constexpr DWORD ImageSize = 0x1892000;
constexpr LONGLONG FileSize = 25648128;
constexpr std::uintptr_t FunctionRva = 0x125d50;
constexpr SIZE_T FunctionSize = 0x1193;
constexpr std::uintptr_t ReverseReturnRva = 0x126d72;
constexpr std::uintptr_t VersionRva = 0x184f2c0;
constexpr char FileHash[] = "ba4df99acf55278c617780d56b89847553063ebc8e521bf831e09d21d5c0b04b";
// Full SetResource, not just a six-byte indirect call. There are no base
// relocations in this exact function; this hash is valid at any load address.
constexpr char FunctionHash[] = "abd9440fdeae30bfcf83d5b1226d5169e45f644c1ef97a116089e7946b798b74";

class Handle {
public:
    explicit Handle(HANDLE value) : value_(value) {}
    ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    HANDLE get() const { return value_; }
private:
    HANDLE value_;
};
class Hash {
public:
    Hash() {
        if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
            throw std::runtime_error("sha256_open_failed");
        if (BCryptCreateHash(algorithm_, &hash_, nullptr, 0, nullptr, 0, 0) < 0) {
            BCryptCloseAlgorithmProvider(algorithm_, 0); algorithm_ = nullptr;
            throw std::runtime_error("sha256_create_failed");
        }
    }
    ~Hash() {
        if (hash_) BCryptDestroyHash(hash_);
        if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
    }
    void Add(const void* bytes, ULONG size) {
        if (BCryptHashData(hash_, const_cast<PUCHAR>(static_cast<const UCHAR*>(bytes)), size, 0) < 0)
            throw std::runtime_error("sha256_read_failed");
    }
    std::string Finish() {
        std::array<UCHAR, 32> digest{};
        if (BCryptFinishHash(hash_, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0)
            throw std::runtime_error("sha256_finish_failed");
        constexpr char hex[] = "0123456789abcdef";
        std::string result(64, '0');
        for (std::size_t i = 0; i < digest.size(); ++i) {
            result[2 * i] = hex[digest[i] >> 4];
            result[2 * i + 1] = hex[digest[i] & 15];
        }
        return result;
    }
private:
    BCRYPT_ALG_HANDLE algorithm_ = nullptr;
    BCRYPT_HASH_HANDLE hash_ = nullptr;
};
void ReadMemory(std::uintptr_t source, void* destination, SIZE_T size) {
    SIZE_T count = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(source),
                           destination, size, &count) || count != size)
        throw std::runtime_error("loaded_image_unreadable");
}
bool ExactFile(HMODULE module) {
    std::vector<wchar_t> path(32768);
    const auto length = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) return false;
    // Hold a read-only, non-write-shared handle while checking the complete file.
    Handle file(CreateFileW(path.data(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.get() == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.get(), &size) || size.QuadPart != FileSize) return false;
    Hash hash;
    std::array<UCHAR, 65536> buffer{};
    LONGLONG total = 0;
    for (;;) {
        DWORD read = 0;
        if (!ReadFile(file.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) return false;
        if (!read) break;
        total += read;
        if (total > FileSize) return false;
        hash.Add(buffer.data(), read);
    }
    return total == FileSize && hash.Finish() == FileHash;
}
void VerifyImage(HMODULE module, DWORD mappedSize) {
    if (mappedSize != ImageSize) throw std::runtime_error("loaded_image_size_mismatch");
    const auto base = reinterpret_cast<std::uintptr_t>(module);
    IMAGE_DOS_HEADER dos{};
    ReadMemory(base, &dos, sizeof(dos));
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 64 ||
        static_cast<std::uint64_t>(dos.e_lfanew) + sizeof(IMAGE_NT_HEADERS64) > ImageSize)
        throw std::runtime_error("loaded_dos_header_mismatch");
    IMAGE_NT_HEADERS64 nt{};
    ReadMemory(base + static_cast<std::uintptr_t>(dos.e_lfanew), &nt, sizeof(nt));
    if (nt.Signature != IMAGE_NT_SIGNATURE || nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC || nt.OptionalHeader.SizeOfImage != ImageSize)
        throw std::runtime_error("loaded_pe_header_mismatch");
    static_assert(FunctionRva + FunctionSize < ImageSize && VersionRva + 12 < ImageSize);
    std::vector<UCHAR> function(FunctionSize);
    ReadMemory(base + FunctionRva, function.data(), function.size());
    Hash hash; hash.Add(function.data(), static_cast<ULONG>(function.size()));
    if (hash.Finish() != FunctionHash) throw std::runtime_error("loaded_setresource_signature_mismatch");
    MEMORY_BASIC_INFORMATION page{};
    const auto address = base + VersionRva;
    if (VirtualQuery(reinterpret_cast<const void*>(address), &page, sizeof(page)) != sizeof(page) ||
        page.AllocationBase != module || page.State != MEM_COMMIT || page.Type != MEM_IMAGE ||
        (page.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0 ||
        address + 12 > reinterpret_cast<std::uintptr_t>(page.BaseAddress) + page.RegionSize)
        throw std::runtime_error("loaded_version_storage_unavailable");
    std::array<std::uint32_t, 3> version{};
    ReadMemory(address, version.data(), sizeof(version));
}
HMODULE FindVerifiedModule() {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId()));
    if (snapshot.get() == INVALID_HANDLE_VALUE) throw std::runtime_error("module_snapshot_failed");
    MODULEENTRY32W entry{}; entry.dwSize = sizeof(entry);
    if (!Module32FirstW(snapshot.get(), &entry)) throw std::runtime_error("module_enumeration_failed");
    HMODULE selected = nullptr;
    do {
        if (_wcsicmp(entry.szModule, L"dxgi.dll") != 0 || entry.modBaseSize != ImageSize) continue;
        if (!ExactFile(entry.hModule)) continue;
        VerifyImage(entry.hModule, entry.modBaseSize);
        if (selected) throw std::runtime_error("multiple_matching_optiscaler_modules");
        selected = entry.hModule;
    } while (Module32NextW(snapshot.get(), &entry));
    if (GetLastError() != ERROR_NO_MORE_FILES) throw std::runtime_error("module_enumeration_incomplete");
    if (!selected) throw std::runtime_error("exact_optiscaler_module_not_found");
    HMODULE pinned = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(selected), &pinned) || pinned != selected)
        throw std::runtime_error("optiscaler_module_pin_failed");
    // Recheck the live function after pinning, before publishing any hook.
    VerifyImage(pinned, ImageSize);
    return pinned;
}
} // namespace

Decision Decide(const Policy& policy, std::uintptr_t caller, ID3D12GraphicsCommandList* list,
                UINT count, const D3D12_RESOURCE_BARRIER* barriers) noexcept {
    if (!policy.verified || !policy.expectedReturn) return Decision::Unverified;
    if (caller != policy.expectedReturn) return Decision::OtherCall;
    if (!list || count != 1 || !barriers || barriers[0].Type != D3D12_RESOURCE_BARRIER_TYPE_TRANSITION ||
        barriers[0].Flags != D3D12_RESOURCE_BARRIER_FLAG_NONE ||
        !barriers[0].Transition.pResource ||
        barriers[0].Transition.Subresource != D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES ||
        barriers[0].Transition.StateBefore != D3D12_RESOURCE_STATE_COPY_DEST ||
        barriers[0].Transition.StateAfter != D3D12_RESOURCE_STATE_COPY_SOURCE)
        return Decision::PatternMismatch;
    const auto v = policy.version;
    if (!v.major || (v.major == 1 && (v.minor < 2 || (v.minor == 2 && v.patch < 2))))
        return Decision::OldOrUnknownVersion;
    return Decision::Suppress;
}
Decision Forward(const Policy& policy, std::uintptr_t caller, BarrierFn original,
                 ID3D12GraphicsCommandList* list, UINT count, const D3D12_RESOURCE_BARRIER* barriers) {
    const auto decision = Decide(policy, caller, list, count, barriers);
    if (decision != Decision::Suppress) original(list, count, barriers);
    return decision;
}

Guard* Guard::instance_ = nullptr;
void Guard::Emit(const char* message) const noexcept { try { if (log_) log_(message); } catch (...) {} }
Version Guard::CurrentVersion() const noexcept {
    if (!version_) return {};
    // Exact SetResource initializes this immutable static cache before reaching
    // the matching barrier call. Zero values before its first call never admit.
    return {version_[0], version_[1], version_[2]};
}
bool Guard::Initialize(ID3D12GraphicsCommandList* list, LogFn log) noexcept {
    if (attempted_.exchange(true)) return ready_.load();
    log_ = log;
    bool created = false;
    try {
        if (!list || list->GetType() != D3D12_COMMAND_LIST_TYPE_DIRECT || instance_)
            throw std::runtime_error("guard_initialization_rejected");
        module_ = FindVerifiedModule();
        const auto base = reinterpret_cast<std::uintptr_t>(module_);
        expectedReturn_ = base + ReverseReturnRva;
        version_ = reinterpret_cast<const volatile std::uint32_t*>(base + VersionRva);
        target_ = (*reinterpret_cast<void***>(list))[26];
        if (!target_) throw std::runtime_error("resource_barrier_method_missing");
        const auto status = MH_CreateHook(target_, reinterpret_cast<void*>(&Hook),
                                          reinterpret_cast<void**>(&original_));
        if (status != MH_OK) throw std::runtime_error(MH_StatusToString(status));
        created = true;
        instance_ = this; // Owner must live for process lifetime, like Adapter.
        const auto enabled = MH_EnableHook(target_);
        if (enabled != MH_OK) throw std::runtime_error(MH_StatusToString(enabled));
        ready_.store(true);
        Emit("event=xefg_barrier_guard status=ready exact_opti_sha=ba4df99acf55278c617780d56b89847553063ebc8e521bf831e09d21d5c0b04b return_rva=0x126d72 threshold=1.2.2 runtime_validated=false graphics_fix_verified=false");
        return true;
    } catch (const std::exception& error) {
        ready_.store(false);
        if (created) {
            // Only our successfully-created hook is touched. If cleanup cannot
            // complete, the pinned owner remains and its disabled policy forwards.
            const auto disabled = MH_DisableHook(target_);
            if (disabled == MH_OK || disabled == MH_ERROR_DISABLED) MH_RemoveHook(target_);
        }
        char message[384]{};
        std::snprintf(message, sizeof(message), "event=xefg_barrier_guard status=disabled reason=%s nr_unchanged=true runtime_validated=false", error.what());
        Emit(message);
    } catch (...) {
        ready_.store(false);
        if (created) {
            const auto disabled = MH_DisableHook(target_);
            if (disabled == MH_OK || disabled == MH_ERROR_DISABLED) MH_RemoveHook(target_);
        }
        Emit("event=xefg_barrier_guard status=disabled reason=unknown_initialization_failure nr_unchanged=true runtime_validated=false");
    }
    return false;
}
void STDMETHODCALLTYPE Guard::Hook(ID3D12GraphicsCommandList* list, UINT count,
                                  const D3D12_RESOURCE_BARRIER* barriers) {
#if defined(_MSC_VER)
    const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
#else
    const auto caller = reinterpret_cast<std::uintptr_t>(__builtin_return_address(0));
#endif
    auto* self = instance_;
    if (caller != self->expectedReturn_ || !self->ready_.load()) {
        self->original_(list, count, barriers); return;
    }
    ++self->exactSiteSeen_;
    const Policy policy{true, self->expectedReturn_, self->CurrentVersion()};
    const auto decision = Forward(policy, caller, self->original_, list, count, barriers);
    if (decision == Decision::Suppress) {
        const auto suppressed = ++self->suppressed_;
        if (suppressed == 1) {
            char message[384]{};
            std::snprintf(message, sizeof(message),
                "event=xefg_barrier_suppressed first=true provider_version=%u.%u.%u return_rva=0x126d72 before=1024 after=2048 list=%p resource=%p runtime_validated=false graphics_fix_verified=false",
                policy.version.major, policy.version.minor, policy.version.patch,
                static_cast<void*>(list), static_cast<void*>(barriers[0].Transition.pResource));
            self->Emit(message);
        }
    } else if (decision == Decision::OldOrUnknownVersion) ++self->oldOrUnknownForwarded_;
    else if (decision == Decision::PatternMismatch) ++self->patternMismatch_;
}
CounterSnapshot Guard::Counters() const noexcept {
    return {attempted_.load(), ready_.load(), exactSiteSeen_.load(), suppressed_.load(),
            patternMismatch_.load(), oldOrUnknownForwarded_.load(), CurrentVersion()};
}
void Guard::Report() const noexcept {
    const auto c = Counters();
    char message[512]{};
    std::snprintf(message, sizeof(message),
        "event=xefg_barrier_stats attempted=%u ready=%u exact_site_seen=%llu suppressed=%llu pattern_mismatch=%llu old_or_unknown_forwarded=%llu provider_version=%u.%u.%u trigger_observed=%u runtime_validated=false graphics_fix_verified=false",
        unsigned(c.attempted), unsigned(c.ready), static_cast<unsigned long long>(c.exactSiteSeen),
        static_cast<unsigned long long>(c.suppressed), static_cast<unsigned long long>(c.patternMismatch),
        static_cast<unsigned long long>(c.oldOrUnknownForwarded), c.version.major, c.version.minor,
        c.version.patch, unsigned(c.suppressed != 0));
    Emit(message);
}
} // namespace nr030::xefg
