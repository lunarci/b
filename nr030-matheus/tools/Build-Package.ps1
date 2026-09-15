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
if ($installerResults.WindowsPowerShell51 -ne $true -or $installerResults.Failed -ne 0 -or $installerResults.Passed -lt 28) {
    throw 'Windows PowerShell 5.1 installer test gate is not satisfied.'
}
$nativeResultPath=Join-Path $BuildRoot 'ctest-results.xml'
[xml]$nativeResults=Get-Content -LiteralPath $nativeResultPath -Raw
$suite=$nativeResults.DocumentElement
if ($suite.LocalName -cne 'testsuite' -or [int]$suite.GetAttribute('failures') -ne 0 -or
    [int]$suite.GetAttribute('skipped') -ne 0 -or [int]$suite.GetAttribute('disabled') -ne 0) {
    throw 'Native CTest suite has failures, skipped or disabled tests.'
}
foreach ($name in @('nr_component_math_checks','nr_pool_checks','nr030_warp_checks','nr030_addon_smoke','nr030_lifetime_checks')) {
    $cases=@($suite.SelectNodes('testcase') | Where-Object { $_.GetAttribute('name') -ceq $name })
    if ($cases.Count -ne 1 -or $cases[0].GetAttribute('status') -cne 'run' -or
        $null -ne $cases[0].SelectSingleNode('failure|error|skipped')) {
        throw ('Required native test did not pass: '+$name)
    }
}
$warpResultPath=Join-Path $BuildRoot 'gpu_tests/warp_results.json'
$warp=Get-Content -LiteralPath $warpResultPath -Raw | ConvertFrom-Json
if ($warp.runner -cne 'D3D12 WARP' -or $warp.productionShaders -ne $true -or
    $warp.sharedProductionExecutor -ne $true -or $warp.neuralRuntimeExecuted -ne $false -or
    $warp.failed -cne '' -or $warp.reason -cne '' -or $warp.passedCount -lt 29 -or
    @($warp.passed).Count -ne $warp.passedCount) {
    throw 'Production shader WARP execution evidence is incomplete or failed.'
}
$lifetimeResultPath=Join-Path $BuildRoot 'addon/lifetime_results.json'
$lifetime=Get-Content -LiteralPath $lifetimeResultPath -Raw | ConvertFrom-Json
if ($lifetime.passedCount -lt 13 -or $lifetime.failure -cne '' -or
    @($lifetime.passed).Count -ne $lifetime.passedCount -or $lifetime.amdGpuGameTested -ne $false) {
    throw 'Production lifetime queue/Reset validation is incomplete.'
}
$dist=Join-Path $BuildRoot 'deliverable/Matheus_NR030_Addon_0.2.1_MapRecovery'
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
Copy-Item -LiteralPath $nativeResultPath -Destination (Join-Path $dist 'evidence/ctest-results.xml')
Copy-Item -LiteralPath $warpResultPath -Destination (Join-Path $dist 'evidence/warp_results.json')
Copy-Item -LiteralPath $lifetimeResultPath -Destination (Join-Path $dist 'evidence/lifetime_results.json')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'components/LICENSE') -Destination (Join-Path $dist 'LICENSE')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'components/NOTICE') -Destination (Join-Path $dist 'NOTICE')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'third_party') -Destination (Join-Path $dist 'third_party') -Recurse
Copy-Item -LiteralPath (Join-Path $sourceRoot 'COMPARISON_KO.md') -Destination $dist
Copy-Item -LiteralPath (Join-Path $sourceRoot 'MAP_RECOVERY_KO.md') -Destination $dist
# Include the reviewed add-on source and pinned Windows build recipe alongside
# the binary. The existing NR engine, model and XeFG binaries are not redistributed.
$sourceStage=Join-Path $BuildRoot 'deliverable/combined-source'
New-Item -ItemType Directory -Path $sourceStage | Out-Null
Copy-Item -LiteralPath $sourceRoot -Destination (Join-Path $sourceStage 'nr030-matheus') -Recurse
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $sourceRoot) '.github/workflows/build-matheus-nr030.yml') -Destination $sourceStage
Compress-Archive -Path (Join-Path $sourceStage '*') -DestinationPath (Join-Path $dist 'SOURCE.zip') -CompressionLevel Optimal
Copy-Item -LiteralPath (Join-Path $sourceRoot 'runtime_contract.h') -Destination (Join-Path $dist 'evidence/runtime_contract.h')
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'runtime_static_evidence.md')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'runtime_static_evidence.md') -Destination (Join-Path $dist 'evidence/runtime_static_evidence.md')
}
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'package/test-results')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'package/test-results') -Destination (Join-Path $dist 'evidence/package-tests') -Recurse
}
$manifest=Get-Content -LiteralPath (Join-Path $sourceRoot 'package/package-manifest.json') -Raw | ConvertFrom-Json
$manifest.addon_version='0.2.1-map-recovery-experimental'
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
    validation_scope='Windows MSVC x64 build; embedded shader identity and disabled loader smoke; production shader WARP tests; Windows PowerShell 5.1 package tests; static exact-C7 ABI review'
    source_commit=$SourceCommit
    build_run_id=$RunId
    runtime_enabled_at_build=$true
    default_scale_percent=85
    default_colour_preservation_percent=100
    default_depth_protection=$true
    default_effect_percent=100
    matias_reference_commit='333038704896d6e38f735b9ddb6e62210e509cb9'
    yuri_reference_commit='0c123fc4bb81bbcb343246e3c98a3bcb33a1009c'
    colour_integration='Same-encoding luminance transfer after AMD residual; no upstream codec or model replacement'
    windows_native_tests=@('nr_component_math_checks','nr_pool_checks','nr030_warp_checks','nr030_addon_smoke','nr030_lifetime_checks')
    lifetime_checks_passed=$lifetime.passedCount
    all_completed_slots_swept=$true
    idle_scratch_trim_ms=2000
    retained_warm_slots=2
    actual_map_fps_recovery_verified=$false
    warp_checks_passed=$warp.passedCount
    installer_checks_passed=$installerResults.Passed
    installer_windows_powershell51=$installerResults.WindowsPowerShell51
    amd_gpu_game_tested=$false
    performance_measured=$false
    baseline_files_changed=$false
}
$provenance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dist 'BUILD_PROVENANCE.json') -Encoding UTF8
$status=@'
# Matheus NR030 0.2.1 MapRecovery 실험용 설치 패키지

