#!/usr/bin/env python3
"""Compile the actual SetResource tagging block with a state-validating fake GPU.

This checks CPU control flow and barrier ordering, not driver/XeFG execution.
Usage: python test_xefg_resource_guard.py /path/to/OptiScaler [--cxx c++]
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("--cxx", default=None)
args = parser.parse_args()
source = (args.source / "OptiScaler/framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8-sig")
method = source.split("bool XeFG_Dx12::SetResource(Dx12Resource* inputResource)", 1)[1]
start = method.index("        xefg_swapchain_d3d12_resource_data_t resourceParam = GetResourceData(type, fIndex);")
end_marker = "        SetResourceReady(type, fIndex);"
end = method.index(end_marker, start) + len(end_marker)
actual_block = textwrap.dedent(method[start:end])
compiler = args.cxx
if compiler is None and os.name != "nt":
    compiler = shutil.which("c++") or shutil.which("clang++") or shutil.which("g++")
if compiler is None and os.name != "nt":
    parser.error("a C++17 compiler is required; pass --cxx")

prefix = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <tuple>
#include <vector>
#define LOG_ERROR(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
enum D3D12_RESOURCE_STATES { D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE,
    D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE };
enum class FG_ResourceType { UIColor, Depth };
enum xefg_result { XEFG_SWAPCHAIN_RESULT_SUCCESS, XEFG_SWAPCHAIN_RESULT_ERROR };
constexpr int XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT = 1, BUFFER_COUNT = 4;
struct feature_version {
    int major, minor, patch;
    bool operator<(const feature_version& v) const {
        return std::tie(major, minor, patch) < std::tie(v.major, v.minor, v.patch);
    }
};
struct ID3D12GraphicsCommandList {};
struct Resource { D3D12_RESOURCE_STATES state; };
struct Dx12Resource {
    D3D12_RESOURCE_STATES state;
    Resource* resource;
    ID3D12GraphicsCommandList* cmdList;
};
struct xefg_swapchain_d3d12_resource_data_t {
    D3D12_RESOURCE_STATES incomingState;
    int validity = XEFG_SWAPCHAIN_RV_UNTIL_NEXT_PRESENT;
};
enum Event { Forward, Tag, Restore, Update, DeactivateEvent, Ready };
static std::vector<Event> events;
static bool failTag;
static Resource* liveResource;
struct State {
    bool fgChanged = false;
    static State& Instance() { static State s; return s; }
};
struct Flag { bool value_or_default() { return false; } };
struct Config {
    Flag FGDrawUIOverFG;
    static Config* Instance() { static Config c; return &c; }
};
struct XeFGProxy {
    static void* SetUiCompositionState() { return nullptr; }
    static xefg_result TagResource(void*, ID3D12GraphicsCommandList*, uint32_t,
                                 xefg_swapchain_d3d12_resource_data_t* p) {
        assert(p->incomingState == liveResource->state);
        events.push_back(Tag);
        return failTag ? XEFG_SWAPCHAIN_RESULT_ERROR : XEFG_SWAPCHAIN_RESULT_SUCCESS;
    }
    static auto D3D12TagFrameResource() { return &TagResource; }
};
struct Subject {
    Dx12Resource* tagged = nullptr;
    uint64_t _frameCount = 8;
    void* _swapChainContext = nullptr;
    int GetIndex() { return 0; }
    xefg_swapchain_d3d12_resource_data_t GetResourceData(FG_ResourceType, int) {
        return {tagged->state};
    }
    void ResourceBarrier(ID3D12GraphicsCommandList* cmd, Resource* r,
                         D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
        assert(cmd != nullptr);
        assert(r->state == before);
        r->state = after;
        events.push_back(after == D3D12_RESOURCE_STATE_COPY_DEST ? Forward : Restore);
    }
    void UpdateTarget() { events.push_back(Update); }
    void Deactivate() { events.push_back(DeactivateEvent); }
    void SetResourceReady(FG_ResourceType, int) { events.push_back(Ready); }
    bool Run(feature_version version, Dx12Resource* inputResource, bool skipUi) {
        Dx12Resource frameResource = *inputResource;
        auto* fResource = &frameResource;
        tagged = fResource;
        auto type = skipUi ? FG_ResourceType::UIColor : FG_ResourceType::Depth;
        int fIndex = 0;
'''
suffix = r'''
        return true;
    }
};
int main() {
    int cases = 0;
    for (auto version : {feature_version{1,2,1}, feature_version{1,2,2}, feature_version{1,3,1}})
    for (auto state : {D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE,
                      D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE})
    for (bool noCommandList : {false, true})
    for (bool skipUi : {false, true})
    for (bool tagFails : {false, true}) {
        events.clear(); State::Instance().fgChanged = false; failTag = tagFails;
        Resource resource{state}; liveResource = &resource;
        ID3D12GraphicsCommandList commands;
        Dx12Resource input{state, &resource, noCommandList ? nullptr : &commands};
        Subject subject;
        bool result = subject.Run(version, &input, skipUi);
        const bool legacyCopy = version < feature_version{1,2,2} && state == D3D12_RESOURCE_STATE_COPY_SOURCE;
        const bool unsupported = legacyCopy && noCommandList;
        const bool tagFailed = !unsupported && !skipUi && tagFails;
        assert(result == (!unsupported && !tagFailed));
        assert(resource.state == state);
        assert(input.state == state);
        assert(std::count(events.begin(), events.end(), Forward) == (legacyCopy && !unsupported ? 1 : 0));
        assert(std::count(events.begin(), events.end(), Restore) == (legacyCopy && !unsupported ? 1 : 0));
        assert(std::count(events.begin(), events.end(), Tag) == (!unsupported && !skipUi ? 1 : 0));
        assert(std::count(events.begin(), events.end(), Ready) == (result ? 1 : 0));
        assert(State::Instance().fgChanged == tagFailed);
        if (unsupported) assert(events.empty());
        if (tagFailed && legacyCopy) {
            assert(std::find(events.begin(), events.end(), Restore) < std::find(events.begin(), events.end(), Update));
            assert(std::find(events.begin(), events.end(), Update) < std::find(events.begin(), events.end(), DeactivateEvent));
        }
        ++cases;
    }
    std::cout << "PASS: " << cases << " scenarios using actual XeFG SetResource code\n";
}
'''
with tempfile.TemporaryDirectory(prefix="xefg-guard-") as tmp:
    directory = Path(tmp)
    cpp = directory / "guard.cpp"
    executable = directory / "guard-test"
    cpp.write_text(prefix + actual_block + "\n" + suffix, encoding="utf-8")
    if compiler is not None:
        subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(executable)], check=True)
    else:
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        msbuild = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires",
            "Microsoft.Component.MSBuild", "-find", r"MSBuild\**\Bin\MSBuild.exe"], text=True).strip().splitlines()[0]
        project = directory / "guard.vcxproj"
        project.write_text(r'''<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup Label="ProjectConfigurations"><ProjectConfiguration Include="Debug|x64"><Configuration>Debug</Configuration><Platform>x64</Platform></ProjectConfiguration></ItemGroup>
  <PropertyGroup Label="Globals"><Keyword>Win32Proj</Keyword><WindowsTargetPlatformVersion>10.0</WindowsTargetPlatformVersion></PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <PropertyGroup Label="Configuration"><ConfigurationType>Application</ConfigurationType><UseDebugLibraries>false</UseDebugLibraries><PlatformToolset>v143</PlatformToolset></PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />
  <PropertyGroup><OutDir>$(ProjectDir)out\</OutDir><IntDir>$(ProjectDir)obj\</IntDir><TargetName>guard-test</TargetName></PropertyGroup>
  <ItemDefinitionGroup><ClCompile><LanguageStandard>stdcpp17</LanguageStandard><WarningLevel>Level4</WarningLevel><Optimization>Disabled</Optimization><UndefinePreprocessorDefinitions>NDEBUG;%(UndefinePreprocessorDefinitions)</UndefinePreprocessorDefinitions></ClCompile><Link><SubSystem>Console</SubSystem></Link></ItemDefinitionGroup>
  <ItemGroup><ClCompile Include="guard.cpp" /></ItemGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
''', encoding="utf-8")
        subprocess.run([msbuild, str(project), "/p:Configuration=Debug", "/p:Platform=x64", "/verbosity:minimal"], check=True)
        executable = directory / "out/guard-test.exe"
    subprocess.run([str(executable)], check=True)
