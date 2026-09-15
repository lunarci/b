// SPDX-License-Identifier: GPL-3.0-only
#include "shader_executor.h"
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <filesystem>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

using Microsoft::WRL::ComPtr;

namespace nr030::gpu {
void Check(HRESULT result, const char* operation) {
    if (SUCCEEDED(result)) return;
    std::ostringstream message;
    message << operation << " failed: HRESULT 0x" << std::hex
            << std::setw(8) << std::setfill('0') << static_cast<unsigned long>(result);
    throw std::runtime_error(message.str());
}

const wchar_t* ShaderExecutor::FileName(Kernel kernel) {
    switch (kernel) {
    case Kernel::Color: return L"area_downsample.hlsl";
    case Kernel::Depth: return L"depth_nearest.hlsl";
    case Kernel::Motion: return L"motion_nearest.hlsl";
    case Kernel::Residual: return L"matched_residual_resolve.hlsl";
    }
    throw std::invalid_argument("Unknown shader kernel");
}

void ShaderExecutor::Initialize(ID3D12Device* device, const std::wstring& shaderDirectory) {
    if (!device) throw std::invalid_argument("ShaderExecutor requires a D3D12 device");
    std::array<ComPtr<ID3DBlob>, 4> blobs{};
    std::array<BytecodeView, 4> views{};
    for (UINT index = 0; index < blobs.size(); ++index) {
        const auto kernel = static_cast<Kernel>(index);
        const auto file = std::filesystem::path(shaderDirectory) / FileName(kernel);
        ComPtr<ID3DBlob> shader, errors;
        const HRESULT compiled = D3DCompileFromFile(
            file.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE,
            "MainCS", "cs_5_0",
            D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_WARNINGS_ARE_ERRORS |
                D3DCOMPILE_IEEE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0, &shader, &errors);
        if (FAILED(compiled)) {
            std::string detail = errors
                ? std::string(static_cast<const char*>(errors->GetBufferPointer()),
                              errors->GetBufferSize())
                : std::string("No shader compiler diagnostic");
            throw std::runtime_error(file.string() + ": " + detail);
        }
        blobs[index] = shader;
        views[index] = {shader->GetBufferPointer(), shader->GetBufferSize()};
    }
    InitializeBytecode(device, views);
}

void ShaderExecutor::InitializeBytecode(ID3D12Device* device,
    const std::array<BytecodeView, 4>& bytecode) {
    if (!device) throw std::invalid_argument("ShaderExecutor requires a D3D12 device");
    // The file-compiled and embedded-bytecode paths share this exact validation
    // and PSO construction. A failure preserves the previous initialized set.
    std::array<Program, 4> built{};
    for (UINT index = 0; index < built.size(); ++index) {
        const auto kernel = static_cast<Kernel>(index);
        const auto& code = bytecode[index];
        if (!code.data || !code.size) throw std::invalid_argument("Empty shader bytecode");
        ComPtr<ID3DBlob> errors;
        ComPtr<ID3D11ShaderReflection> reflection;
        Check(D3DReflect(code.data, code.size,
                         IID_PPV_ARGS(&reflection)), "D3DReflect");
        D3D11_SHADER_DESC reflected{};
        Check(reflection->GetDesc(&reflected), "Shader reflection GetDesc");
        UINT srvMask = 0, uavCount = 0, cbCount = 0;
        for (UINT binding = 0; binding < reflected.BoundResources; ++binding) {
            D3D11_SHADER_INPUT_BIND_DESC input{};
            Check(reflection->GetResourceBindingDesc(binding, &input), "Reflect binding");
            if (input.Type == D3D_SIT_TEXTURE &&
                input.Dimension == D3D_SRV_DIMENSION_TEXTURE2D &&
                input.BindPoint < 4 && input.BindCount == 1) {
                srvMask |= 1u << input.BindPoint;
            } else if (input.Type == D3D_SIT_UAV_RWTYPED &&
                       input.Dimension == D3D_SRV_DIMENSION_TEXTURE2D &&
                       input.BindPoint == 0 && input.BindCount == 1) {
                ++uavCount;
            } else if (input.Type == D3D_SIT_CBUFFER &&
                       input.BindPoint == 0 && input.BindCount == 1) {
                D3D11_SHADER_BUFFER_DESC buffer{};
                Check(reflection->GetConstantBufferByName(input.Name)->GetDesc(&buffer),
                      "Reflect constant buffer");
                if (buffer.Size != 16)
                    throw std::runtime_error("Shader b0 must contain exactly four DWORDs");
                ++cbCount;
            } else {
                throw std::runtime_error("Unexpected shader resource binding");
            }
        }
        Program& program = built[index];
        program.inputCount = kernel == Kernel::Residual ? 3u : 1u;
        if (srvMask != ((1u << program.inputCount) - 1u) || uavCount != 1 || cbCount != 1)
            throw std::runtime_error("Shader resource contract differs from expected layout");
        program.constants = 4;
        UINT groupZ = 0;
        reflection->GetThreadGroupSize(&program.groupX, &program.groupY, &groupZ);
        if (program.groupX != 8 || program.groupY != 8 || groupZ != 1)
            throw std::runtime_error("Shader thread group differs from 8x8x1 contract");

        D3D12_DESCRIPTOR_RANGE ranges[2]{};
        ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        ranges[0].NumDescriptors = 4;
        ranges[0].BaseShaderRegister = 0;
        ranges[0].OffsetInDescriptorsFromTableStart = 0;
        ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
        ranges[1].NumDescriptors = 1;
        ranges[1].BaseShaderRegister = 0;
        ranges[1].OffsetInDescriptorsFromTableStart = 4;
        D3D12_ROOT_PARAMETER parameters[2]{};
        parameters[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        parameters[0].Constants.Num32BitValues = program.constants;
        parameters[0].Constants.ShaderRegister = 0;
        parameters[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameters[1].DescriptorTable.NumDescriptorRanges = 2;
        parameters[1].DescriptorTable.pDescriptorRanges = ranges;
        parameters[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_ROOT_SIGNATURE_DESC rootDescription{};
        rootDescription.NumParameters = 2;
        rootDescription.pParameters = parameters;
        ComPtr<ID3DBlob> rootBlob;
        errors.Reset();
        Check(D3D12SerializeRootSignature(&rootDescription, D3D_ROOT_SIGNATURE_VERSION_1,
                                          &rootBlob, &errors), "Serialize root signature");
        Check(device->CreateRootSignature(0, rootBlob->GetBufferPointer(),
                                           rootBlob->GetBufferSize(),
                                           IID_PPV_ARGS(&program.root)), "Create root signature");
        D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline{};
        pipeline.pRootSignature = program.root.Get();
        pipeline.CS = {code.data, code.size};
        Check(device->CreateComputePipelineState(&pipeline, IID_PPV_ARGS(&program.pipeline)),
              "Create compute pipeline");
    }
    device_ = device;
    programs_ = std::move(built);
}

void ShaderExecutor::Record(Kernel kernel, ID3D12GraphicsCommandList* commands,
    ID3D12DescriptorHeap* visibleHeap, UINT firstDescriptor, const void* constants,
    UINT dwordCount, const TextureBinding* inputs, UINT inputCount,
    const TextureBinding& output, UINT dispatchWidth, UINT dispatchHeight) const {
    const UINT index = static_cast<UINT>(kernel);
    if (!device_ || index >= programs_.size() || !commands || !visibleHeap ||
        !constants || !inputs || !output.resource || dispatchWidth == 0 || dispatchHeight == 0)
        throw std::invalid_argument("Invalid ShaderExecutor dispatch");
    const Program& program = programs_[index];
    if (inputCount != program.inputCount || dwordCount != program.constants)
        throw std::invalid_argument("ShaderExecutor binding or constant count mismatch");
    std::array<UINT, 4> extent{};
    std::memcpy(extent.data(), constants, sizeof(extent));
    if (extent[0] != dispatchWidth || extent[1] != dispatchHeight ||
        !extent[2] || !extent[3] || dispatchWidth > 16384 || dispatchHeight > 16384)
        throw std::invalid_argument("Shader extent constants do not match dispatch dimensions");
    for (UINT slot = 0; slot < inputCount; ++slot) {
        if (!inputs[slot].resource) throw std::invalid_argument("Missing shader input texture");
        const auto input = inputs[slot].resource->GetDesc();
        const UINT readWidth = kernel == Kernel::Residual && slot == 0 ? extent[0] : extent[2];
        const UINT readHeight = kernel == Kernel::Residual && slot == 0 ? extent[1] : extent[3];
        if (readWidth > input.Width || readHeight > input.Height)
            throw std::invalid_argument("Shader source extent exceeds its bound texture");
    }
    const auto heapDescription = visibleHeap->GetDesc();
    if (heapDescription.Type != D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV ||
        !(heapDescription.Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE) ||
        firstDescriptor > heapDescription.NumDescriptors ||
        DescriptorCount > heapDescription.NumDescriptors - firstDescriptor)
        throw std::invalid_argument("Dispatch needs a private five-descriptor visible range");
    const auto outputDescription = output.resource->GetDesc();
    if (outputDescription.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
        outputDescription.DepthOrArraySize != 1 || outputDescription.SampleDesc.Count != 1 ||
        !(outputDescription.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) ||
        dispatchWidth > outputDescription.Width || dispatchHeight > outputDescription.Height)
        throw std::invalid_argument("Output texture cannot hold the dispatch");
    const UINT step = device_->GetDescriptorHandleIncrementSize(
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto cpu = visibleHeap->GetCPUDescriptorHandleForHeapStart();
    cpu.ptr += static_cast<SIZE_T>(firstDescriptor) * step;
    for (UINT slot = 0; slot < 4; ++slot) {
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};
        view.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
        view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Texture2D.MipLevels = 1;
        ID3D12Resource* resource = nullptr;
        if (slot < inputCount) {
            resource = inputs[slot].resource;
            if (!resource || resource == output.resource)
                throw std::invalid_argument("Input and output textures must be distinct");
            const auto source = resource->GetDesc();
            if (source.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
                source.DepthOrArraySize != 1 || source.SampleDesc.Count != 1)
                throw std::invalid_argument("Shader input must be a single-sample 2D texture");
            view.Format = inputs[slot].format;
        }
        device_->CreateShaderResourceView(resource, &view, cpu);
        cpu.ptr += step;
    }
    D3D12_UNORDERED_ACCESS_VIEW_DESC unordered{};
    unordered.Format = output.format;
    unordered.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
    device_->CreateUnorderedAccessView(output.resource, nullptr, &unordered, cpu);

    auto gpu = visibleHeap->GetGPUDescriptorHandleForHeapStart();
    gpu.ptr += static_cast<UINT64>(firstDescriptor) * step;
    commands->SetDescriptorHeaps(1, &visibleHeap);
    commands->SetComputeRootSignature(program.root.Get());
    commands->SetPipelineState(program.pipeline.Get());
    commands->SetComputeRoot32BitConstants(0, dwordCount, constants, 0);
    commands->SetComputeRootDescriptorTable(1, gpu);
    commands->Dispatch((dispatchWidth + program.groupX - 1) / program.groupX,
                       (dispatchHeight + program.groupY - 1) / program.groupY, 1);
}

void Transition(ID3D12GraphicsCommandList* commands, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    if (!commands || !resource) throw std::invalid_argument("Invalid resource transition");
    if (before == after) return;
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    commands->ResourceBarrier(1, &barrier);
}
void UavBarrier(ID3D12GraphicsCommandList* commands, ID3D12Resource* resource) {
    if (!commands || !resource) throw std::invalid_argument("Invalid UAV barrier");
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    barrier.UAV.pResource = resource;
    commands->ResourceBarrier(1, &barrier);
}
} // namespace nr030::gpu
