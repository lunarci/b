// SPDX-License-Identifier: GPL-3.0-only
// Experimental additive adapter. Exact-C7 static ABI only; not game validated.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <MinHook.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include "ffx_contract.h"
#include "input_contract.h"
#include "lifetime.h"
#include "predication.h"
#include "../runtime_contract.h"
#include "../components/component_contract.h"
#include "../components/pool_maintenance.h"
#include "../gpu_tests/shader_executor.h"

#ifndef NR030_ENABLE_EXPERIMENTAL_RUNTIME
#define NR030_ENABLE_EXPERIMENTAL_RUNTIME 0
#endif
#ifndef NR030_SOURCE_COMMIT
#define NR030_SOURCE_COMMIT "unrecorded"
#endif

namespace nr030 {
namespace {
namespace cmp = matheus030::components;
using Microsoft::WRL::ComPtr;
constexpr auto ReadState = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
constexpr auto WriteState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
constexpr std::size_t SlotCount = 8;
constexpr UINT64 AllocationLimit = 512ull * 1024ull * 1024ull;
HMODULE selfModule = nullptr;
std::atomic<bool> workerStarted{false};
std::filesystem::path moduleDirectory;
std::mutex logMutex;
thread_local unsigned nesting = 0;

std::string Utc() {
    SYSTEMTIME t{}; GetSystemTime(&t);
    char result[40]{};
    sprintf_s(result, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
        unsigned(t.wYear), unsigned(t.wMonth), unsigned(t.wDay), unsigned(t.wHour),
        unsigned(t.wMinute), unsigned(t.wSecond), unsigned(t.wMilliseconds));
    return result;
}
void Log(const std::string& message) noexcept {
    try {
        std::lock_guard guard(logMutex);
        FILE* file = nullptr;
        if (_wfopen_s(&file, (moduleDirectory / L"MatheusNR030.log").c_str(), L"ab") == 0 && file) {
            const auto line = message + "\r\n";
            fwrite(line.data(), 1, line.size(), file); fclose(file);
        }
    } catch (...) { }
}
void LifetimeLog(const char* message) {
    try { Log(std::string("event=lifetime detail=") + message); } catch (...) { }
}
void HookCheck(MH_STATUS status, const char* action) {
    if (status != MH_OK) throw std::runtime_error(std::string(action) + ": " + MH_StatusToString(status));
}
std::filesystem::path ModulePath(HMODULE module) {
    std::vector<wchar_t> path(32768);
    const auto count = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
    if (!count || count >= path.size()) throw std::runtime_error("Cannot resolve loaded module path");
    return std::filesystem::path(std::wstring(path.data(), count));
}
int IniInteger(const std::filesystem::path& path, const wchar_t* section, const wchar_t* key,
               int missingValue = -1) {
    wchar_t text[64]{};
    GetPrivateProfileStringW(section, key, L"", text, 64, path.c_str());
    if (!text[0]) return missingValue;
    wchar_t* end = nullptr;
    const auto result = wcstol(text, &end, 10);
    if (!end || *end || result < 0 || result > 100) return -1;
    return static_cast<int>(result);
}
bool BaseIniAllowed(const std::filesystem::path& runtimePath) {
    auto ini = runtimePath; ini.replace_filename(L"dlssnr_on_amd.ini");
    return IniInteger(ini, L"DlssNrOnAmd", L"Enabled") == 1 &&
           IniInteger(ini, L"DlssNrOnAmd", L"PreUpscale") == 1 &&
           IniInteger(ini, L"DlssNrOnAmd", L"Async") == 0;
}

class Sha256 {
    BCRYPT_ALG_HANDLE algorithm_ = nullptr;
    BCRYPT_HASH_HANDLE hash_ = nullptr;
    std::vector<UCHAR> object_;
public:
    Sha256() {
        DWORD size = 0, read = 0;
        if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
            throw std::runtime_error("Cannot open SHA-256 provider");
        if (BCryptGetProperty(algorithm_, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&size),
                              sizeof(size), &read, 0) < 0) {
            BCryptCloseAlgorithmProvider(algorithm_, 0); algorithm_ = nullptr;
            throw std::runtime_error("Cannot read SHA-256 object size");
        }
        try { object_.resize(size); }
        catch (...) { BCryptCloseAlgorithmProvider(algorithm_, 0); algorithm_ = nullptr; throw; }
        if (BCryptCreateHash(algorithm_, &hash_, object_.data(), size, nullptr, 0, 0) < 0) {
            BCryptCloseAlgorithmProvider(algorithm_, 0); algorithm_ = nullptr;
            throw std::runtime_error("Cannot create SHA-256 hash");
        }
    }
    ~Sha256() { if (hash_) BCryptDestroyHash(hash_); if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0); }
    void Append(const void* data, ULONG size) {
        if (BCryptHashData(hash_, const_cast<PUCHAR>(static_cast<const UCHAR*>(data)), size, 0) < 0)
            throw std::runtime_error("Cannot hash runtime bytes");
    }
    std::array<UCHAR, 32> Finish() {
        std::array<UCHAR, 32> digest{};
        if (BCryptFinishHash(hash_, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0)
            throw std::runtime_error("Cannot finish runtime hash");
        return digest;
    }
};
bool ImageRangeReadable(HMODULE module, const void* address, std::size_t length, bool executable = false) {
    auto cursor = reinterpret_cast<std::uintptr_t>(address);
    if (!length || cursor > UINTPTR_MAX - length) return false;
    const auto end = cursor + length;
    while (cursor < end) {
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<const void*>(cursor), &region, sizeof(region)) ||
            region.State != MEM_COMMIT || region.Type != MEM_IMAGE || region.AllocationBase != module ||
            (region.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return false;
        const auto protection = region.Protect & 0xffu;
        const bool executableRead = protection == PAGE_EXECUTE_READ ||
            protection == PAGE_EXECUTE_READWRITE || protection == PAGE_EXECUTE_WRITECOPY;
        const bool dataRead = protection == PAGE_READONLY || protection == PAGE_READWRITE || protection == PAGE_WRITECOPY;
        if (executable ? !executableRead : !(executableRead || dataRead)) return false;
        const auto next = reinterpret_cast<std::uintptr_t>(region.BaseAddress) + region.RegionSize;
        if (next <= cursor) return false;
        cursor = next;
    }
    return true;
}
bool VerifyRuntime(HMODULE module, const std::filesystem::path& path) {
    const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                     OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    bool verified = false;
    try {
        LARGE_INTEGER length{};
        if (!GetFileSizeEx(file, &length) || UINT64(length.QuadPart) != RuntimeContract::ExpectedFileSize)
            throw std::runtime_error("Runtime length differs");
        Sha256 hash;
        std::array<UCHAR, 65536> buffer{};
        DWORD count = 0;
        for (;;) {
            if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr))
                throw std::runtime_error("Runtime file read failed");
            if (!count) break;
            hash.Append(buffer.data(), count);
        }
        if (hash.Finish() != RuntimeContract::ExpectedSha256) throw std::runtime_error("Runtime SHA-256 differs");
        const auto* base = reinterpret_cast<const std::uint8_t*>(module);
        if (!ImageRangeReadable(module, base, sizeof(IMAGE_DOS_HEADER)))
            throw std::runtime_error("Runtime DOS header is not readable image memory");
        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > 0x100000)
            throw std::runtime_error("Runtime DOS header differs");
        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
        if (!ImageRangeReadable(module, nt, sizeof(*nt)))
            throw std::runtime_error("Runtime NT header is not readable image memory");
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
            nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
            nt->OptionalHeader.SizeOfImage != RuntimeContract::ExpectedImageSize ||
            RuntimeContract::HelperEndRva > nt->OptionalHeader.SizeOfImage)
            throw std::runtime_error("Runtime PE image differs");
        if (!ImageRangeReadable(module, base + RuntimeContract::HelperRva, RuntimeContract::HelperSize, true) ||
            !ImageRangeReadable(module, base + RuntimeContract::EnabledRva, 1) ||
            !ImageRangeReadable(module, base + RuntimeContract::PreUpscaleRva, sizeof(std::int32_t)))
            throw std::runtime_error("Runtime helper or mode fields have unexpected memory protection");
        const auto* sections = IMAGE_FIRST_SECTION(nt);
        if (nt->FileHeader.NumberOfSections == 0 || nt->FileHeader.NumberOfSections > 96 ||
            !ImageRangeReadable(module, sections, sizeof(*sections) * nt->FileHeader.NumberOfSections))
            throw std::runtime_error("Runtime section table is invalid");
        bool helperSection = false;
        for (unsigned index = 0; index < nt->FileHeader.NumberOfSections; ++index) {
            const auto& section = sections[index];
            const auto end = UINT64(section.VirtualAddress) + section.Misc.VirtualSize;
            if (section.VirtualAddress <= RuntimeContract::HelperRva && end >= RuntimeContract::HelperEndRva &&
                (section.Characteristics & IMAGE_SCN_MEM_READ) && (section.Characteristics & IMAGE_SCN_MEM_EXECUTE))
                helperSection = true;
        }
        if (!helperSection) throw std::runtime_error("Runtime helper is outside readable executable section");
        if (memcmp(base + RuntimeContract::SignatureRva, RuntimeContract::SignatureBytes.data(),
                   RuntimeContract::SignatureBytes.size()) != 0)
            throw std::runtime_error("Runtime helper is already modified or differs");
        Sha256 helper;
        helper.Append(base + RuntimeContract::HelperRva, RuntimeContract::HelperSize);
        verified = helper.Finish() == RuntimeContract::HelperSha256;
    } catch (const std::exception& error) { Log(std::string("event=runtime_rejected reason=") + error.what()); }
    CloseHandle(file);
    return verified;
}

