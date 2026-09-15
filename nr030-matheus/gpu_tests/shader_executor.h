// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <cstddef>
#include <string>

namespace nr030::gpu {

enum class Kernel : UINT { Color = 0, Depth = 1, Motion = 2, Residual = 3 };
struct TextureBinding {
    ID3D12Resource* resource = nullptr;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
};
struct BytecodeView {
    const void* data = nullptr;
    std::size_t size = 0;
};

// The caller owns the command list, resource states, queue submission and fences.
// Reserve DescriptorCount distinct descriptors PER outstanding dispatch; do not
// rewrite a used range, reset its allocator or release its resources before the
// submission fence has retired. Record never submits, waits or keeps resources.
class ShaderExecutor {
public:
    static constexpr UINT DescriptorCount = 5; // t0..t3, then u0
    void Initialize(ID3D12Device* device, const std::wstring& shaderDirectory);
    // Bytecode is consumed synchronously; embedded resources need no extra owner.
    void InitializeBytecode(ID3D12Device* device,
                            const std::array<BytecodeView, 4>& bytecode);
    void Record(Kernel kernel, ID3D12GraphicsCommandList* commands,
                ID3D12DescriptorHeap* visibleHeap, UINT firstDescriptor,
                const void* constants, UINT dwordCount,
                const TextureBinding* inputs, UINT inputCount,
                const TextureBinding& output, UINT dispatchWidth, UINT dispatchHeight) const;

    bool IsInitialized() const noexcept { return device_ != nullptr; }
    static const wchar_t* FileName(Kernel kernel);

private:
    struct Program {
        Microsoft::WRL::ComPtr<ID3D12RootSignature> root;
        Microsoft::WRL::ComPtr<ID3D12PipelineState> pipeline;
        UINT inputCount = 0;
        UINT constants = 0;
        UINT groupX = 0;
        UINT groupY = 0;
    };
    Microsoft::WRL::ComPtr<ID3D12Device> device_;
    std::array<Program, 4> programs_{};
};

// Explicit state transitions; these helpers do not infer or track game states.
void Transition(ID3D12GraphicsCommandList* commands, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after);
void UavBarrier(ID3D12GraphicsCommandList* commands, ID3D12Resource* resource);
void Check(HRESULT result, const char* operation);

} // namespace nr030::gpu
