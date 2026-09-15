// SPDX-License-Identifier: GPL-3.0-only
// Shader compile check only. This tool never opens a game or loads an NR runtime.
#ifdef _WIN32
#include <d3dcompiler.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#pragma comment(lib, "d3dcompiler.lib")

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: compile_nr_components SOURCE_DIR OUTPUT_DIR\n";
        return 2;
    }
    try {
        const std::filesystem::path source_dir(argv[1]), output_dir(argv[2]);
        std::filesystem::create_directories(output_dir);
        const char* names[] = {"area_downsample", "matched_residual_resolve",
                               "depth_nearest", "motion_nearest"};
        for (const auto* name : names) {
            const auto input = source_dir / (std::string(name) + ".hlsl");
            ID3DBlob* bytecode = nullptr;
            ID3DBlob* errors = nullptr;
            const UINT flags = D3DCOMPILE_ENABLE_STRICTNESS |
                               D3DCOMPILE_WARNINGS_ARE_ERRORS |
                               D3DCOMPILE_IEEE_STRICTNESS |
                               D3DCOMPILE_OPTIMIZATION_LEVEL3;
            const HRESULT hr = D3DCompileFromFile(input.c_str(), nullptr,
                D3D_COMPILE_STANDARD_FILE_INCLUDE, "MainCS", "cs_5_0",
                flags, 0, &bytecode, &errors);
            if (errors) {
                std::cerr.write(static_cast<const char*>(errors->GetBufferPointer()),
                                static_cast<std::streamsize>(errors->GetBufferSize()));
                errors->Release();
            }
            if (FAILED(hr) || !bytecode) {
                if (bytecode) bytecode->Release();
                std::cerr << name << ": HLSL compile failed\n";
                return 1;
            }
            const auto output = output_dir / (std::string(name) + ".cso");
            std::ofstream stream(output, std::ios::binary);
            stream.write(static_cast<const char*>(bytecode->GetBufferPointer()),
                         static_cast<std::streamsize>(bytecode->GetBufferSize()));
            const bool wrote = stream.good();
            bytecode->Release();
            if (!wrote) {
                std::cerr << name << ": output write failed\n";
                return 1;
            }
            std::cout << name << ": compiled cs_5_0\n";
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    return 0;
}
#else
#error This compile checker requires Windows SDK and d3dcompiler.
#endif

