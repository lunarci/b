[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BuildRoot,
    [Parameter(Mandatory=$true)][string]$SourceCommit,
    [Parameter(Mandatory=$true)][string]$RunId,
    [switch]$ExperimentalReviewed
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $ExperimentalReviewed) { throw 'The runtime adapter review gate has not been enabled.' }
if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or $RunId -notmatch '^[0-9]+$') { throw 'Invalid immutable build provenance.' }
$sourceRoot=Split-Path -Parent $PSScriptRoot
$BuildRoot=[IO.Path]::GetFullPath($BuildRoot)
$binary=Join-Path $BuildRoot 'addon/Release/MatheusNR030.asi'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'The Windows x64 ASI build is missing.' }
$cache=Get-Content -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt') -Raw
if ($cache -notmatch '(?m)^NR030_ENABLE_EXPERIMENTAL_RUNTIME:BOOL=ON\r?$') { throw 'This ASI was built with the runtime integration disabled.' }
if ($cache -notmatch ('(?m)^NR030_SOURCE_COMMIT:STRING='+[regex]::Escape($SourceCommit)+'\r?$')) {
    throw 'Embedded source commit does not match the package provenance.'
}
$testLog=Join-Path $BuildRoot 'Testing/Temporary/LastTest.log'
if (-not (Test-Path -LiteralPath $testLog)) { throw 'Native test evidence is missing.' }
$installerResults=Get-Content -LiteralPath (Join-Path $sourceRoot 'package/test-results/installer-tests.json') -Raw | ConvertFrom-Json
if ($installerResults.WindowsPowerShell51 -ne $true -or $installerResults.Failed -ne 0 -or $installerResults.Passed -lt 21) {
    throw 'Windows PowerShell 5.1 installer test gate is not satisfied.'
}
[xml]$nativeResults=Get-Content -LiteralPath (Join-Path $BuildRoot 'ctest-results.xml') -Raw
if ([int]$nativeResults.testsuite.failures -ne 0 -or [int]$nativeResults.testsuite.tests -lt 2) {
    throw 'Native CTest/WARP test gate is not satisfied.'
}
$dist=Join-Path $BuildRoot 'deliverable/Matheus_NR030_Addon_0.1.0_experimental'
if (Test-Path -LiteralPath $dist) { throw 'Refusing to overwrite an existing staged deliverable.' }
New-Item -ItemType Directory -Path $dist | Out-Null
foreach ($name in @('Setup.ps1','01_INSTALL_ADDON.cmd','02_REMOVE_ADDON.cmd','03_CHECK_ADDON.cmd','README_KO.md','protected-files.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot ('package/'+$name)) -Destination $dist
}
New-Item -ItemType Directory -Path (Join-Path $dist 'payload') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dist 'evidence') | Out-Null
Copy-Item -LiteralPath $binary -Destination (Join-Path $dist 'payload/MatheusNR030.asi')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'addon/MatheusNR030.ini') -Destination (Join-Path $dist 'payload/MatheusNR030.ini')
Copy-Item -LiteralPath $testLog -Destination (Join-Path $dist 'evidence/LastTest.log')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'components/LICENSE') -Destination (Join-Path $dist 'LICENSE')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'components/NOTICE') -Destination (Join-Path $dist 'NOTICE')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'third_party') -Destination (Join-Path $dist 'third_party') -Recurse
Copy-Item -LiteralPath (Join-Path $sourceRoot 'runtime_contract.h') -Destination (Join-Path $dist 'evidence/runtime_contract.h')
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'runtime_static_evidence.md')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'runtime_static_evidence.md') -Destination (Join-Path $dist 'evidence/runtime_static_evidence.md')
}
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'package/test-results')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'package/test-results') -Destination (Join-Path $dist 'evidence/package-tests') -Recurse
}
$manifest=Get-Content -LiteralPath (Join-Path $sourceRoot 'package/package-manifest.json') -Raw | ConvertFrom-Json
$manifest.addon_version='0.1.0-experimental'
$manifest.source_commit=$SourceCommit
$manifest.build_run_id=$RunId
$manifest.build_verified=$true
$manifest.abi_verified=$true
$manifest.build_evidence='https://github.com/lunarci/b/actions/runs/'+$RunId
$manifest.abi_evidence='Exact C7 PE/disassembly contract only; evidence/runtime_contract.h; game execution unverified'
$manifest.game_runtime_verified=$false
$manifest.runtime_log_schema='matheusnr030-events-v1'
$manifest.files=@(foreach ($name in @('MatheusNR030.asi','MatheusNR030.ini')) {
    $path=Join-Path $dist ('payload/'+$name)
    [ordered]@{name=$name;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();size=(Get-Item -LiteralPath $path).Length}
})
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dist 'package-manifest.json') -Encoding UTF8
$provenance=[ordered]@{
    source='https://github.com/lunarci/b/tree/'+$SourceCommit+'/nr030-matheus'
    workflow='https://github.com/lunarci/b/actions/runs/'+$RunId
    base_nr_sha256=$manifest.base_nr_sha256
    validation_scope='Windows x64 build, production shader WARP tests, package synthetic tests, static exact-binary ABI review'
    amd_gpu_game_tested=$false
    performance_measured=$false
    baseline_files_changed=$false
}
$provenance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dist 'BUILD_PROVENANCE.json') -Encoding UTF8
$zip=$dist+'.zip'
Compress-Archive -Path $dist -DestinationPath $zip -CompressionLevel Optimal
Write-Host ('EXPERIMENTAL_PACKAGE='+$zip)
Get-FileHash -LiteralPath $zip -Algorithm SHA256
