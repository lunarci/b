[CmdletBinding()]
param([string]$BuildRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows with VS2022 C++ x64 tools is required.' }
$source=Split-Path -Parent $PSScriptRoot
if (-not $BuildRoot) { $BuildRoot=Join-Path $source 'build-local' }
$BuildRoot=[IO.Path]::GetFullPath($BuildRoot)
foreach ($tool in @('cmake','git')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw ($tool+' was not found.') } }
& cmake -S $source -B $BuildRoot -A x64 -DNR030_ENABLE_EXPERIMENTAL_RUNTIME=OFF
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
& cmake --build $BuildRoot --config Release --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
& ctest --test-dir $BuildRoot -C Release --output-on-failure --output-junit ctest-results.xml
if ($LASTEXITCODE -ne 0) { throw 'Native/WARP tests failed.' }
$ps51=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'package/Test-Package.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell package tests failed.' }
Write-Host 'Development tests finished. Runtime integration remains compile-time DISABLED.'
Write-Host 'This command creates no installable game package and changes no game files.'
