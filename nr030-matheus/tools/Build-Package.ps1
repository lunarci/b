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
if ($installerResults.WindowsPowerShell51 -ne $true -or $installerResults.Failed -ne 0 -or $installerResults.Passed -lt 36) {
    throw 'Windows PowerShell 5.1 installer test gate is not satisfied.'
}
foreach ($name in @('missing-legacy-record-install-repeat-remove','missing-legacy-record-wrong-hash-blocked','missing-legacy-record-wrong-settings-blocked','conflicting-legacy-record-blocked','missing-legacy-record-does-not-bypass-addon-ownership','missing-base-file-is-not-reported-as-hash-mismatch','current-input-rejection-is-not-reported-as-working-scale','luma-stability-config-is-observed-not-visual-proof')) {
    $cases=@($installerResults.Tests | Where-Object { $_.Test -ceq $name })
    if ($cases.Count -ne 1 -or $cases[0].Status -cne 'PASS') { throw ('Required installer regression did not pass: '+$name) }
}
$completeResults=Get-Content -LiteralPath (Join-Path $sourceRoot 'package/test-results/complete-installer-tests.json') -Raw | ConvertFrom-Json
if ($completeResults.WindowsPowerShell51 -ne $true -or $completeResults.Failed -ne 0 -or
    $completeResults.Passed -lt 31 -or $completeResults.GameRuntimeVerified -ne $false) {
    throw 'Windows PowerShell 5.1 complete installer test gate is not satisfied.'
}
foreach ($name in @('absent-nr-model-and-inis-downloaded-before-install','corrupt-download-blocked-before-game-writes','failed-addon-step-rolls-back-new-base-and-state','failed-upgrade-restores-old-addon-and-ownership','disable-nr-preserves-fsr-xefg-and-reinstall-reenables','disable-nr-failure-restores-all-ini-and-state-bytes','disabled-install-can-restore-complete-originals','requested-ratio-two-updates-both-ark-and-overwrite-ini','ratio-check-reports-configured-expectation-without-runtime-claim','regenerated-weights-are-backed-up-and-do-not-block-restore','standalone-recovery-configures-two-and-disables-both-nr-layers','recovery-failure-rolls-back-ratio-enabled-flags-and-state','recovery-missing-primary-opti-ini-stops-before-changes','owned-addon-upgrade-preserves-tuned-ini-and-state')) {
    $cases=@($completeResults.Tests | Where-Object { $_.Test -ceq $name })
    if ($cases.Count -ne 1 -or $cases[0].Status -cne 'PASS') { throw ('Required complete installer regression did not pass: '+$name) }
}
$nativeResultPath=Join-Path $BuildRoot 'ctest-results.xml'
[xml]$nativeResults=Get-Content -LiteralPath $nativeResultPath -Raw
$suite=$nativeResults.DocumentElement
if ($suite.LocalName -cne 'testsuite' -or [int]$suite.GetAttribute('failures') -ne 0 -or
    [int]$suite.GetAttribute('skipped') -ne 0 -or [int]$suite.GetAttribute('disabled') -ne 0) {
    throw 'Native CTest suite has failures, skipped or disabled tests.'
}
foreach ($name in @('nr_component_math_checks','nr_pool_checks','nr030_warp_checks','nr030_addon_smoke','nr030_lifetime_checks','nr030_input_checks')) {
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
    $warp.failed -cne '' -or $warp.reason -cne '' -or $warp.passedCount -lt 47 -or
    @($warp.passed).Count -ne $warp.passedCount) {
    throw 'Production shader WARP execution evidence is incomplete or failed.'
}
foreach ($required in @(
    '85% HDR outlier keeps its 2.5% interpolation support',
    '85% negative outlier keeps its 2.5% interpolation support',
    'Residual rejects mismatched taps even when their baseline average matches',
    'Tap guards retain matched uniform HDR correction and RGB ratios',
    'Tap guards preserve signed FP16 identity on the 85% grid',
    'Luma stability suppresses new checker detail at 0 50 and 100 percent',
    'Luma stability preserves native high-frequency identity on the 85% grid',
    'Luma stability retains correction that removes existing baseline detail',
    'Luma stability retains uniform HDR correction and RGB ratios',
    'Luma stability never expands positive or negative outlier support',
    'Luma stability retains per-tap rejection of falsely matching averages',
    'Luma stability rejects same-colour neighbours across a depth edge',
    'Luma stability rejects neighbours across a baseline colour edge',
    'Luma stability ignores malformed extra neighbours without enlarging fallback'
)) {
    if ($warp.passed -cnotcontains $required) { throw ('Missing image stability regression: '+$required) }
}
$lifetimeResultPath=Join-Path $BuildRoot 'addon/lifetime_results.json'
$lifetime=Get-Content -LiteralPath $lifetimeResultPath -Raw | ConvertFrom-Json
if ($lifetime.passedCount -lt 13 -or $lifetime.failure -cne '' -or
    @($lifetime.passed).Count -ne $lifetime.passedCount -or $lifetime.amdGpuGameTested -ne $false) {
    throw 'Production lifetime queue/Reset validation is incomplete.'
}
$inputResultPath=Join-Path $BuildRoot 'addon/input_results.json'
$inputChecks=Get-Content -LiteralPath $inputResultPath -Raw | ConvertFrom-Json
if ($inputChecks.passedCount -lt 16 -or $inputChecks.failure -cne '' -or
    @($inputChecks.passed).Count -ne $inputChecks.passedCount -or $inputChecks.amdGpuGameTested -ne $false) {
    throw 'Production input admission validation is incomplete.'
}
$dist=Join-Path $BuildRoot 'deliverable/Matheus_NR030_0.2.4_LumaStability'
if (Test-Path -LiteralPath $dist) { throw 'Refusing to overwrite an existing staged deliverable.' }
New-Item -ItemType Directory -Path $dist | Out-Null
foreach ($name in @('Setup.ps1','Complete-Setup.ps1','00_FIX_RATIO_AND_DISABLE_NR.cmd','01_INSTALL_ADDON.cmd','02_REMOVE_ADDON.cmd','03_CHECK_ADDON.cmd','04_RESTORE_FSR_XEFG.cmd','05_REMOVE_AND_RESTORE_BASE.cmd','README_KO.md','protected-files.json')) {
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
Copy-Item -LiteralPath $inputResultPath -Destination (Join-Path $dist 'evidence/input_results.json')
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
$manifest.addon_version='0.2.4-luma-stability-experimental'
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
    default_effect_percent=50
    default_luma_stability_percent=100
    luma_stability_policy='Attenuate existing guarded taps when same-frame guided cross statistics detect added luminance contrast'
    luma_stability_game_verified=$false
    requested_upscaler_ratio=2.0
    residual_guard='Per-tap clamp and baseline confidence before bilinear interpolation'
    temporal_filter_added=$false
    user_reported_white_artifact_fix_verified=$false
    matias_reference_commit='333038704896d6e38f735b9ddb6e62210e509cb9'
    yuri_reference_commit='0c123fc4bb81bbcb343246e3c98a3bcb33a1009c'
    colour_integration='Same-encoding luminance transfer after AMD residual; no upstream codec or model replacement'
    windows_native_tests=@('nr_component_math_checks','nr_pool_checks','nr030_warp_checks','nr030_addon_smoke','nr030_lifetime_checks','nr030_input_checks')
    input_admission_checks_passed=$inputChecks.passedCount
    supported_motion_formats=@('DXGI_FORMAT_R16G16_FLOAT','DXGI_FORMAT_R16G16B16A16_FLOAT')
    rejected_scaled_dispatch_policy='Original FFX without NR; explicit 100 percent still uses original NR'
    lifetime_checks_passed=$lifetime.passedCount
    all_completed_slots_swept=$true
    idle_scratch_trim_ms=2000
    retained_warm_slots=2
    actual_map_fps_recovery_verified=$false
    warp_checks_passed=$warp.passedCount
    installer_checks_passed=$installerResults.Passed
    installer_windows_powershell51=$installerResults.WindowsPowerShell51
    complete_installer_checks_passed=$completeResults.Passed
    complete_installer_windows_powershell51=$completeResults.WindowsPowerShell51
    installer_revision='complete-0.2.4'
    legacy_base_record_required=$false
    base_compatibility='Verified existing C7 ASI and model or pinned automatic downloads; required NR / OptiScaler / XeFG route keys and requested ratio 2.0 backed up before changes'
    amd_gpu_game_tested=$false
    performance_measured=$false
    baseline_changes='Missing/incompatible NR and model; required route INI keys and user-requested upscale ratio 2.0; transactional backups'
    optiscaler_and_xefg_binaries_replaced=$false
}
$provenance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dist 'BUILD_PROVENANCE.json') -Encoding UTF8
$status=@'
# Matheus NR030 0.2.4 휘도 보정 안정화 설치본