bool SameDevice(ID3D12DeviceChild* child, ID3D12Device* expected) {
    ComPtr<ID3D12Device> actual;
    return child && SUCCEEDED(child->GetDevice(IID_PPV_ARGS(&actual))) && actual.Get() == expected;
}
ID3D12Resource* Resource(const ffx::Resource& resource) {
    return static_cast<ID3D12Resource*>(resource.resource);
}
std::string ResourceFacts(const char* label, const ffx::Resource& resource) {
    std::string result = std::string(" ") + label + "_present=" + std::to_string(resource.resource != nullptr) +
        " " + label + "_ffx_format=" + std::to_string(resource.description.format) +
        " " + label + "_state=" + std::to_string(resource.state) +
        " " + label + "_type=" + std::to_string(resource.description.type) +
        " " + label + "_width=" + std::to_string(resource.description.width) +
        " " + label + "_height=" + std::to_string(resource.description.height);
    if (resource.resource && resource.description.type == 2) {
        const auto actual = Resource(resource)->GetDesc();
        result += std::string(" ") + label + "_dxgi=" + std::to_string(actual.Format) +
            " " + label + "_texture_width=" + std::to_string(actual.Width) +
            " " + label + "_texture_height=" + std::to_string(actual.Height) +
            " " + label + "_mips=" + std::to_string(actual.MipLevels) +
            " " + label + "_samples=" + std::to_string(actual.SampleDesc.Count);
    }
    return result;
}
ffx::Resource AdaptResource(const ffx::Resource& source, ID3D12Resource* resource,
                            cmp::Extent2D extent, std::uint32_t format) {
    auto result = source;
    result.resource = resource;
    result.description.type = 2; // FFX_API_RESOURCE_TYPE_TEXTURE2D
    result.description.format = format;
    result.description.width = extent.width;
    result.description.height = extent.height;
    result.description.depth = 1;
    result.description.mipCount = 1;
    result.description.flags = 0; // FFX_API_RESOURCE_FLAGS_NONE
    result.description.usage = 2; // FFX_API_RESOURCE_USAGE_UAV: actual allocation has ALLOW_UNORDERED_ACCESS
    result.state = ffx::ComputeRead;
    return result;
}

