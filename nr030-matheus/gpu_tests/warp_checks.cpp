// SPDX-License-Identifier: GPL-3.0-only
// Runs the production HLSL and production dispatch code on Microsoft's D3D12 WARP.
// Fixtures are mathematical shader inputs, never a substitute or mock NR runtime.
#include "shader_executor.h"
#include "../components/component_contract.h"
#include <d3d12sdklayers.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using nr030::gpu::Check;
using nr030::gpu::Kernel;
using nr030::gpu::ShaderExecutor;
using nr030::gpu::TextureBinding;
using nr030::gpu::Transition;
namespace contract = matheus030::components;

namespace {
void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
std::uint16_t ToHalf(float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    const std::uint32_t sign = (bits >> 16) & 0x8000u;
    const std::uint32_t exponent = (bits >> 23) & 255u;
    std::uint32_t mantissa = bits & 0x7fffffu;
    if (exponent == 255u)
        return static_cast<std::uint16_t>(sign | 0x7c00u | (mantissa ? 0x0200u : 0u));
    const int e = static_cast<int>(exponent) - 127 + 15;
    if (e >= 31) return static_cast<std::uint16_t>(sign | 0x7c00u);
    if (e <= 0) {
        if (e < -10) return static_cast<std::uint16_t>(sign);
        mantissa |= 0x800000u;
        const unsigned shift = static_cast<unsigned>(14 - e);
        const std::uint32_t rounding = ((1u << (shift - 1)) - 1u) + ((mantissa >> shift) & 1u);
        return static_cast<std::uint16_t>(sign | ((mantissa + rounding) >> shift));
    }
    const std::uint32_t rounded = mantissa + 0xfffu + ((mantissa >> 13) & 1u);
    return static_cast<std::uint16_t>(sign | ((static_cast<std::uint32_t>(e) << 10) +
                                             (rounded >> 13)));
}
float FromHalf(std::uint16_t value) {
    const std::uint32_t sign = (static_cast<std::uint32_t>(value) & 0x8000u) << 16;
    std::uint32_t exponent = (value >> 10) & 31u;
    std::uint32_t mantissa = value & 1023u;
    std::uint32_t bits = sign;
    if (exponent == 0) {
        if (mantissa) {
            int shift = 0;
            while ((mantissa & 1024u) == 0) { mantissa <<= 1; ++shift; }
            bits |= static_cast<std::uint32_t>(113 - shift) << 23;
            bits |= (mantissa & 1023u) << 13;
        }
    } else if (exponent == 31u) {
        bits |= 0x7f800000u | (mantissa << 13);
    } else {
        bits |= (exponent + 112u) << 23;
        bits |= mantissa << 13;
    }
    float result = 0;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}
UINT Channels(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R32_FLOAT: return 1;
    case DXGI_FORMAT_R32G32_FLOAT: return 2;
    case DXGI_FORMAT_R32G32B32A32_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return 4;
    default: throw std::invalid_argument("Unsupported test texture format");
    }
}
UINT ComponentBytes(DXGI_FORMAT format) {
    return format == DXGI_FORMAT_R16G16B16A16_FLOAT ? 2u : 4u;
}
struct Image {
    UINT width = 0, height = 0;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    std::vector<float> pixels;
    Image(UINT w, UINT h, DXGI_FORMAT f)
        : width(w), height(h), format(f), pixels(static_cast<size_t>(w) * h * Channels(f)) {}
    float& At(UINT x, UINT y, UINT channel) {
        return pixels[(static_cast<size_t>(y) * width + x) * Channels(format) + channel];
    }
    float At(UINT x, UINT y, UINT channel) const {
        return pixels[(static_cast<size_t>(y) * width + x) * Channels(format) + channel];
    }
};
std::vector<std::uint8_t> Pack(const Image& image) {
    std::vector<std::uint8_t> bytes(image.pixels.size() * ComponentBytes(image.format));
    if (ComponentBytes(image.format) == 4) {
        std::memcpy(bytes.data(), image.pixels.data(), bytes.size());
    } else {
        for (size_t i = 0; i < image.pixels.size(); ++i) {
            const auto h = ToHalf(image.pixels[i]);
            std::memcpy(bytes.data() + i * sizeof(h), &h, sizeof(h));
        }
    }
    return bytes;
}
void Equal(const Image& actual, const Image& expected, float absolute = 3e-5f,
           float relative = 3e-6f, bool exact = false) {
    Require(actual.width == expected.width && actual.height == expected.height &&
            actual.pixels.size() == expected.pixels.size(), "Result shape mismatch");
    for (size_t i = 0; i < actual.pixels.size(); ++i) {
        const float a = actual.pixels[i], e = expected.pixels[i];
        if (!std::isfinite(a) || !std::isfinite(e))
            throw std::runtime_error("Unexpected nonfinite component at " + std::to_string(i));
        if (exact) {
            if (std::memcmp(&a, &e, sizeof(float)) != 0)
                throw std::runtime_error("Identity bit mismatch at component " + std::to_string(i));
        } else if (std::abs(a - e) > absolute + relative * std::abs(e)) {
            throw std::runtime_error("Component " + std::to_string(i) +
                ": expected " + std::to_string(e) + ", got " + std::to_string(a));
        }
    }
}
Image Filled(UINT w, UINT h, std::initializer_list<float> values,
             DXGI_FORMAT format = DXGI_FORMAT_R32G32B32A32_FLOAT) {
    Require(values.size() == Channels(format), "Wrong constant channel count");
    Image image(w, h, format);
    for (size_t i = 0; i < image.pixels.size(); i += values.size())
        std::copy(values.begin(), values.end(), image.pixels.begin() + static_cast<std::ptrdiff_t>(i));
    return image;
}
Image Pattern(UINT w, UINT h) {
    Image image(w, h, DXGI_FORMAT_R32G32B32A32_FLOAT);
    for (UINT y = 0; y < h; ++y) for (UINT x = 0; x < w; ++x) {
        image.At(x, y, 0) = x < w / 2 ? -0.5f : 4.0f;
        image.At(x, y, 1) = static_cast<float>((x + y) % 2) * 2.0f;
        image.At(x, y, 2) = static_cast<float>(3 * x + 7 * y) / 16.0f;
        image.At(x, y, 3) = static_cast<float>((x + 2 * y) % 9) / 8.0f;
    }
    return image;
}
// Independent double-precision finite-volume reference: visit each source cell
// and accumulate its geometric intersection with each destination cell.
Image AreaReference(const Image& input, UINT w, UINT h) {
    Image expected(w, h, input.format);
    std::vector<double> sums(expected.pixels.size());
    const double cellArea = static_cast<double>(input.width) * input.height / (w * h);
    for (UINT sy = 0; sy < input.height; ++sy) for (UINT sx = 0; sx < input.width; ++sx) {
        for (UINT dy = 0; dy < h; ++dy) {
            const double top = std::max(static_cast<double>(sy), static_cast<double>(dy) * input.height / h);
            const double bottom = std::min(static_cast<double>(sy + 1), static_cast<double>(dy + 1) * input.height / h);
            if (bottom <= top) continue;
            for (UINT dx = 0; dx < w; ++dx) {
                const double left = std::max(static_cast<double>(sx), static_cast<double>(dx) * input.width / w);
                const double right = std::min(static_cast<double>(sx + 1), static_cast<double>(dx + 1) * input.width / w);
                if (right <= left) continue;
                const double weight = (bottom - top) * (right - left) / cellArea;
                for (UINT c = 0; c < Channels(input.format); ++c)
                    sums[(static_cast<size_t>(dy) * w + dx) * Channels(input.format) + c] += input.At(sx, sy, c) * weight;
            }
        }
    }
    std::transform(sums.begin(), sums.end(), expected.pixels.begin(),
                   [](double value) { return static_cast<float>(value); });
    return expected;
}

