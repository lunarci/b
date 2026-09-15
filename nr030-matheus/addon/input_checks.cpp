// SPDX-License-Identifier: GPL-3.0-only
// The production input admission contract is exercised with real WARP resources.
// This does not invoke the NR engine, game hook, or a Radeon device.
#include "input_contract.h"
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
namespace ffx = nr030::ffx;
namespace input = nr030::input;
using Microsoft::WRL::ComPtr;
constexpr UINT Width = 64, Height = 48;

void Require(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
void Check(HRESULT value, const char* message) {
    if (FAILED(value)) throw std::runtime_error(std::string(message) + ": HRESULT " +
                                               std::to_string(static_cast<unsigned long>(value)));
}
std::string JsonString(const std::string& value) {
    std::string result = "\"";
    for (const unsigned char c : value) {
        if (c == '\\' || c == '"') { result += '\\'; result += static_cast<char>(c); }
        else if (c == '\n') result += "\\n";
        else if (c == '\r') result += "\\r";
        else if (c == '\t') result += "\\t";
        else if (c >= 32) result += static_cast<char>(c);
    }
    return result + '"';
}
struct Results {
    std::vector<std::string> passed;
    std::string failure;
    void Save(const std::filesystem::path& path, bool debugEnabled) const {
        std::ofstream file(path, std::ios::binary);
        Require(bool(file), "Cannot create input admission evidence JSON");
        file << "{\n  \"scope\": \"production input_contract.h + real D3D12 WARP resources\",\n"
                "  \"amdGpuGameTested\": false,\n  \"debugLayerEnabled\": "
             << (debugEnabled ? "true" : "false") << ",\n  \"passedCount\": "
             << passed.size() << ",\n  \"passed\": [";
        for (std::size_t i = 0; i < passed.size(); ++i)
            file << (i ? ", " : "") << JsonString(passed[i]);
        file << "],\n  \"failure\": " << JsonString(failure) << "\n}\n";
        Require(bool(file), "Cannot write input admission evidence JSON");
    }
};

class Warp {
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    bool debugEnabled = false;

    Warp() {
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
            debug->EnableDebugLayer();
            debugEnabled = true;
        }
        ComPtr<IDXGIFactory4> factory;
        Check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Select WARP adapter");
        DXGI_ADAPTER_DESC1 description{};
        Check(adapter->GetDesc1(&description), "Read WARP adapter description");
        Require((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0, "Expected software WARP device");
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
            IID_PPV_ARGS(&device)), "Create WARP device");
        (void)device.As(&messages_);
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&allocator)), "Create direct command allocator");
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(),
            nullptr, IID_PPV_ARGS(&commands)), "Create direct command list");
    }
    ~Warp() { if (commands) (void)commands->Close(); }

    ComPtr<ID3D12Resource> Texture(DXGI_FORMAT format, UINT width = Width, UINT height = Height,
                                  UINT16 layers = 1, UINT16 mips = 1) {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = width;
        desc.Height = height;
        desc.DepthOrArraySize = layers;
        desc.MipLevels = mips;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        ComPtr<ID3D12Resource> resource;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr,
            IID_PPV_ARGS(&resource)), "Create admission test texture");
        return resource;
    }
    ComPtr<ID3D12Resource> Buffer() {
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = Width;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> resource;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr,
            IID_PPV_ARGS(&resource)), "Create nontexture admission fixture");
        return resource;
    }
    void CheckMessages() {
        if (!messages_) return;
        for (UINT64 i = 0; i < messages_->GetNumStoredMessagesAllowedByRetrievalFilter(); ++i) {
            SIZE_T size = 0;
            Check(messages_->GetMessage(i, nullptr, &size), "Read D3D12 message size");
            std::vector<unsigned char> bytes(size);
            auto* message = reinterpret_cast<D3D12_MESSAGE*>(bytes.data());
            Check(messages_->GetMessage(i, message, &size), "Read D3D12 message");
            if (message->Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
                message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION)
                throw std::runtime_error(std::string("D3D12 debug validation: ") + message->pDescription);
        }
        messages_->ClearStoredMessages();
    }
private:
    ComPtr<ID3D12InfoQueue> messages_;
};