struct Slot {
    ComPtr<ID3D12Resource> baseline, lowDepth, lowMotion, fullResolved;
    ComPtr<ID3D12DescriptorHeap> descriptors;
    std::shared_ptr<RecordingUse> use;
    bool resolved = false;
    UINT64 bytes = 0, lastUsedMs = 0;
};
struct Frame {
    Slot* slot;
    ffx::DispatchFn original;
    void** context;
    ffx::UpscaleDispatch full;
    cmp::ScalePlan plan;
    bool called = false;
    std::uint32_t result = 0;
    PredicationScope* predication = nullptr;
};
thread_local Frame* activeFrame = nullptr;

class Adapter {
public:
    HMODULE runtime = nullptr;
    ffx::HelperFn helper = nullptr;
    cmp::FixedScale scale = cmp::FixedScale::Percent85;
    int colourPreservation = 100, depthProtection = 1, effectPercent = 50, lumaStability = 100;
    bool trimIdleScratch = true, diagnostics = true;
    std::atomic<bool> failed{false};
    std::mutex mutex;
    RecordingLifetime lifetime;
    PredicationTracker predication;
    ComPtr<ID3D12Device> device;
    ComPtr<IDXGIAdapter3> memoryAdapter;
    gpu::ShaderExecutor shaders;
    std::array<Slot, SlotCount> slots{};
    void** admittedContext = nullptr;
    void* admittedContextValue = nullptr;
    cmp::Extent2D admittedExtent{};
    std::atomic<UINT64> allocatedBytes{0};
    std::atomic<unsigned> allocatedSlots{0};
    std::atomic<UINT64> seen{0}, scaled{0}, nrRecorded{0}, resolved{0}, originalColorPassthrough{0}, fallback{0}, gpuCompleted{0};
    UINT64 admissionDeferred = 0;
    UINT64 predicateAdmitted = 0, predicateUnknown = 0, predicateActive = 0, predicateUntracked = 0;
    UINT64 retiredUses = 0, releasedBorrowedRefs = 0, trimmedSlots = 0, trimmedBytes = 0;
    UINT64 lastDiagnosticMs = 0;
    UINT64 resetDispatches = 0;
    std::atomic<const char*> lastFallbackReason{"none"};

    // Called while holding the adapter mutex, BEFORE any eligibility fallback.
    // Reclaim safe uses across the whole pool rather than only the chosen slot.
    // GPU-complete but replayable/unobserved recordings remain pinned.
    void Maintain(const ffx::UpscaleDispatch* desc) noexcept {
        if (!device) return;
        try {
            const auto now = GetTickCount64();
            const bool validDesc = desc && desc->header.type == ffx::UpscaleType;
            if (validDesc && desc->reset) ++resetDispatches;
            cmp::sweep_completed(slots,
                [this](const auto& use) { return lifetime.Reusable(use); },
                [this](auto& slot) {
                    if (slot.resolved) ++gpuCompleted;
                    ++retiredUses; releasedBorrowedRefs += slot.use->borrowed.size();
                    slot.use.reset(); slot.resolved = false;
                });
            if (trimIdleScratch) for (auto it = slots.rbegin(); it != slots.rend(); ++it) {
                auto& slot = *it;
                if (!cmp::trim_idle_scratch(bool(slot.use), bool(slot.baseline), now,
                                           slot.lastUsedMs, allocatedSlots.load())) continue;
                const auto bytes = slot.bytes;
                slot = Slot{};
                allocatedBytes -= bytes; --allocatedSlots;
                ++trimmedSlots; trimmedBytes += bytes;
            }
            if (!diagnostics || now - lastDiagnosticMs < 1000) return;
            lastDiagnosticMs = now;
            unsigned retained = 0;
            for (const auto& slot : slots) if (slot.use) ++retained;
            DXGI_QUERY_VIDEO_MEMORY_INFO local{}, nonlocal{};
            const bool localOk = memoryAdapter && SUCCEEDED(memoryAdapter->QueryVideoMemoryInfo(
                0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local));
            const bool nonlocalOk = memoryAdapter && SUCCEEDED(memoryAdapter->QueryVideoMemoryInfo(
                0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &nonlocal));
            Log("event=pool_sample tick_ms=" + std::to_string(now) +
                " seen=" + std::to_string(seen.load()) + " scaled=" + std::to_string(scaled.load()) +
                " resolved=" + std::to_string(resolved.load()) + " fallback=" + std::to_string(fallback.load()) +
                " allocated_bytes=" + std::to_string(allocatedBytes.load()) +
                " allocated_slots=" + std::to_string(allocatedSlots.load()) +
                " retained_uses=" + std::to_string(retained) +
                " retired_uses=" + std::to_string(retiredUses) +
                " released_borrowed_refs=" + std::to_string(releasedBorrowedRefs) +
                " trimmed_slots=" + std::to_string(trimmedSlots) +
                " trimmed_bytes=" + std::to_string(trimmedBytes) +
                " local_valid=" + std::to_string(localOk) +
                " local_usage_bytes=" + std::to_string(local.CurrentUsage) +
                " local_budget_bytes=" + std::to_string(local.Budget) +
                " nonlocal_valid=" + std::to_string(nonlocalOk) +
                " nonlocal_usage_bytes=" + std::to_string(nonlocal.CurrentUsage) +
                " ffx_frame_time_ms=" + std::to_string(validDesc ? desc->frameTimeDelta : 0.0f) +
                " ffx_reset=" + std::to_string(validDesc && desc->reset) +
                " reset_dispatches=" + std::to_string(resetDispatches) +
                " addon_failed=" + std::to_string(failed.load()) +
                " last_fallback_ever=" + lastFallbackReason.load());
        } catch (...) { /* Diagnostics must never prevent game dispatch. */ }
    }