0.2.4는 원본보다 NR 결과에서 증가한 국소적인 밝기 대비를 검사합니다. 같은 프레임의 고정된 주변 픽셀을 참고해 기존 NR 보정량을 약화합니다. 원본 영상 자체를 흐리거나 주변 보정값으로 덮어쓰지 않습니다.

0.2.3의 픽셀별 제한 후 보간 순서를 유지합니다. 잔차가 0인 픽셀에 주변의 보정값을 추가하지 않으며, 원본 색과 깊이가 다른 이웃의 영향을 제한합니다. 전체적으로 일정한 HDR 입력과 보정, 원래 입력 노이즈를 줄이는 NR 보정, 기존 외곽 보호를 검증합니다.

LumaStabilityPercent=100이 기본입니다. 0은 이번 억제만 끄며 기존 0.2.3 합성 방식으로 비교합니다. NR 전체를 끄는 설정이 아닙니다. 공간적으로 거친 보정에 섞여 있는 유효한 밝기 변화나 작은 세부 대비도 약해질 수 있습니다. 피부나 흰색 조명을 판별하는 기능이 아니며, 균일한 넓은 영역의 시간적 깜빡임과 원본 자체의 자글거림을 해결한다고 검증하지 않았습니다.

새 GPU 텍스처·이전 프레임 누적·추가 dispatch는 없지만 이웃을 읽는 셰이더 연산은 증가합니다. 실제 Radeon 게임의 처리 시간과 화질 개선은 확인 전입니다.