ffx::Resource Adapt(ID3D12Resource* resource, std::uint32_t format) {
    ffx::Resource result{};
    result.resource = resource;
    result.description = {2, format, Width, Height, 1, 1, 0, 0};
    result.state = ffx::ComputeRead;
    return result;
}
struct Fixture {
    ComPtr<ID3D12Resource> color, motion, depth;
    ffx::UpscaleDispatch desc{};
    Fixture(Warp& gpu, DXGI_FORMAT motionFormat = DXGI_FORMAT_R16G16B16A16_FLOAT,
            DXGI_FORMAT colorFormat = DXGI_FORMAT_R16G16B16A16_FLOAT,
            DXGI_FORMAT depthFormat = DXGI_FORMAT_R32_TYPELESS) {
        color = gpu.Texture(colorFormat);
        motion = gpu.Texture(motionFormat);
        depth = gpu.Texture(depthFormat);
        desc.header.type = ffx::UpscaleType;
        desc.commandList = gpu.commands.Get();
        desc.color = Adapt(color.Get(), ffx::FormatRgba16Float);
        desc.depth = Adapt(depth.Get(), ffx::FormatR32Float);
        const bool rgba = motionFormat == DXGI_FORMAT_R16G16B16A16_FLOAT ||
                          motionFormat == DXGI_FORMAT_R16G16B16A16_TYPELESS;
        desc.motionVectors = Adapt(motion.Get(), rgba ? ffx::FormatRgba16Float : ffx::FormatRg16Float);
        desc.renderSize = {Width, Height};
        desc.upscaleSize = {96, 72};
        desc.motionVectorScale = {64.0f, 48.0f};
        desc.jitterOffset = {-0.25f, 0.5f};
        desc.frameTimeDelta = 16.0f;
        desc.preExposure = 1.0f;
    }
};
void Accepted(const ffx::UpscaleDispatch& desc) {
    const char* reason = input::Rejection(&desc);
    Require(!reason, std::string("Valid input was rejected: ") + (reason ? reason : ""));
}
void Rejected(const ffx::UpscaleDispatch* desc) {
    const char* reason = input::Rejection(desc);
    Require(reason && *reason, "Invalid input was accepted or no rejection reason was supplied");
}
std::array<ffx::Resource*, 3> Resources(ffx::UpscaleDispatch& desc) {
    return {&desc.color, &desc.depth, &desc.motionVectors};
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    const auto report = argc > 1 ? std::filesystem::path(argv[1]) : std::filesystem::path(L"input_results.json");
    Results results;
    bool debugEnabled = false;
    std::string current = "Create real WARP admission fixtures";
    try {
        Warp gpu;
        debugEnabled = gpu.debugEnabled;
        const auto test = [&](const std::string& name, const std::function<void()>& work) {
            current = name;
            work();
            gpu.CheckMessages();
            results.passed.push_back(name);
            std::cout << "PASS: " << name << '\n';
        };
        test("Captured RGBA16F motion family and typeless R32 depth are admitted", [&] {
            Fixture fixture(gpu);
            Accepted(fixture.desc);
            Require(input::MotionViewFormat(fixture.desc.motionVectors) == DXGI_FORMAT_R16G16B16A16_FLOAT,
                    "RGBA16F motion must use an RGBA16F shader view");
        });
        test("Original RG16F motion and typed R32 depth remain admitted", [&] {
            Fixture fixture(gpu, DXGI_FORMAT_R16G16_FLOAT, DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32_FLOAT);
            Accepted(fixture.desc);
            Require(input::MotionViewFormat(fixture.desc.motionVectors) == DXGI_FORMAT_R16G16_FLOAT,
                    "RG16F motion must retain its RG16F shader view");
        });
        test("RGBA16 typeless motion and color accept compatible typed views", [&] {
            Fixture fixture(gpu, DXGI_FORMAT_R16G16B16A16_TYPELESS, DXGI_FORMAT_R16G16B16A16_TYPELESS);
            Accepted(fixture.desc);
            Require(input::MotionViewFormat(fixture.desc.motionVectors) == DXGI_FORMAT_R16G16B16A16_FLOAT,
                    "RGBA16 typeless motion selected incompatible view");
        });
        test("RG16 typeless motion accepts its original compatible typed view", [&] {
            Fixture fixture(gpu, DXGI_FORMAT_R16G16_TYPELESS);
            Accepted(fixture.desc);
            Require(input::MotionViewFormat(fixture.desc.motionVectors) == DXGI_FORMAT_R16G16_FLOAT,
                    "RG16 typeless motion selected incompatible view");
        });
        test("Null dispatch command list chained extension and wrong ABI are rejected", [&] {
            Fixture fixture(gpu);
            Rejected(nullptr);
            auto desc = fixture.desc;
            desc.commandList = nullptr;
            Rejected(&desc);
            desc = fixture.desc;
            desc.header.type ^= 1;
            Rejected(&desc);
            desc = fixture.desc;
            ffx::Header extension{};
            desc.header.next = &extension;
            Rejected(&desc);
        });
        test("Zero and out-of-range render extents are rejected", [&] {
            Fixture fixture(gpu);
            for (const auto extent : {ffx::Extent{0, Height}, ffx::Extent{Width, 0},
                                      ffx::Extent{16385, Height}, ffx::Extent{Width, 16385}}) {
                auto desc = fixture.desc;
                desc.renderSize = extent;
                Rejected(&desc);
            }
        });
        test("Nonfinite motion scale and jitter components are rejected", [&] {
            Fixture fixture(gpu);
            for (const auto value : {std::numeric_limits<float>::quiet_NaN(),
                                    std::numeric_limits<float>::infinity(),
                                    -std::numeric_limits<float>::infinity()}) {
                for (UINT component = 0; component < 4; ++component) {
                    auto desc = fixture.desc;
                    std::array<float*, 4> values{&desc.motionVectorScale.x, &desc.motionVectorScale.y,
                                                &desc.jitterOffset.x, &desc.jitterOffset.y};
                    *values[component] = value;
                    Rejected(&desc);
                }
            }
        });
        test("A missing color depth or motion resource is rejected", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) {
                auto desc = fixture.desc;
                Resources(desc)[index]->resource = nullptr;
                Rejected(&desc);
            }
        });
        test("Every input requires the exact FFX compute-read state", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) for (const auto state : {0u, 2u, 8u, 12u}) {
                auto desc = fixture.desc;
                Resources(desc)[index]->state = state;
                Rejected(&desc);
            }
        });
        test("Every input requires a Texture2D FFX resource description", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) {
                auto desc = fixture.desc;
                Resources(desc)[index]->description.type = 1;
                Rejected(&desc);
            }
        });
        test("FFX description extents must match the active render extent", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) for (const bool width : {false, true}) {
                auto desc = fixture.desc;
                auto& description = Resources(desc)[index]->description;
                if (width) ++description.width;
                else ++description.height;
                Rejected(&desc);
            }
        });
        test("Incorrect FFX color depth and motion formats are rejected", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) {
                auto desc = fixture.desc;
                Resources(desc)[index]->description.format = 0;
                Rejected(&desc);
            }
            auto desc = fixture.desc;
            desc.motionVectors.description.format = ffx::FormatRg16Float;
            Rejected(&desc);
            Fixture rg(gpu, DXGI_FORMAT_R16G16_FLOAT);
            rg.desc.motionVectors.description.format = ffx::FormatRgba16Float;
            Rejected(&rg.desc);
        });
        test("Physical texture extents are checked beyond reported FFX extents", [&] {
            Fixture fixture(gpu);
            for (UINT index = 0; index < 3; ++index) {
                const auto format = index == 1 ? DXGI_FORMAT_R32_FLOAT : DXGI_FORMAT_R16G16B16A16_FLOAT;
                auto actual = gpu.Texture(format, Width + 1, Height);
                auto desc = fixture.desc;
                Resources(desc)[index]->resource = actual.Get();
                Rejected(&desc);
            }
        });
        test("Unexpected physical motion texture format is rejected", [&] {
            Fixture fixture(gpu);
            auto wrong = gpu.Texture(DXGI_FORMAT_R32G32_FLOAT);
            fixture.desc.motionVectors.resource = wrong.Get();
            Rejected(&fixture.desc);
        });
        test("Texture arrays and multi-mip inputs are rejected", [&] {
            Fixture fixture(gpu);
            for (const bool array : {false, true}) {
                auto actual = gpu.Texture(DXGI_FORMAT_R16G16B16A16_FLOAT, Width, Height,
                                          static_cast<UINT16>(array ? 2u : 1u),
                                          static_cast<UINT16>(array ? 1u : 2u));
                fixture.desc.motionVectors.resource = actual.Get();
                Rejected(&fixture.desc);
            }
        });
        test("A buffer disguised as a Texture2D input is rejected", [&] {
            Fixture fixture(gpu);
            auto buffer = gpu.Buffer();
            fixture.desc.motionVectors.resource = buffer.Get();
            Rejected(&fixture.desc);
        });
        results.Save(report, debugEnabled);
        std::cout << "PASS: " << results.passed.size()
                  << " production input admission groups; actual NR and Radeon game runtime are not exercised.\n";
        return 0;
    } catch (const std::exception& error) {
        results.failure = current + ": " + error.what();
        std::cerr << "FAIL: " << results.failure << '\n';
        try { results.Save(report, debugEnabled); } catch (...) {}
        return 1;
    }
}