class Warp {
public:
    explicit Warp(const std::wstring& shaderDirectory, const std::wstring& bytecodeDirectory) {
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
            debug->EnableDebugLayer();
            debugEnabled_ = true;
        }
        ComPtr<IDXGIFactory4> factory;
        Check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Enum WARP adapter");
        DXGI_ADAPTER_DESC1 description{};
        Check(adapter->GetDesc1(&description), "Get WARP adapter description");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected a software WARP adapter");
        std::wcout << L"Adapter: " << description.Description << L" (WARP)\n";
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device_)),
              "Create WARP D3D12 device");
        (void)device_.As(&messages_);
        D3D12_COMMAND_QUEUE_DESC queue{};
        queue.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        Check(device_->CreateCommandQueue(&queue, IID_PPV_ARGS(&queue_)), "Create command queue");
        Check(device_->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
              IID_PPV_ARGS(&allocator_)), "Create command allocator");
        Check(device_->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator_.Get(),
              nullptr, IID_PPV_ARGS(&commands_)), "Create command list");
        Check(commands_->Close(), "Close initial list");
        Check(device_->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence_)), "Create fence");
        event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event_) Check(HRESULT_FROM_WIN32(GetLastError()), "Create completion event");
        executor_.Initialize(device_.Get(), shaderDirectory);
        // The add-on embeds these same build outputs. Tests execute the CSOs,
        // using the same InitializeBytecode path as the production add-on.
        std::array<std::vector<char>, 4> bytes;
        std::array<nr030::gpu::BytecodeView, 4> views{};
        for (UINT i = 0; i < bytes.size(); ++i) {
            auto path = std::filesystem::path(bytecodeDirectory) /
                        ShaderExecutor::FileName(static_cast<Kernel>(i));
            path.replace_extension(L".cso");
            std::ifstream file(path, std::ios::binary | std::ios::ate);
            Require(file.good(), "Cannot open production CSO: " + path.string());
            const auto length = file.tellg();
            Require(length > 0 && length < 16 * 1024 * 1024, "Invalid production CSO size");
            bytes[i].resize(static_cast<size_t>(length));
            file.seekg(0);
            file.read(bytes[i].data(), static_cast<std::streamsize>(bytes[i].size()));
            Require(file.good(), "Cannot read complete production CSO");
            views[i] = {bytes[i].data(), bytes[i].size()};
        }
        executor_.InitializeBytecode(device_.Get(), views);
        CheckMessages();
        std::cout << "Compiled four cs_5_0 sources; all GPU checks execute the shared production CSOs.\n";
    }
    ~Warp() { if (event_) CloseHandle(event_); }
    Warp(const Warp&) = delete;
    Warp& operator=(const Warp&) = delete;
    bool DebugEnabled() const { return debugEnabled_; }

    Image Run(Kernel kernel, const std::vector<Image>& inputs, UINT w, UINT h,
              const std::array<UINT, 4>& constants, DXGI_FORMAT outputFormat) {
        Begin();
        std::vector<GpuTexture> textures;
        std::vector<TextureBinding> views;
        textures.reserve(inputs.size());
        views.reserve(inputs.size());
        for (const auto& input : inputs) {
            textures.push_back(Upload(input));
            views.push_back({textures.back().resource.Get(), input.format});
        }
        auto result = CreateTexture(w, h, outputFormat, true);
        auto heap = MakeHeap(ShaderExecutor::DescriptorCount);
        executor_.Record(kernel, commands_.Get(), heap.Get(), 0,
                         constants.data(), 4, views.data(), static_cast<UINT>(views.size()),
                         {result.Get(), outputFormat}, w, h);
        auto readback = CopyResult(result.Get());
        Finish();
        auto image = Read(readback, w, h, outputFormat);
        CheckMessages();
        return image;
    }
    Image ChainedIdentity(const Image& source, const contract::ScalePlan& plan) {
        Begin();
        auto input = Upload(source);
        auto low = CreateTexture(plan.neural.width, plan.neural.height, source.format, true);
        auto result = CreateTexture(source.width, source.height, source.format, true);
        auto heap = MakeHeap(2 * ShaderExecutor::DescriptorCount);
        const auto down = plan.colour_constants();
        const TextureBinding original{input.resource.Get(), source.format};
        executor_.Record(Kernel::Color, commands_.Get(), heap.Get(), 0, &down, 4,
                         &original, 1, {low.Get(), source.format}, plan.neural.width, plan.neural.height);
        Transition(commands_.Get(), low.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        const TextureBinding resolveInputs[] = {original, {low.Get(), source.format},
                                                {low.Get(), source.format}};
        const auto resolve = plan.resolve_constants();
        executor_.Record(Kernel::Residual, commands_.Get(), heap.Get(), ShaderExecutor::DescriptorCount,
                         &resolve, 4, resolveInputs, 3, {result.Get(), source.format},
                         source.width, source.height);
        auto readback = CopyResult(result.Get());
        Finish();
        auto image = Read(readback, source.width, source.height, source.format);
        CheckMessages();
        return image;
    }

private:
    struct GpuTexture { ComPtr<ID3D12Resource> resource, upload; };
    struct Readback { ComPtr<ID3D12Resource> buffer; D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{}; };
    ComPtr<ID3D12Device> device_;
    ComPtr<ID3D12CommandQueue> queue_;
    ComPtr<ID3D12CommandAllocator> allocator_;
    ComPtr<ID3D12GraphicsCommandList> commands_;
    ComPtr<ID3D12Fence> fence_;
    ComPtr<ID3D12InfoQueue> messages_;
    HANDLE event_ = nullptr;
    UINT64 fenceValue_ = 0;
    bool debugEnabled_ = false;
    ShaderExecutor executor_;

    void Begin() {
        Check(allocator_->Reset(), "Reset retired command allocator");
        Check(commands_->Reset(allocator_.Get(), nullptr), "Reset command list");
    }
    void Finish() {
        Check(commands_->Close(), "Close compute command list");
        ID3D12CommandList* lists[]{commands_.Get()};
        queue_->ExecuteCommandLists(1, lists);
        const UINT64 submitted = ++fenceValue_;
        Check(queue_->Signal(fence_.Get(), submitted), "Signal compute completion");
        if (fence_->GetCompletedValue() < submitted) {
            Check(fence_->SetEventOnCompletion(submitted, event_), "Arm compute completion");
            const DWORD waited = WaitForSingleObject(event_, 30000);
            if (waited != WAIT_OBJECT_0) {
                Check(device_->GetDeviceRemovedReason(), "WARP device after fence timeout");
                throw std::runtime_error("WARP computation did not complete within 30 seconds");
            }
        }
        Require(fence_->GetCompletedValue() >= submitted, "Fence did not retire submitted work");
        Check(device_->GetDeviceRemovedReason(), "WARP device status");
    }
    ComPtr<ID3D12Resource> Buffer(UINT64 bytes, D3D12_HEAP_TYPE heapType,
                                D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = heapType;
        D3D12_RESOURCE_DESC description{};
        description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        description.Width = bytes;
        description.Height = 1;
        description.DepthOrArraySize = 1;
        description.MipLevels = 1;
        description.SampleDesc.Count = 1;
        description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> buffer;
        Check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description,
              state, nullptr, IID_PPV_ARGS(&buffer)), "Create CPU transfer buffer");
        return buffer;
    }
    ComPtr<ID3D12Resource> CreateTexture(UINT w, UINT h, DXGI_FORMAT format, bool unordered) {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC description{};
        description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        description.Width = w;
        description.Height = h;
        description.DepthOrArraySize = 1;
        description.MipLevels = 1;
        description.Format = format;
        description.SampleDesc.Count = 1;
        description.Flags = unordered ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE;
        ComPtr<ID3D12Resource> texture;
        Check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description,
              unordered ? D3D12_RESOURCE_STATE_UNORDERED_ACCESS : D3D12_RESOURCE_STATE_COPY_DEST,
              nullptr, IID_PPV_ARGS(&texture)), "Create test texture");
        return texture;
    }
    GpuTexture Upload(const Image& image) {
        GpuTexture result;
        result.resource = CreateTexture(image.width, image.height, image.format, false);
        const auto description = result.resource->GetDesc();
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
        UINT rows = 0;
        UINT64 rowBytes = 0, total = 0;
        device_->GetCopyableFootprints(&description, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
        Require(rows == image.height, "Unexpected transfer row count");
        result.upload = Buffer(total, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        const auto bytes = Pack(image);
        Require(rowBytes == static_cast<UINT64>(image.width) * Channels(image.format) * ComponentBytes(image.format),
                "Unexpected row format");
        std::uint8_t* mapped = nullptr;
        const D3D12_RANGE none{0, 0};
        Check(result.upload->Map(0, &none, reinterpret_cast<void**>(&mapped)), "Map upload");
        std::memset(mapped, 0, static_cast<size_t>(total));
        for (UINT row = 0; row < rows; ++row)
            std::memcpy(mapped + footprint.Offset + static_cast<size_t>(row) * footprint.Footprint.RowPitch,
                        bytes.data() + static_cast<size_t>(row) * static_cast<size_t>(rowBytes),
                        static_cast<size_t>(rowBytes));
        const D3D12_RANGE written{0, static_cast<SIZE_T>(total)};
        result.upload->Unmap(0, &written);
        D3D12_TEXTURE_COPY_LOCATION source{}, destination{};
        source.pResource = result.upload.Get();
        source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        source.PlacedFootprint = footprint;
        destination.pResource = result.resource.Get();
        destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        commands_->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
        Transition(commands_.Get(), result.resource.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        return result;
    }
    ComPtr<ID3D12DescriptorHeap> MakeHeap(UINT count) {
        D3D12_DESCRIPTOR_HEAP_DESC description{};
        description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        description.NumDescriptors = count;
        description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        ComPtr<ID3D12DescriptorHeap> heap;
        Check(device_->CreateDescriptorHeap(&description, IID_PPV_ARGS(&heap)), "Create descriptor heap");
        return heap;
    }
    Readback CopyResult(ID3D12Resource* texture) {
        Readback result;
        const auto description = texture->GetDesc();
        UINT64 total = 0;
        device_->GetCopyableFootprints(&description, 0, 1, 0, &result.layout, nullptr, nullptr, &total);
        result.buffer = Buffer(total, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(commands_.Get(), texture, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION source{}, destination{};
        source.pResource = texture;
        source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        destination.pResource = result.buffer.Get();
        destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        destination.PlacedFootprint = result.layout;
        commands_->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
        return result;
    }
    Image Read(const Readback& source, UINT w, UINT h, DXGI_FORMAT format) {
        Image output(w, h, format);
        const auto length = source.buffer->GetDesc().Width;
        const D3D12_RANGE range{0, static_cast<SIZE_T>(length)};
        std::uint8_t* bytes = nullptr;
        Check(source.buffer->Map(0, &range, reinterpret_cast<void**>(&bytes)),
              "Map retired readback");
        for (UINT y = 0; y < h; ++y) {
            const auto* row = bytes + source.layout.Offset + static_cast<size_t>(y) * source.layout.Footprint.RowPitch;
            if (ComponentBytes(format) == 4) {
                std::memcpy(output.pixels.data() + static_cast<size_t>(y) * w * Channels(format), row,
                            static_cast<size_t>(w) * Channels(format) * sizeof(float));
            } else {
                for (UINT x = 0; x < w * Channels(format); ++x) {
                    std::uint16_t half = 0;
                    std::memcpy(&half, row + static_cast<size_t>(x) * sizeof(half), sizeof(half));
                    output.pixels[static_cast<size_t>(y) * w * Channels(format) + x] = FromHalf(half);
                }
            }
        }
        const D3D12_RANGE none{0, 0};
        source.buffer->Unmap(0, &none);
        return output;
    }
    void CheckMessages() {
        if (!messages_) return;
        std::string errors;
        const UINT64 count = messages_->GetNumStoredMessagesAllowedByRetrievalFilter();
        for (UINT64 index = 0; index < count; ++index) {
            SIZE_T bytes = 0;
            Check(messages_->GetMessage(index, nullptr, &bytes), "Get D3D12 diagnostic size");
            std::vector<std::uint8_t> storage(bytes);
            auto* message = reinterpret_cast<D3D12_MESSAGE*>(storage.data());
            Check(messages_->GetMessage(index, message, &bytes), "Get D3D12 diagnostic");
            if (message->Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)
                errors += std::string(message->pDescription, message->DescriptionByteLength) + "\n";
        }
        messages_->ClearStoredMessages();
        Require(errors.empty(), "D3D12 debug validation: " + errors);
    }
};

struct Results {
    std::vector<std::string> passed;
    std::string failed, reason;
};
std::string JsonEscape(const std::string& value) {
    std::string output;
    for (const unsigned char c : value) {
        if (c == '"' || c == '\\') { output += '\\'; output += static_cast<char>(c); }
        else if (c == '\n') output += "\\n";
        else if (c == '\r') output += "\\r";
        else if (c == '\t') output += "\\t";
        else if (c >= 32) output += static_cast<char>(c);
    }
    return output;
}
void SaveResults(const std::filesystem::path& file, const Results& results, bool debugEnabled) {
    if (file.empty()) return;
    std::ofstream output(file);
    Require(output.good(), "Cannot create test results file");
    output << "{\n  \"runner\": \"D3D12 WARP\",\n  \"productionShaders\": true,\n"
           << "  \"sharedProductionExecutor\": true,\n  \"neuralRuntimeExecuted\": false,\n"
           << "  \"debugLayerEnabled\": " << (debugEnabled ? "true" : "false") << ",\n"
           << "  \"passedCount\": " << results.passed.size() << ",\n  \"passed\": [";
    for (size_t i = 0; i < results.passed.size(); ++i)
        output << (i ? ", " : "") << '"' << JsonEscape(results.passed[i]) << '"';
    output << "],\n  \"failed\": \"" << JsonEscape(results.failed) << "\",\n"
           << "  \"reason\": \"" << JsonEscape(results.reason) << "\"\n}\n";
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::cerr << "Usage: nr030_warp_checks <production shader directory> <production cso directory> [results.json]\n";
        return 2;
    }
    const std::filesystem::path report = argc > 3 ? std::filesystem::path(argv[3]) : std::filesystem::path();
    Results results;
    bool debugEnabled = false;
    std::string current = "Initialize WARP and compile four production shaders";
    try {
        Warp gpu(argv[1], argv[2]);
        debugEnabled = gpu.DebugEnabled();
        results.passed.push_back(current);
        auto test = [&](const std::string& name, const std::function<void()>& work) {
            current = name;
            work();
            results.passed.push_back(name);
            std::cout << "PASS: " << name << "\n";
        };
        const DXGI_FORMAT rgba = DXGI_FORMAT_R32G32B32A32_FLOAT;
        test("Area identity preserves finite RGBA including negative and HDR", [&] {
            auto image = Pattern(13, 9);
            image.At(3, 4, 2) = 65504.0f;
            const auto out = gpu.Run(Kernel::Color, {image}, 13, 9, {13, 9, 13, 9}, rgba);
            Equal(out, image, 0, 0, true);
        });
        test("Area exact fractional edge average 5x3 to 3x2", [&] {
            auto image = Filled(5, 3, {0, 0, 0, 0.75f});
            for (UINT y = 0; y < 3; ++y) for (UINT x = 2; x < 5; ++x) image.At(x, y, 0) = 1;
            auto expected = Filled(3, 2, {0, 0, 0, 0.75f});
            for (UINT y = 0; y < 2; ++y) { expected.At(1, y, 0) = 0.8f; expected.At(2, y, 0) = 1; }
            Equal(gpu.Run(Kernel::Color, {image}, 3, 2, {3, 2, 5, 3}, rgba), expected);
        });
        for (const auto choice : {contract::FixedScale::Percent100, contract::FixedScale::Percent85,
                                  contract::FixedScale::Percent75}) {
            const auto plan = contract::make_scale_plan({53, 47}, choice);
            const auto percent = static_cast<UINT>(choice);
            test("Plan " + std::to_string(percent) + "% area average and shape", [&] {
                const auto image = Pattern(plan.input.width, plan.input.height);
                const auto out = gpu.Run(Kernel::Color, {image}, plan.neural.width, plan.neural.height,
                    {plan.neural.width, plan.neural.height, plan.input.width, plan.input.height}, rgba);
                Equal(out, AreaReference(image, plan.neural.width, plan.neural.height), 9e-5f, 1e-5f);
                Require(out.width <= image.width && out.height <= image.height, "Upscale instead of reduce");
            });
            test("Plan " + std::to_string(percent) + "% GPU chained zero-residual identity", [&] {
                const auto image = Pattern(plan.input.width, plan.input.height);
                Equal(gpu.ChainedIdentity(image, plan), image, 0, 0, true);
            });
            if (percent == 100) continue;
            test("Plan " + std::to_string(percent) + "% constant RGBA average", [&] {
                auto image = Filled(53, 47, {0.25f, -0.5f, 32, 0.375f});
                auto expected = Filled(plan.neural.width, plan.neural.height, {0.25f, -0.5f, 32, 0.375f});
                Equal(gpu.Run(Kernel::Color, {image}, plan.neural.width, plan.neural.height,
                    {plan.neural.width, plan.neural.height, 53, 47}, rgba), expected);
            });
        }
        for (const auto kernel : {Kernel::Depth, Kernel::Motion}) {
            const auto format = kernel == Kernel::Depth ? DXGI_FORMAT_R32_FLOAT : DXGI_FORMAT_R32G32_FLOAT;
            test(kernel == Kernel::Depth ? "Depth nearest preserves convention at fractional grid"
                                        : "Motion nearest preserves raw vector units at fractional grid", [&] {
                Image input(7, 5, format), expected(5, 3, format);
                for (UINT y = 0; y < 5; ++y) for (UINT x = 0; x < 7; ++x)
                    for (UINT c = 0; c < Channels(format); ++c)
                        input.At(x, y, c) = c ? -static_cast<float>(100 * y + x) : static_cast<float>(100 * y + x);
                const UINT sampledX[]{0, 2, 3, 4, 6};
                const UINT sampledY[]{0, 2, 4};
                for (UINT y = 0; y < 3; ++y) for (UINT x = 0; x < 5; ++x)
                    for (UINT c = 0; c < Channels(format); ++c)
                        expected.At(x, y, c) = input.At(sampledX[x], sampledY[y], c);
                Equal(gpu.Run(kernel, {input}, 5, 3, {5, 3, 7, 5}, format), expected, 0, 0, true);
            });
        }
        test("Residual zero preserves native detail negative values and alpha exactly", [&] {
            auto image = Pattern(11, 7);
            auto low = Filled(3, 2, {2, 3, 4, 99});
            Equal(gpu.Run(Kernel::Residual, {image, low, low}, 11, 7, {11, 7, 3, 2}, rgba),
                  image, 0, 0, true);
        });
        test("Residual matched correction clamps each RGB and keeps native alpha", [&] {
            auto native = Filled(9, 5, {2, 4, 8, 0.3125f});
            auto baseline = Filled(4, 3, {2, 4, 8, 999});
            auto edited = Filled(4, 3, {102, -96, 9, -99});
            auto expected = Filled(9, 5, {3, 2, 9, 0.3125f});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, rgba), expected);
        });
        test("Residual strong mismatch rejects correction and preserves alpha", [&] {
            auto native = Filled(9, 5, {10, 10, 10, -0.125f});
            auto baseline = Filled(4, 3, {1, 1, 1, 1});
            auto edited = Filled(4, 3, {2, 2, 2, 0});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, rgba),
                  native, 0, 0, true);
        });
        test("Residual midpoint confidence attenuates correction", [&] {
            auto native = Filled(9, 5, {10, 10, 10, 0.625f});
            auto baseline = Filled(4, 3, {5.5f, 5.5f, 5.5f, 0});
            auto edited = Filled(4, 3, {6.5f, 6.5f, 6.5f, 1});
            auto expected = Filled(9, 5, {10.5f, 10.5f, 10.5f, 0.625f});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, rgba), expected);
        });
        test("HDR correction bounded to finite FP16 range", [&] {
            auto native = Filled(9, 5, {60000, 8, 0.5f, 1});
            auto baseline = Filled(4, 3, {60000, 8, 0.5f, 0});
            auto edited = Filled(4, 3, {65504, 12, 0.75f, 0});
            auto expected = Filled(9, 5, {65504, 12, 0.75f, 1});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, rgba), expected);
        });
        test("Malformed low taps fall back to finite native frame", [&] {
            auto native = Pattern(9, 5);
            auto baseline = Filled(4, 3, {1, 2, 3, 1});
            auto edited = Filled(4, 3, {std::numeric_limits<float>::quiet_NaN(),
                                      std::numeric_limits<float>::infinity(), 4, 0});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, rgba),
                  native, 0, 0, true);
        });
        test("Malformed native components are sanitized independently", [&] {
            auto native = Filled(9, 5, {std::numeric_limits<float>::quiet_NaN(), -2,
                                      std::numeric_limits<float>::infinity(), 0.5f});
            auto baseline = Filled(4, 3, {1, 2, 3, 1});
            auto expected = Filled(9, 5, {0, -2, 0, 0.5f});
            Equal(gpu.Run(Kernel::Residual, {native, baseline, baseline}, 9, 5, {9, 5, 4, 3}, rgba),
                  expected, 0, 0, true);
        });
        test("Actual RGBA16F storage preserves identity and bounded residual", [&] {
            const auto half = DXGI_FORMAT_R16G16B16A16_FLOAT;
            auto native = Filled(9, 5, {2, 4, 8, 0.3125f}, half);
            Equal(gpu.Run(Kernel::Color, {native}, 9, 5, {9, 5, 9, 5}, half), native, 0, 0, true);
            auto baseline = Filled(4, 3, {2, 4, 8, 1}, half);
            auto edited = Filled(4, 3, {102, -96, 9, 0}, half);
            auto expected = Filled(9, 5, {3, 2, 9, 0.3125f}, half);
            Equal(gpu.Run(Kernel::Residual, {native, baseline, edited}, 9, 5, {9, 5, 4, 3}, half),
                  expected, 0, 0, true);
        });
        SaveResults(report, results, debugEnabled);
        std::cout << "PASS: " << results.passed.size()
                  << " WARP checks. Actual NR runtime, Radeon and game hook are NOT exercised.\n";
        return 0;
    } catch (const std::exception& error) {
        results.failed = current;
        results.reason = error.what();
        std::cerr << "FAIL: " << current << ": " << error.what() << "\n";
        try { SaveResults(report, results, debugEnabled); } catch (...) {}
        return 1;
    }
}