    bool LiveModeAllowed() const {
        const auto* base = reinterpret_cast<const std::uint8_t*>(runtime);
        return (*reinterpret_cast<const volatile std::uint8_t*>(base + RuntimeContract::EnabledRva) & 1u) &&
            *reinterpret_cast<const volatile std::int32_t*>(base + RuntimeContract::PreUpscaleRva) != 0;
    }
    void InputDiagnostic(const ffx::UpscaleDispatch* desc, const char* issue) const noexcept {
        if (!diagnostics || (seen.load() != 1 && seen.load() % 120 != 0)) return;
        try {
            std::string line = std::string("event=input_check reason=") + (issue ? issue : "accepted");
            if (desc) line += " dispatch_type=" + std::to_string(desc->header.type) +
                " has_extension=" + std::to_string(desc->header.next != nullptr);
            if (desc && desc->header.type == ffx::UpscaleType) {
                line += " render_width=" + std::to_string(desc->renderSize.width) +
                    " render_height=" + std::to_string(desc->renderSize.height) +
                    ResourceFacts("color", desc->color) + ResourceFacts("depth", desc->depth) +
                    ResourceFacts("motion", desc->motionVectors);
            }
            Log(line);
        } catch (...) { }
    }
    void Stats(bool force = false) const {
        const auto count = seen.load();
        if (!force && count != 1 && count % 120 != 0) return;
        Log("event=frame seen=" + std::to_string(count) + " scaled=" + std::to_string(scaled.load()) +
            " nr_recorded=" + std::to_string(nrRecorded.load()) + " resolved=" + std::to_string(resolved.load()) +
            " fallback=" + std::to_string(fallback.load()) + " gpu_completed=" + std::to_string(gpuCompleted.load()) +
            " allocated_bytes=" + std::to_string(allocatedBytes.load()) + " allocated_slots=" + std::to_string(allocatedSlots.load()));
        Log("event=original_color_stats passthrough=" + std::to_string(originalColorPassthrough.load()) +
            " seen=" + std::to_string(count) + " nr_recorded=" + std::to_string(nrRecorded.load()));
        const auto predicate = predication.Counters();
        Log("event=predication_stats admitted=" + std::to_string(predicateAdmitted) +
            " bypass_unknown=" + std::to_string(predicateUnknown) +
            " bypass_active=" + std::to_string(predicateActive) +
            " bypass_untracked=" + std::to_string(predicateUntracked) +
            " observed_sets=" + std::to_string(predicate.observedSets) +
            " observed_resets=" + std::to_string(predicate.observedResets) +
            " observed_clears=" + std::to_string(predicate.observedClears) +
            " private_sets=" + std::to_string(predicate.privateSets) +
            " private_restores=" + std::to_string(predicate.privateRestores) +
            " tracked_lists=" + std::to_string(predicate.trackedLists) +
            " capacity_bypass=" + std::to_string(predicate.capacityBypass));
    }
    std::uint32_t Fallback(ffx::DispatchFn original, void** context, const ffx::UpscaleDispatch* desc,
                           const char* reason, bool direct = false) {
        const auto count = ++fallback;
        lastFallbackReason.store(reason);
        if (count == 1 || count % 120 == 0) Log(std::string("event=fallback reason=") + reason);
        // A rejected 75/85% path must not silently run expensive, unscaled NR.
        // Restore ordinary FFX input immediately. The explicit 100% comparison
        // mode reaches the original NR helper separately in HelperHook.
        const auto value = original(context, desc ? &desc->header : nullptr);
        // Direct admission failures can be on a competing thread without the
        // adapter mutex. Only its owner emits a coherent frame snapshot.
        if (!direct) Stats();
        return value;
    }
    static D3D12_RESOURCE_DESC TextureDescription(cmp::Extent2D extent, DXGI_FORMAT format) {
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = extent.width; desc.Height = extent.height;
        desc.DepthOrArraySize = 1; desc.MipLevels = 1; desc.Format = format;
        desc.SampleDesc.Count = 1; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        return desc;
    }
    ComPtr<ID3D12Resource> Texture(cmp::Extent2D extent, DXGI_FORMAT format) {
        const auto desc = TextureDescription(extent, format);
        const auto allocation = device->GetResourceAllocationInfo(0, 1, &desc);
        if (allocation.SizeInBytes == UINT64_MAX || allocation.SizeInBytes > AllocationLimit - allocatedBytes.load())
            throw std::runtime_error("Addon 512 MiB resource allocation ceiling reached");
        D3D12_HEAP_PROPERTIES heap{}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        heap.CreationNodeMask = 1; heap.VisibleNodeMask = 1;
        ComPtr<ID3D12Resource> result;
        gpu::Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, ReadState,
                   nullptr, IID_PPV_ARGS(&result)), "Create additive scratch texture");
        allocatedBytes += allocation.SizeInBytes;
        return result;
    }
    void Initialize(ID3D12GraphicsCommandList* commands, void** context, const cmp::ScalePlan& plan) {
        try {
        gpu::Check(commands->GetDevice(IID_PPV_ARGS(&device)), "Resolve command-list device");
        // Optional read-only memory telemetry for this exact D3D12 adapter.
        ComPtr<IDXGIFactory4> factory;
        if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))
            factory->EnumAdapterByLuid(device->GetAdapterLuid(), IID_PPV_ARGS(&memoryAdapter));
        if (commands->GetType() != D3D12_COMMAND_LIST_TYPE_DIRECT)
            throw std::runtime_error("Only direct game command lists are supported");
        std::array<gpu::BytecodeView, 4> code{};
        for (UINT i = 0; i < code.size(); ++i) {
            const auto resource = FindResourceW(selfModule, MAKEINTRESOURCEW(101 + i), MAKEINTRESOURCEW(10));
            if (!resource) throw std::runtime_error("Embedded production shader is missing");
            const auto loaded = LoadResource(selfModule, resource);
            code[i] = {LockResource(loaded), SizeofResource(selfModule, resource)};
        }
        shaders.InitializeBytecode(device.Get(), code);
        predication.Initialize(commands);
        lifetime.Initialize(device.Get(), commands, &LifetimeLog, &PredicationTracker::ResetObserver, &predication);
        Log("event=predication_mode admission=observed_disabled_only active_or_unknown=skip_nr preserve_before_ffx=true scale100_covered=false");
        admittedContext = context; admittedContextValue = context ? *context : nullptr;
        admittedExtent = plan.input;
        Log("event=adapter_ready input_width=" + std::to_string(plan.input.width) +
            " input_height=" + std::to_string(plan.input.height) + " nr_width=" +
            std::to_string(plan.neural.width) + " nr_height=" + std::to_string(plan.neural.height));
        } catch (...) {
            // Partially installed hooks/objects remain pinned, and admission is
            // permanently stopped. Never retry an uncertain hook installation.
            failed.store(true);
            throw;
        }
    }
    Slot& Acquire(const cmp::ScalePlan& plan) {
        for (auto& slot : slots) {
            if (slot.use) continue; // Maintain() has already swept every safe use.
            if (!slot.baseline) {
                Slot complete;
                const auto before = allocatedBytes.load();
                // Test the complete set before any allocation, so a budget-limited
                // frame cannot repeatedly allocate and release partial slots.
                const D3D12_RESOURCE_DESC required[] = {
                    TextureDescription(plan.neural, DXGI_FORMAT_R16G16B16A16_FLOAT),
                    TextureDescription(plan.neural, DXGI_FORMAT_R32_FLOAT),
                    TextureDescription(plan.neural, DXGI_FORMAT_R16G16_FLOAT),
                    TextureDescription(plan.input, DXGI_FORMAT_R16G16B16A16_FLOAT)};
                UINT64 needed = 0;
                for (const auto& texture : required) {
                    const auto allocation = device->GetResourceAllocationInfo(0, 1, &texture);
                    if (allocation.SizeInBytes == UINT64_MAX || allocation.SizeInBytes > AllocationLimit - needed)
                        throw std::runtime_error("Scratch slot cannot fit the resource budget");
                    needed += allocation.SizeInBytes;
                }
                if (needed > AllocationLimit - before)
                    throw std::runtime_error("Scratch budget exhausted; existing slots await reuse");
                try {
                complete.baseline = Texture(plan.neural, DXGI_FORMAT_R16G16B16A16_FLOAT);
                complete.lowDepth = Texture(plan.neural, DXGI_FORMAT_R32_FLOAT);
                complete.lowMotion = Texture(plan.neural, DXGI_FORMAT_R16G16_FLOAT);
                complete.fullResolved = Texture(plan.input, DXGI_FORMAT_R16G16B16A16_FLOAT);
                D3D12_DESCRIPTOR_HEAP_DESC desc{};
                desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
                desc.NumDescriptors = 4 * gpu::ShaderExecutor::DescriptorCount;
                desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
                gpu::Check(device->CreateDescriptorHeap(&desc, IID_PPV_ARGS(&complete.descriptors)),
                           "Create private dispatch descriptor ranges");
                } catch (...) { allocatedBytes = before; throw; }
                complete.bytes = allocatedBytes.load() - before;
                slot = std::move(complete);
                ++allocatedSlots;
            }
            slot.lastUsedMs = GetTickCount64();
            return slot;
        }
        throw std::runtime_error("All eight slots await observed queue completion and Reset");
    }
    void Downsample(Slot& slot, ID3D12GraphicsCommandList* commands,
                    const ffx::UpscaleDispatch& full, const cmp::ScalePlan& plan) {
        const auto constants = plan.colour_constants();
        const std::array<gpu::TextureBinding, 3> inputs{{
            {Resource(full.color), DXGI_FORMAT_R16G16B16A16_FLOAT},
            {Resource(full.depth), DXGI_FORMAT_R32_FLOAT},
            {Resource(full.motionVectors), input::MotionViewFormat(full.motionVectors)}}};
        const std::array<gpu::TextureBinding, 3> output{{
            {slot.baseline.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT},
            {slot.lowDepth.Get(), DXGI_FORMAT_R32_FLOAT},
            {slot.lowMotion.Get(), DXGI_FORMAT_R16G16_FLOAT}}};
        for (UINT index = 0; index < inputs.size(); ++index) {
            gpu::Transition(commands, output[index].resource, ReadState, WriteState);
            try {
            shaders.Record(static_cast<gpu::Kernel>(index), commands, slot.descriptors.Get(),
                index * gpu::ShaderExecutor::DescriptorCount, &constants, 4, &inputs[index], 1,
                output[index], plan.neural.width, plan.neural.height);
            } catch (...) {
                gpu::Transition(commands, output[index].resource, WriteState, ReadState);
                throw;
            }
            gpu::Transition(commands, output[index].resource, WriteState, ReadState);
        }
    }
    std::uint32_t After(Frame& frame, void** context, const ffx::Header* header) {
        if (frame.called) { failed.store(true); return frame.result; }
        // Claim the real dispatch BEFORE calling it, including any re-entrancy.
        frame.called = true;
        auto dispatch = frame.full;
        const auto* corrected = reinterpret_cast<const ffx::UpscaleDispatch*>(header);
        const bool callbackMatches = context == frame.context && corrected &&
            corrected->header.type == ffx::UpscaleType &&
            corrected->commandList == frame.full.commandList;
        if (callbackMatches &&
            corrected->color.resource != frame.slot->baseline.Get() &&
            !input::TextureRejection(corrected->color, frame.plan.neural, ffx::FormatRgba16Float,
                                     DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16B16A16_TYPELESS) &&
            SameDevice(Resource(corrected->color), device.Get())) {
            ++nrRecorded;
            try {
                frame.slot->use->borrowed.emplace_back(Resource(corrected->color));
                if (effectPercent == 0) {
                    // Diagnostic comparison: NR capture/inference/wait still run,
                    // but FSR receives the untouched ORIGINAL color resource.
                    // Keep the NR output alive for its already-recorded GPU use.
                    // Positive effects retain the existing resolve path below.
                    ++originalColorPassthrough;
                } else {
                const auto constants = frame.plan.resolve_constants(colourPreservation / 100.0f,
                    depthProtection != 0, effectPercent / 100.0f, static_cast<std::uint32_t>(lumaStability));
                const gpu::TextureBinding inputs[] = {
                    {Resource(frame.full.color), DXGI_FORMAT_R16G16B16A16_FLOAT},
                    {frame.slot->baseline.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT},
                    {Resource(corrected->color), DXGI_FORMAT_R16G16B16A16_FLOAT},
                    {Resource(frame.full.depth), DXGI_FORMAT_R32_FLOAT}};
                const gpu::TextureBinding output{frame.slot->fullResolved.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT};
                auto* commands = static_cast<ID3D12GraphicsCommandList*>(frame.full.commandList);
                gpu::Transition(commands, output.resource, ReadState, WriteState);
                try {
                shaders.Record(gpu::Kernel::Residual, commands, frame.slot->descriptors.Get(),
                    3 * gpu::ShaderExecutor::DescriptorCount, &constants, 8, inputs, 4,
                    output, frame.plan.input.width, frame.plan.input.height);
                } catch (...) {
                    gpu::Transition(commands, output.resource, WriteState, ReadState);
                    throw;
                }
                gpu::Transition(commands, output.resource, WriteState, ReadState);
                dispatch.color = AdaptResource(frame.full.color, output.resource, frame.plan.input,
                                               ffx::FormatRgba16Float);
                frame.slot->resolved = true; ++resolved;
                }
            } catch (const std::exception& error) {
                failed.store(true); ++fallback;
                lastFallbackReason.store("resolve_record_failed");
                Log(std::string("event=resolve_disabled reason=") + error.what());
            }
        } else {
            // Record(false) passes the low input through unchanged, including
            // normal startup/busy skips. Retry later instead of latching a fault.
            const char* reason = callbackMatches &&
                corrected->color.resource == frame.slot->baseline.Get()
                ? "nr_output_unavailable" : "nr_output_incompatible";
            lastFallbackReason.store(reason);
            const auto count = ++fallback;
            if (count == 1 || count % 120 == 0)
                Log(std::string("event=fallback reason=") + reason);
        }
        if (frame.predication) frame.predication->Restore();
        frame.result = frame.original(frame.context, &dispatch.header);
        return frame.result;
    }
};
// Deliberately process lifetime: command lists can outlive plugin loader scopes.
Adapter* app = nullptr;
std::uint32_t __fastcall AfterNr(void** context, const ffx::Header* desc) {
    if (!activeFrame || !app) return 1u;
    return app->After(*activeFrame, context, desc);
}
struct NestingGuard { NestingGuard() { ++nesting; } ~NestingGuard() { --nesting; } };
struct FrameGuard {
    Frame* before;
    explicit FrameGuard(Frame* frame) : before(activeFrame) { activeFrame = frame; }
    ~FrameGuard() { activeFrame = before; }
};
std::uint32_t __fastcall HelperHook(ffx::DispatchFn original, void** context, const ffx::UpscaleDispatch* desc) {
    if (!original) return 1u;
    if (nesting) return original(context, desc ? &desc->header : nullptr);
    NestingGuard depth;
    ++app->seen;
    if (app->scale == cmp::FixedScale::Percent100)
        return app->helper(original, context, desc);
    // A competing dispatch must never resize the NR runtime while low NR is being recorded.
    std::unique_lock guard(app->mutex, std::try_to_lock);
    if (!guard.owns_lock()) return app->Fallback(original, context, desc, "concurrent_dispatch", true);
    app->Maintain(desc);
    const char* issue = app->failed.load() ? "adapter_failed" :
        !app->LiveModeAllowed() ? "base_mode_disabled" :
        (!context || !*context) ? "context_missing" : input::Rejection(desc);
    app->InputDiagnostic(desc, issue);
    if (issue) return app->Fallback(original, context, desc, issue);
    auto* commands = static_cast<ID3D12GraphicsCommandList*>(desc->commandList);
    const auto plan = cmp::make_scale_plan({desc->renderSize.width, desc->renderSize.height}, app->scale);
    if (!plan.scaled) return app->Fallback(original, context, desc, "extent_not_scaled");
    const auto admissionError = [](const std::exception& error) {
        const auto deferred = ++app->admissionDeferred;
        if (deferred == 1 || deferred % 120 == 0)
            Log(std::string("event=admission_deferred reason=") + error.what());
        if (app->lifetime.HasUnknownUse()) app->failed.store(true);
    };
    bool initializationFailed = false;
    try {
        if (!app->device) app->Initialize(commands, context, plan);
    } catch (const std::exception& error) {
        admissionError(error); initializationFailed = true;
    }
    // Real FFX callbacks stay outside our catches, even on admission rejection.
    if (initializationFailed)
        return app->Fallback(original, context, desc, "scratch_or_lifetime_unavailable");
    if (context != app->admittedContext || *context != app->admittedContextValue)
        return app->Fallback(original, context, desc, "context_changed");
    if (plan.input.width != app->admittedExtent.width || plan.input.height != app->admittedExtent.height)
        return app->Fallback(original, context, desc, "render_extent_changed");
    if (commands->GetType() != D3D12_COMMAND_LIST_TYPE_DIRECT || !app->lifetime.Covers(commands) ||
        !SameDevice(commands, app->device.Get()) ||
        !SameDevice(Resource(desc->color), app->device.Get()) ||
        !SameDevice(Resource(desc->depth), app->device.Get()) ||
        !SameDevice(Resource(desc->motionVectors), app->device.Get()))
        return app->Fallback(original, context, desc, "device_or_tracking_changed");

    // Registration precedes both Begin() and all private GPU recording. An
    // unknown first recording can therefore become known at its next real Reset.
    PredicationScope predicate(app->predication, commands);
    if (!predicate.Admitted()) {
        const char* reason = "caller_predication_untracked";
        if (predicate.State() == PredicationState::Unknown) {
            ++app->predicateUnknown; reason = "caller_predication_unknown";
        } else if (predicate.State() == PredicationState::Active) {
            ++app->predicateActive; reason = "caller_predication_active";
        } else ++app->predicateUntracked;
        return app->Fallback(original, context, desc, reason);
    }
    ++app->predicateAdmitted;
    Slot* slot = nullptr;
    bool acquisitionFailed = false;
    try {
        slot = &app->Acquire(plan);
        slot->use = app->lifetime.Begin(commands);
        slot->use->borrowed.reserve(8);
        const ffx::Resource* resources[] = {&desc->color, &desc->depth, &desc->motionVectors, &desc->exposure,
            &desc->reactive, &desc->transparencyAndComposition, &desc->output};
        for (const auto* resource : resources)
            if (resource->resource) slot->use->borrowed.emplace_back(Resource(*resource));
    } catch (const std::exception& error) {
        admissionError(error); acquisitionFailed = true;
    }
    if (acquisitionFailed) {
        predicate.Restore();
        return app->Fallback(original, context, desc, "scratch_or_lifetime_unavailable");
    }
    Frame frame{slot, original, context, *desc, plan};
    frame.predication = &predicate;
    FrameGuard scope(&frame);
    const char* recordFailure = nullptr;
    try {
        auto low = *desc;
        low.color = AdaptResource(desc->color, slot->baseline.Get(), plan.neural, ffx::FormatRgba16Float);
        low.depth = AdaptResource(desc->depth, slot->lowDepth.Get(), plan.neural, ffx::FormatR32Float);
        low.motionVectors = AdaptResource(desc->motionVectors, slot->lowMotion.Get(), plan.neural, ffx::FormatRg16Float);
        low.renderSize = {plan.neural.width, plan.neural.height};
        const auto motion = cmp::neural_motion_multiplier(plan.input, plan.neural,
            {desc->motionVectorScale.x, desc->motionVectorScale.y});
        low.motionVectorScale = {motion.x, motion.y};
        low.jitterOffset = {desc->jitterOffset.x * (float(plan.neural.width) / float(plan.input.width)),
                            desc->jitterOffset.y * (float(plan.neural.height) / float(plan.input.height))};
        app->Downsample(*slot, commands, *desc, plan);
        ++app->scaled;
        const auto result = app->helper(&AfterNr, context, &low);
        if (!frame.called) {
            app->failed.store(true);
            Log("event=adapter_disabled reason=verified_helper_did_not_invoke_callback");
            recordFailure = "missing_callback";
        } else {
            app->Stats();
            return result;
        }
    } catch (const std::exception& error) {
        app->failed.store(true);
        Log(std::string("event=adapter_disabled reason=") + error.what());
        // Never dispatch FSR twice if it threw after the callback was entered.
        if (frame.called) throw;
        recordFailure = "record_exception";
    }
    predicate.Restore();
    return app->Fallback(original, context, desc, recordFailure, true);
}

