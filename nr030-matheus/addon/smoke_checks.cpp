// SPDX-License-Identifier: GPL-3.0-only
// Loads the actual ASI with Enabled=0. This is not an NR/GPU/gameplay test.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
std::vector<char> ReadFileBytes(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot open smoke-test input file");
    std::vector<char> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (!input.eof() && input.fail()) throw std::runtime_error("Cannot read smoke-test input file");
    return bytes;
}
std::string ReadLog(const std::filesystem::path& path) {
    if (!std::filesystem::is_regular_file(path)) return {};
    const auto bytes = ReadFileBytes(path);
    return std::string(bytes.begin(), bytes.end());
}
std::size_t Count(const std::string& text, const std::string& token) {
    std::size_t found = 0, offset = 0;
    while ((offset = text.find(token, offset)) != std::string::npos) {
        ++found; offset += token.size();
    }
    return found;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    try {
        Require(argc == 4, "Usage: nr030_addon_smoke <built ASI> <shared shader directory> <scratch directory>");
        const auto source = std::filesystem::absolute(argv[1]);
        const auto shaderDirectory = std::filesystem::absolute(argv[2]);
        const auto root = std::filesystem::absolute(argv[3]);
        std::filesystem::create_directories(root);
        const auto unique = L"loader-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                            std::to_wstring(GetTickCount64());
        const auto directory = root / unique;
        Require(std::filesystem::create_directory(directory), "Smoke directory already exists");
        const auto copy = directory / L"MatheusNR030.asi";
        std::filesystem::copy_file(source, copy);
        {
            std::ofstream settings(directory / L"MatheusNR030.ini", std::ios::binary);
            settings << "; Disabled CI loader smoke, never a game configuration.\r\n"
                        "[MatheusNR030]\r\nEnabled=0\r\nScalePercent=85\r\n";
            Require(bool(settings), "Cannot create disabled smoke INI");
        }

        // Hold the original reference until process exit. InitializeASI pins the
        // module as well; unloading or deleting it during this test is forbidden.
        const HMODULE module = LoadLibraryExW(copy.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module) throw std::runtime_error("Actual ASI LoadLibraryExW failed: Win32 " + std::to_string(GetLastError()));
        const auto initialize = reinterpret_cast<void(*)()>(GetProcAddress(module, "InitializeASI"));
        Require(initialize != nullptr, "InitializeASI export is missing");
        Require(GetProcAddress(module, "PatchResult") == nullptr,
                "PatchResult must not be exported because OptiScaler assigns it unrelated behavior");

        const std::array<const wchar_t*, 4> files = {
            L"area_downsample.cso", L"depth_nearest.cso", L"motion_nearest.cso", L"matched_residual_resolve.cso"};
        for (unsigned index = 0; index < files.size(); ++index) {
            const auto expected = ReadFileBytes(shaderDirectory / files[index]);
            Require(expected.size() >= 4 && std::memcmp(expected.data(), "DXBC", 4) == 0,
                    "Shared production shader is not a DXBC container");
            const HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(101 + index), MAKEINTRESOURCEW(10));
            Require(resource != nullptr, "A production shader resource 101-104 is missing");
            const DWORD size = SizeofResource(module, resource);
            Require(size == expected.size(), "Embedded shader length differs from WARP-tested production CSO");
            const HGLOBAL loaded = LoadResource(module, resource);
            const void* bytes = loaded ? LockResource(loaded) : nullptr;
            Require(bytes != nullptr && std::memcmp(bytes, expected.data(), expected.size()) == 0,
                    "Embedded shader bytes differ from WARP-tested production CSO");
        }

        initialize();
        initialize(); // Must not launch a second worker or clear the first log.
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        std::string log;
        for (;;) {
            log = ReadLog(directory / L"MatheusNR030.log");
            Require(log.find("event=hook_active") == std::string::npos,
                    "A disabled ASI unexpectedly installed a game hook");
            const bool disabled = log.find("event=disabled reason=experimental_runtime_not_enabled_at_build") != std::string::npos ||
                                  log.find("event=disabled reason=Enabled_not_1") != std::string::npos;
            if (disabled) break;
            Require(std::chrono::steady_clock::now() < deadline, "Disabled initialization log timed out");
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        // A second worker, if erroneously started, gets a short opportunity to
        // produce its entry; process startup and the actual DLL are exercised.
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        log = ReadLog(directory / L"MatheusNR030.log");
        Require(Count(log, "event=session_start ") == 1 && Count(log, "event=disabled reason=") == 1,
                "InitializeASI was not idempotent or the disabled session log is incomplete");
        Require(log.find("event=hook_active") == std::string::npos,
                "The disabled session reported an active game hook");
        std::cout << "PASS: actual ASI loads; InitializeASI exists; PatchResult absent; all four embedded shaders match; "
                     "disabled initialization is idempotent; no hook reported.\n"
                     "Scope: loader/exports/resources/disabled startup only; no NR, GPU, or game execution.\n";
        std::wcout << L"Smoke evidence directory: " << directory.c_str() << L"\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << "\n";
        return 1;
    }
}