필요한 기본 NR C7과 모델 310.8.0을 기존 파일에서 검증·재사용하거나 지정 출처에서 다운로드합니다. 압축 파일과 추출 파일의 크기 및 SHA-256을 모두 확인한 뒤 설치합니다. 기본 NR·모델은 이 ZIP에 재배포하지 않습니다. 기존 OptiScaler·XeFG 실행 파일은 유지합니다.

재윤님 요청에 따라 설치 시 OptiScaler 전체 배율을 2.0으로 설정합니다. 4K 출력 기준 입력은 1920×1080이며 85% NR 입력은 1632×918입니다. 설정 검사는 파일 설정값을 확인하며 게임이 실제로 사용한 크기까지 자동으로 입증하지는 않습니다.

새 추가 모드 INI는 85% 입력·색상 보존 100%·깊이 보호 켬·합성 강도 50%·휘도 안정화 100%가 기본입니다. 기존에 조정한 INI는 유지될 수 있습니다. 50% 합성 강도는 과한 보정을 줄여 비교하기 위한 값이며 NR 추론 시간을 절반으로 줄이는 값이 아닙니다.

## 완료한 검증

- Windows MSVC x64 빌드와 생산용 HLSL 4개 컴파일
- 같은 생산용 셰이더를 D3D12 WARP에서 실행: RG16F 및 RGBA16F 모션 입력 포함
- 생산용 입력 형식 판정, 자원 수명·Reset, ASI 로딩·내장 셰이더·비활성 초기화 검사
- Windows PowerShell 5.1에서 설치·다운로드 오류·설정 변경·재설치·실패 복원·NR 끔 검사
- 정확한 C7 NR 0.3.0의 정적 해시·PE·함수 구조 검토

## 실제 게임 검증 범위

RX 9070 XT에서 피부 모자이크·움직임 잔상·입력지연·맵 복귀 FPS가 해결됐는지는 아직 확인하지 않았습니다. WARP는 Windows 소프트웨어 GPU에서 추가 모드의 셰이더를 실행한 검사이며 기본 NR 신경망과 Radeon 게임 실행 검증은 아닙니다.

설치: 게임·MO2 종료 → 01_INSTALL_ADDON.cmd → 평소처럼 MO2에서 게임 실행
검사: 새 게임 실행 뒤 03_CHECK_ADDON.cmd → Results/MATHEUS_CHECK.txt
화면·지연 비교 복구: 게임·MO2 종료 → 04_RESTORE_FSR_XEFG.cmd → NR 두 모드를 끄고 기존 FSR·XeFG 유지
추가 모드만 제거: 02_REMOVE_ADDON.cmd
추가 모드 제거 및 기본 NR·설정 변경 복원: 05_REMOVE_AND_RESTORE_BASE.cmd

자세한 설명은 README_KO.md, 빌드·소스·시험 수치는 BUILD_PROVENANCE.json과 evidence/에 있습니다. MAP_RECOVERY_KO.md는 이전 0.2.1 자원 회수 수정 기록입니다.

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
