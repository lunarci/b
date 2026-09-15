# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string] $BuildDirectory = (Join-Path $PSScriptRoot "build"),
    [ValidateSet("Debug", "Release")] [string] $Configuration = "Release"
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Windows and its D3D12 WARP runtime are required." }
& cmake -S $PSScriptRoot -B $BuildDirectory -A x64
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed: $LASTEXITCODE" }
& cmake --build $BuildDirectory --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "MSVC or shader compilation failed: $LASTEXITCODE" }
& ctest --test-dir $BuildDirectory -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "D3D12 WARP validation failed: $LASTEXITCODE" }
Write-Output ("WARP results: " + (Join-Path $BuildDirectory "warp_results.json"))