DWORD WINAPI Worker(void*) {
    try {
        // Pin this ASI before installing hooks or retaining any GPU objects.
        HMODULE pinned = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(&Worker), &pinned)) return 0;
        moduleDirectory = ModulePath(selfModule).parent_path();
        FILE* log = nullptr;
        if (_wfopen_s(&log, (moduleDirectory / L"MatheusNR030.log").c_str(), L"wb") == 0 && log) fclose(log);
        Log("event=session_start utc=" + Utc() + " runtime_validated=false source_commit=" NR030_SOURCE_COMMIT);
        if (!NR030_ENABLE_EXPERIMENTAL_RUNTIME) {
            Log("event=disabled reason=experimental_runtime_not_enabled_at_build"); return 0;
        }
        const auto settings = moduleDirectory / L"MatheusNR030.ini";
        if (IniInteger(settings, L"MatheusNR030", L"Enabled") != 1) {
            Log("event=disabled reason=Enabled_not_1"); return 0;
        }
        const auto percent = IniInteger(settings, L"MatheusNR030", L"ScalePercent");
        if (percent != 75 && percent != 85 && percent != 100) {
            Log("event=disabled reason=ScalePercent_must_be_75_85_or_100"); return 0;
        }
        const auto colour = IniInteger(settings, L"MatheusNR030", L"ColourPreservationPercent", 100);
        const auto depthProtect = IniInteger(settings, L"MatheusNR030", L"DepthProtection", 1);
        const auto effect = IniInteger(settings, L"MatheusNR030", L"EffectPercent", 50);
        const auto stability = IniInteger(settings, L"MatheusNR030", L"LumaStabilityPercent", 100);
        const auto trim = IniInteger(settings, L"MatheusNR030", L"TrimIdleScratch", 1);
        const auto diagnostic = IniInteger(settings, L"MatheusNR030", L"Diagnostics", 1);
        if (colour < 0 || effect < 0 || stability < 0 || depthProtect < 0 || depthProtect > 1 ||
            trim < 0 || trim > 1 || diagnostic < 0 || diagnostic > 1) {
            Log("event=disabled reason=invalid_composite_settings"); return 0;
        }
        HMODULE runtime = nullptr;
        for (unsigned attempt = 0; attempt < 300 && !runtime; ++attempt) {
            runtime = GetModuleHandleW(L"dlssnr_on_amd.asi");
            if (!runtime) Sleep(200);
        }
        if (!runtime) { Log("event=disabled reason=NR_runtime_not_loaded"); return 0; }
        const auto runtimePath = ModulePath(runtime);
        if (!RuntimeContract::StaticAbiVerified || !BaseIniAllowed(runtimePath) || !VerifyRuntime(runtime, runtimePath)) {
            Log("event=disabled reason=base_mode_or_exact_C7_contract_rejected"); return 0;
        }
        HMODULE pinnedRuntime = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(runtime), &pinnedRuntime)) {
            Log("event=disabled reason=cannot_pin_runtime"); return 0;
        }
        app = new Adapter();
        app->runtime = runtime; app->scale = static_cast<cmp::FixedScale>(percent);
        app->colourPreservation = colour; app->depthProtection = depthProtect; app->effectPercent = effect;
        app->lumaStability = stability;
        app->trimIdleScratch = trim != 0; app->diagnostics = diagnostic != 0;
        const auto initialized = MH_Initialize();
        if (initialized != MH_OK && initialized != MH_ERROR_ALREADY_INITIALIZED)
            HookCheck(initialized, "Initialize hook engine");
        auto* target = reinterpret_cast<std::uint8_t*>(runtime) + RuntimeContract::HelperRva;
        HookCheck(MH_CreateHook(target, reinterpret_cast<void*>(&HelperHook),
            reinterpret_cast<void**>(&app->helper)), "Create fixed-C7 helper hook");
        HookCheck(MH_EnableHook(target), "Enable fixed-C7 helper hook");
        Log("event=hook_active static_abi_verified=true runtime_validated=false scale_percent=" + std::to_string(percent));
        Log("event=resolve_config version=0.2.4 colour_preservation_percent=" + std::to_string(colour) +
            " depth_protection=" + std::to_string(depthProtect) + " effect_percent=" + std::to_string(effect) +
            " applies_to_scaled_path_only=true");
        Log(std::string("event=effect_zero_handoff diagnostic_build=true mode=") +
            (effect == 0 ? "original_color_passthrough" : "positive_effect_resolve_unchanged") +
            " nr_execution_unchanged=true applies_to_scaled_path_only=true visual_verified=false");
        Log("event=pool_policy version=0.2.4 sweep_all_completed=1 idle_trim=" + std::to_string(trim) +
            " idle_ms=2000 warm_slots=2 diagnostics=" + std::to_string(diagnostic));
        Log("event=resolve_policy version=0.2.4 per_tap_guard_before_interpolation=1 temporal_filter=0");
        Log("event=luma_stability_config version=0.2.4 strength_percent=" + std::to_string(stability) +
            " applies_to_scaled_path_only=true temporal_filter=0");
        Log("event=fallback_policy version=0.2.4 rejected_scaled_path=fsr_without_nr explicit_scale100=original_nr");
    } catch (const std::exception& error) { Log(std::string("event=disabled reason=") + error.what()); }
    return 0;
}
} // namespace
} // namespace nr030

extern "C" __declspec(dllexport) void InitializeASI() {
    bool expected = false;
    if (!nr030::workerStarted.compare_exchange_strong(expected, true)) return;
    const HANDLE worker = CreateThread(nullptr, 0, &nr030::Worker, nullptr, 0, nullptr);
    if (worker) CloseHandle(worker);
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        nr030::selfModule = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}