맵 전환 뒤 회수 가능한 옛 GPU 자원이 남는 경로를 수정하고, 완료된 유휴 버퍼를 줄입니다. 실제 맵 복귀 FPS 회복 여부는 아직 검증하지 않았습니다. MAP_RECOVERY_KO.md에 원인 검토와 비교 절차가 있습니다.

matiasLombo의 색상 보존 원리와 Yuri의 깊이 경계 보호를 기존 Matheus 85% 잔차 합성에 통합했습니다. 새 NR 엔진이나 모델은 포함하지 않습니다. COMPARISON_KO.md에 비교·채택 범위, SOURCE.zip에 수정 소스가 있습니다.

## 완료한 검증

- Windows MSVC x64 빌드
- 4개 HLSL의 Microsoft 컴파일러 컴파일
- 동일 생산용 셰이더를 D3D12 WARP에서 실제 실행
- 완성 ASI 로딩, InitializeASI export, PatchResult 미노출, 내장 셰이더4개 원본 일치 확인
- Enabled=0 상태의 초기화·로그·중복 초기화 방지 확인
- Windows PowerShell 5.1의 설치·재설치·제거·실패 복원 합성 검사
- 정확한 C7 NR0.3.0 바이너리의 정적 해시·PE·함수 구조 확인

## 실제 게임에서는 아직 확인하지 않은 항목

RX9070XT에서 기존 NR을 연결하여 85% 입력으로 추론한 뒤 FSR·XeFG4X까지 정상 작동하는지, 화질·지연·FPS·장시간 안정성은 미검증입니다. Windows 검증 통과는 게임 검증 통과가 아닙니다.

추가 모듈만 기본 85%로 설치하며 기존 NR·OptiScaler·XeFG 파일 및 설정은 변경하지 않습니다. 적용할 수 없는 호출은 우회합니다. 축소 NR이 시작된 뒤의 우회는 해당 호출에서 NR을 생략할 수 있으므로 검사 결과의 resolved/fallback 수치를 확인해야 합니다. 다른 바이너리나 지원하지 않는 입력에서는 기능이 켜지지 않을 수 있습니다.

설치: 게임·MO2 종료 → 01_INSTALL_ADDON.cmd → 평소처럼 실행
제거: 게임·MO2 종료 → 02_REMOVE_ADDON.cmd
검사: 실행 후 03_CHECK_ADDON.cmd → Results/MATHEUS_CHECK.txt
자세한 설명과 비교 방법은 README_KO.md에 있습니다.

빌드 실행·소스 커밋·검사 수치는 BUILD_PROVENANCE.json, 원문 결과는 evidence/를 확인하십시오.
'@
$status | Set-Content -LiteralPath (Join-Path $dist 'BUILD_STATUS_KO.md') -Encoding UTF8
# Validate the exact staged payload using the same read-only PE/hash gate as installation.
& {
    param($StagedRoot)
    . (Join-Path $StagedRoot 'Setup.ps1')
    $null=Get-VerifiedManifest
} $dist
$zip=$dist+'.zip'
Compress-Archive -Path $dist -DestinationPath $zip -CompressionLevel Optimal
Write-Host ('EXPERIMENTAL_PACKAGE='+$zip)
Get-FileHash -LiteralPath $zip -Algorithm SHA256
