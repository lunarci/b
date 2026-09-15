#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$componentRoot=$PSScriptRoot
. (Join-Path $componentRoot 'Setup.ps1') -Action Check
$productionHash=$script:ExpectedNrHash
$productionPackage=$script:PackageRoot
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('MatheusNR030-Tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('ASSERTION: '+$Message) }
}
function Assert-Throws([scriptblock]$Code,[string]$ExpectedPattern) {
    $caught=$null
    try { & $Code | Out-Null } catch { $caught=$_ }
    if ($null -eq $caught) { throw ('Expected failure: '+$ExpectedPattern) }
    if ($caught.Exception.Message -notmatch $ExpectedPattern) { throw ('Unexpected failure: '+$caught.Exception.Message+'; expected '+$ExpectedPattern) }
}
function Write-FakePe([string]$Path) {
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=0x80
    $bytes[128]=0x50; $bytes[129]=0x45; $bytes[132]=0x64; $bytes[133]=0x86
    $bytes[151]=0x20
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function Update-FixtureManifest($Fixture) {
    $manifest=Read-Json (Join-Path $Fixture.Package 'package-manifest.json')
    foreach ($entry in $manifest.files) {
        $path=Join-Path (Join-Path $Fixture.Package 'payload') $entry.name
        $entry.sha256=Get-Hash $path; $entry.size=(Get-Item -LiteralPath $path).Length
    }
    Write-Json (Join-Path $Fixture.Package 'package-manifest.json') $manifest
}
function New-Fixture([string]$Name) {
    $root=Join-Path $fixtureRoot $Name
    $package=Join-Path $root 'package'; $payload=Join-Path $package 'payload'
    $paths=Get-Paths (Join-Path $root 'MO2')
    foreach ($dir in @($payload,$paths.Plugins,(Split-Path -Parent $paths.BaseState))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $componentRoot 'protected-files.json') -Destination (Join-Path $package 'protected-files.json')
    Write-Text (Join-Path $paths.Plugins 'dlssnr_on_amd.asi') 'SYNTHETIC NR FIXTURE, NOT EXECUTABLE'
    # Only this dot-sourced fixture scope changes the expected hash. Production CLI has no override.
    $script:ExpectedNrHash=Get-Hash (Join-Path $paths.Plugins 'dlssnr_on_amd.asi')
    $script:PackageRoot=$package
    Write-Text (Join-Path $paths.Plugins 'dlssnr_on_amd.ini') "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`nTone=0.42`r`n"
    Write-Text (Join-Path $paths.Bin 'OptiScaler.ini') @"
[Upscalers]
Dx12Upscaler=ffx
[FrameGen]
FGInput=dlssg
FGOutput=xefg
[Inputs]
EnableDlssInputs=true
EnableFfxInputs=false
[Plugins]
LoadAsiPlugins=true
Path=plugins
[XeFG]
InterpolationCount=3
[UpscaleRatio]
UpscaleRatioOverrideEnabled=true
UpscaleRatioOverrideValue=2.0
"@
    Write-Text (Join-Path $paths.Bin 'custom-opti-proxy.dll') 'OPTI: PRESERVE ACTUAL NAME'
    Write-Text (Join-Path $paths.Bin 'libxess_fg.dll') 'INTEL: DO NOT REPLACE'
    Write-Text (Join-Path $paths.Plugins 'XeFGUnlock.asi') 'XEFG UNLOCK: DO NOT REPLACE'
    Write-Text (Join-Path $paths.Plugins 'nvngx_dlssnr.dll') 'MODEL: DO NOT REPLACE'
    Write-Text (Join-Path $paths.Plugins 'dlssnr_on_amd_weights.bin') 'WEIGHTS: DO NOT DELETE'
    Write-Json $paths.BaseState ([pscustomobject]@{Version=2;PackageVersion='1.4-FFX-input-test';PluginFolder=$paths.Plugins})
    Write-FakePe (Join-Path $payload 'MatheusNR030.asi')
    Write-Text (Join-Path $payload 'MatheusNR030.ini') "[SyntheticTestOnly]`r`nEnabled=0`r`n"
    $manifest=[pscustomobject]@{
        schema_version=1; addon_name='MatheusNR030'; addon_version='synthetic-fixture'
        base_nr_sha256=$script:ExpectedNrHash; source_commit=('a'*40); build_run_id='1234567890'
        build_verified=$true; abi_verified=$true; build_evidence='https://github.com/lunarci/b/actions/runs/1234567890'
        abi_evidence='synthetic fixture; no ABI claim'; game_runtime_verified=$false; runtime_log_schema='matheusnr030-events-v1'
        files=@([pscustomobject]@{name='MatheusNR030.asi';sha256='';size=0},[pscustomobject]@{name='MatheusNR030.ini';sha256='';size=0})
    }
    Write-Json (Join-Path $package 'package-manifest.json') $manifest
    $fixture=[pscustomobject]@{Root=$root;Package=$package;Paths=$paths}
    Update-FixtureManifest $fixture
    return $fixture
}
function Run-Case([string]$Name,[scriptblock]$Code) {
    try {
        $fixture=New-Fixture $Name
        & $Code $fixture
        $results.Add([pscustomobject]@{Test=$Name;Status='PASS'})
        Write-Host ('PASS '+$Name)
    } catch {
        $results.Add([pscustomobject]@{Test=$Name;Status='FAIL';Error=$_.Exception.Message})
        Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)
    } finally {
        $script:ExpectedNrHash=$productionHash; $script:PackageRoot=$productionPackage
    }
}

try {
    Assert-True ($productionHash -ceq 'c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de') 'Production NR hash changed.'
    Run-Case 'unverified-manifest-blocked' {
        param($f)
        $path=Join-Path $f.Package 'package-manifest.json'; $manifest=Read-Json $path
        $manifest.build_verified=$false; $manifest.abi_verified=$false; Write-Json $path $manifest
        Assert-Throws { Install-Addon $f.Paths } 'build_verified is not verified'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Unverified package changed installation.'
    }

    Run-Case 'install-repeat-remove-preserves-base' {
        param($f)
        $before=Get-ProtectedSnapshot $f.Paths
        Install-Addon $f.Paths
        Assert-True (Test-Path -LiteralPath $f.Paths.State) 'Install state missing.'
        Install-Addon $f.Paths
        Assert-SnapshotUnchanged $f.Paths $before
        $state=Read-AddonState $f.Paths
        Assert-True (-not $state.RuntimeVerified) 'Install must not claim runtime verification.'
        Remove-Addon $f.Paths
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.State)) 'State remains after remove.'
        foreach ($path in @(Get-OwnedPaths $f.Paths)) { Assert-True (-not (Test-Path -LiteralPath $path)) 'Owned payload remains.' }
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'missing-legacy-record-install-repeat-remove' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.BaseState
        $legacyFolder=Split-Path -Parent $f.Paths.BaseState
        Remove-Item -LiteralPath $legacyFolder
        $before=Get-ProtectedSnapshot $f.Paths
        Install-Addon $f.Paths
        $state=Read-AddonState $f.Paths
        Assert-True ($null -ne $state -and -not $state.OwnsBaseNr -and -not $state.RuntimeVerified) 'Add-on ownership was not recorded correctly.'
        Assert-SnapshotUnchanged $f.Paths $before
        Install-Addon $f.Paths
        Assert-SnapshotUnchanged $f.Paths $before
        Remove-Addon $f.Paths
        Assert-SnapshotUnchanged $f.Paths $before
        Assert-True (-not (Test-Path -LiteralPath $legacyFolder)) 'Legacy base record or folder was fabricated.'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.State)) 'Add-on state remains after removal.'
        foreach ($path in @(Get-OwnedPaths $f.Paths)) { Assert-True (-not (Test-Path -LiteralPath $path)) 'Owned payload remains.' }
    }
    Run-Case 'missing-legacy-record-wrong-hash-blocked' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.BaseState
        Write-Text (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi') 'DIFFERENT NR BINARY'
        $before=Get-ProtectedSnapshot $f.Paths
        Assert-Throws { Install-Addon $f.Paths } 'pinned NR 0.3.0 ASI SHA-256'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Missing metadata bypassed the pinned hash check.'
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'missing-legacy-record-wrong-settings-blocked' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.BaseState
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('InterpolationCount=3','InterpolationCount=1'))
        $before=Get-ProtectedSnapshot $f.Paths
        Assert-Throws { Install-Addon $f.Paths } 'existing XeFG 4X setting'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Missing metadata bypassed the settings check.'
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'conflicting-legacy-record-blocked' {
        param($f)
        Write-Json $f.Paths.BaseState ([pscustomobject]@{Version=2;PluginFolder=(Join-Path $f.Root 'other-plugins')})
        $before=Get-ProtectedSnapshot $f.Paths
        Assert-Throws { Install-Addon $f.Paths } 'base installation record does not match'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Conflicting metadata was ignored.'
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'missing-legacy-record-does-not-bypass-addon-ownership' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.BaseState
        $path=Join-Path $f.Paths.Plugins 'MatheusNR030.asi'
        Write-Text $path 'UNOWNED ADD-ON FILE'
        $hash=Get-Hash $path
        Assert-Throws { Install-Addon $f.Paths } 'Unowned add-on-named file'
        Assert-Throws { Remove-Addon $f.Paths } 'No add-on ownership record exists'
        Assert-True ((Get-Hash $path) -ceq $hash) 'Unowned add-on file was changed.'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Add-on ownership was fabricated.'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.BaseState)) 'Legacy ownership was fabricated.'
    }
    Run-Case 'missing-base-file-is-not-reported-as-hash-mismatch' {
        param($f)
        Remove-Item -LiteralPath (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi')
        Assert-Throws { Install-Addon $f.Paths } 'Base NR file is missing:'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Missing base file changed the installation.'
    }
    Run-Case 'current-input-rejection-is-not-reported-as-working-scale' {
        param($f)
        $log="event=session_start utc=2026-09-15T09:12:30.976Z runtime_validated=false source_commit="+('a'*40)+"`n"
        $log+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $log+="event=resolve_config version=0.2.2 colour_preservation_percent=100 depth_protection=1 effect_percent=50 applies_to_scaled_path_only=true`n"
        $log+="event=input_check reason=motion_input_unsupported motion_ffx_format=4 motion_dxgi=10`n"
        $log+="event=frame seen=1080 scaled=0 nr_recorded=0 resolved=0 fallback=1080 gpu_completed=0 allocated_bytes=0 allocated_slots=0`n"
        $a=Get-AddonSessionSummary $log '2026-09-15T09:00:00Z'
        Assert-True ($a.CompositeSettingsFound -and $a.EffectPercent -eq 50) '0.2.2 settings were not recognized.'
        Assert-True ($a.Result -ceq 'NO_NR_RESOLVE_RECORDING_OBSERVED' -and -not $a.CommandRecordingObserved -and -not $a.CompositeRecordingObserved) 'Rejected input was mistaken for a working scale/quality effect.'
    }
    Run-Case 'wrong-base-hash-no-write' {
        param($f)
        Write-Text (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi') 'DIFFERENT NR BINARY'
        Assert-Throws { Install-Addon $f.Paths } 'pinned NR 0.3.0 ASI SHA-256'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Preflight failure created install backup.'
    }
    Run-Case 'settings-not-rewritten' {
        param($f)
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EnableFfxInputs=false','EnableFfxInputs=true'))
        $hash=Get-Hash $ini
        Assert-Throws { Install-Addon $f.Paths } 'Preserved route is not confirmed'
        Assert-True ((Get-Hash $ini) -ceq $hash) 'Existing configuration was rewritten.'
    }
    Run-Case 'false-or-string-verification-blocked' {
        param($f)
        $path=Join-Path $f.Package 'package-manifest.json'; $manifest=Read-Json $path
        $manifest.abi_verified='true'; Write-Json $path $manifest
        Assert-Throws { Install-Addon $f.Paths } 'abi_verified is not verified'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Unverified ABI mutated installation.'
    }
    Run-Case 'experimental-package-cannot-claim-game-validation' {
        param($f)
        $path=Join-Path $f.Package 'package-manifest.json'; $manifest=Read-Json $path
        $manifest.game_runtime_verified=$true; Write-Json $path $manifest
        Assert-Throws { Install-Addon $f.Paths } 'game_runtime_verified=false'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Incorrect game-validation metadata allowed installation.'
    }
    Run-Case 'mismatched-build-run-evidence-blocked' {
        param($f)
        $path=Join-Path $f.Package 'package-manifest.json'; $manifest=Read-Json $path
        $manifest.build_evidence='https://github.com/lunarci/b/actions/runs/9876543210'; Write-Json $path $manifest
        Assert-Throws { Install-Addon $f.Paths } 'Build evidence does not match'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Mismatched build provenance allowed installation.'
    }
    Run-Case 'payload-hash-mismatch-no-write' {
        param($f)
        Write-Text (Join-Path $f.Package 'payload/MatheusNR030.ini') 'MODIFIED PAYLOAD'
        Assert-Throws { Install-Addon $f.Paths } 'Payload SHA-256/size mismatch'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.Backup)) 'Bad payload mutated installation.'
    }
    Run-Case 'unowned-file-protected' {
        param($f)
        $path=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'; Write-Text $path 'USER FILE'
        $hash=Get-Hash $path
        Assert-Throws { Install-Addon $f.Paths } 'Unowned add-on-named file'
        Assert-True ((Get-Hash $path) -ceq $hash) 'Unowned file was overwritten.'
    }
    Run-Case 'modified-owned-ini-backed-up-before-remove' {
        param($f)
        Install-Addon $f.Paths
        $path=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'; Write-Text $path 'USER MODIFIED CONFIG'
        $hash=Get-Hash $path; $stateHash=Get-Hash $f.Paths.State
        Assert-Throws { Install-Addon $f.Paths } 'Modified add-on file is protected'
        Assert-True ((Get-Hash $path) -ceq $hash -and (Get-Hash $f.Paths.State) -ceq $stateHash) 'Modified file/state changed.'
        Remove-Addon $f.Paths
        Assert-True (-not (Test-Path -LiteralPath $path)) 'Tuned INI remains active after removal.'
        $saved=@(Get-ChildItem -LiteralPath $f.Paths.Backup -Filter 'ARK-MatheusNR030.ini' -File -Recurse)
        Assert-True ($saved.Count -eq 1 -and (Get-Hash $saved[0].FullName) -ceq $hash) 'Tuned INI was not preserved exactly.'
    }
    Run-Case 'modified-owned-asi-blocks-all-removal' {
        param($f)
        Install-Addon $f.Paths
        $path=Join-Path $f.Paths.Plugins 'MatheusNR030.asi'; Write-Text $path 'UNRECOGNIZED EXECUTABLE'
        $hash=Get-Hash $path; $stateHash=Get-Hash $f.Paths.State
        Assert-Throws { Remove-Addon $f.Paths } 'Modified add-on file is protected'
        Assert-Throws { Install-Addon $f.Paths } 'Modified add-on file is protected'
        Assert-True ((Get-Hash $path) -ceq $hash -and (Get-Hash $f.Paths.State) -ceq $stateHash) 'Changed ASI/state was modified.'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Paths.Plugins 'MatheusNR030.ini')) 'Removal partially proceeded despite changed ASI.'
    }
    Run-Case 'partial-install-rollback' {
        param($f)
        $before=Get-ProtectedSnapshot $f.Paths
        Assert-Throws { Install-Addon $f.Paths { param($index) if ($index -eq 1) { throw 'INJECTED COPY FAILURE' } } } 'INJECTED COPY FAILURE'
        Assert-True (-not (Test-Path -LiteralPath $f.Paths.State)) 'Failed installation kept active state.'
        foreach ($path in @(Get-OwnedPaths $f.Paths)) { Assert-True (-not (Test-Path -LiteralPath $path)) 'Partial payload not rolled back.' }
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'update-rollback-restores-previous-addon' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'; $oldHash=Get-Hash $ini; $stateHash=Get-Hash $f.Paths.State
        Write-Text (Join-Path $f.Package 'payload/MatheusNR030.ini') 'UPDATED SYNTHETIC ADDON'
        Update-FixtureManifest $f
        Assert-Throws { Install-Addon $f.Paths { param($index) if ($index -eq 2) { throw 'INJECTED STATE FAILURE' } } } 'INJECTED STATE FAILURE'
        Assert-True ((Get-Hash $ini) -ceq $oldHash -and (Get-Hash $f.Paths.State) -ceq $stateHash) 'Previous add-on/state was not restored.'
    }
    Run-Case 'remove-rollback-restores-addon' {
        param($f)
        Install-Addon $f.Paths
        $asi=Join-Path $f.Paths.Plugins 'MatheusNR030.asi'; $hash=Get-Hash $asi
        Assert-Throws { Remove-Addon $f.Paths { param($index) if ($index -eq 1) { throw 'INJECTED REMOVE FAILURE' } } } 'INJECTED REMOVE FAILURE'
        Assert-True ((Get-Hash $asi) -ceq $hash -and (Test-Path -LiteralPath $f.Paths.State)) 'Failed removal did not restore add-on.'
    }
    Run-Case 'tuned-ini-remove-failure-restores-tuning' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'
        Write-Text $ini 'USER SCALE 75 CONFIG'
        $hash=Get-Hash $ini
        Assert-Throws { Remove-Addon $f.Paths { param($index) if ($index -eq 2) { throw 'INJECTED TUNED REMOVE FAILURE' } } } 'INJECTED TUNED REMOVE FAILURE'
        Assert-True ((Get-Hash $ini) -ceq $hash -and (Test-Path -LiteralPath $f.Paths.State)) 'Failed removal lost tuned settings.'
    }
    Run-Case 'foreign-path-transaction-rejected' {
        param($f)
        $before=Get-ProtectedSnapshot $f.Paths; $folder=New-BackupFolder $f.Paths 'test'
        $ops=@([pscustomobject]@{Path=(Join-Path $f.Paths.Bin 'OptiScaler.ini');Action='Delete';Source=$null})
        Assert-Throws { Invoke-OwnTransaction $f.Paths $ops $folder $before } 'unowned or duplicate destination'
        Assert-SnapshotUnchanged $f.Paths $before
    }
    Run-Case 'overwrite-owned-copy-cleanup' {
        param($f)
        Install-Addon $f.Paths
        New-Item -ItemType Directory -Path $f.Paths.OldPlugins -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $f.Paths.Plugins 'MatheusNR030.asi') -Destination (Join-Path $f.Paths.OldPlugins 'MatheusNR030.asi')
        Remove-Addon $f.Paths
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Paths.OldPlugins 'MatheusNR030.asi'))) 'Owned overwrite copy remains.'
    }
    Run-Case 'last-session-only-no-stale-success' {
        param($f)
        $text="dlssnr_amd v0.3.0 (build af5027d8) loaded into Cyberpunk2077.exe`npre-upscale mode: the network runs on the 1920x1080`nnetwork job 100 done`n"
        $text+="dlssnr_amd v0.3.0 (build af5027d8) loaded into Cyberpunk2077.exe`nframes 600 dispatches 0 submitted 0`n"
        $summary=Get-BaseSessionSummary $text
        Assert-True ($summary.Nr030 -and -not $summary.PreUpscale -and -not $summary.CompletedJob) 'Old session success leaked into latest session.'
    }
    Run-Case 'addon-new-session-recording-is-not-gameplay-proof' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=frame seen=120 scaled=110 nr_recorded=100 resolved=100 fallback=20 gpu_completed=99`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($summary.StartedAfterInstall -and $summary.CommandRecordingObserved -and $summary.GpuRetirementObserved) 'Fresh recording evidence was not recognized.'
        Assert-True (-not $summary.RuntimeValidated -and $summary.Resolved -eq 100) 'Recording became a gameplay verdict.'
    }
    Run-Case 'addon-skipped-nr-is-not-success' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=frame seen=120 scaled=100 nr_recorded=0 resolved=0 fallback=120 gpu_completed=99`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True (-not $summary.CommandRecordingObserved -and $summary.Result -eq 'NO_NR_RESOLVE_RECORDING_OBSERVED') 'Skipped NR was treated as success.'
    }
    Run-Case 'addon-old-recording-is-not-new-session-proof' {
        param($f)
        $text="event=session_start utc=2026-09-15T00:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=frame seen=120 scaled=110 nr_recorded=100 resolved=100 fallback=20 gpu_completed=99`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True (-not $summary.CommandRecordingObserved -and $summary.Result -eq 'STALE_OR_NO_INSTALL_TIME') 'Old log was accepted as post-install evidence.'
        $text+="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True (-not $summary.HookActive -and -not $summary.CommandRecordingObserved) 'Previous-session hook leaked into final session.'
    }
    Run-Case 'addon-recording-without-retirement-remains-distinct' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=75`n"
        $text+="event=frame seen=1 scaled=1 nr_recorded=1 resolved=1 fallback=0 gpu_completed=0`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($summary.CommandRecordingObserved -and -not $summary.GpuRetirementObserved) 'GPU completion was inferred from recording.'
    }
    Run-Case 'addon-invalid-counters-are-unverified' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=frame seen=1 scaled=1 nr_recorded=0 resolved=1 fallback=0 gpu_completed=0`n"
        $summary=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True (-not $summary.StatsFound -and -not $summary.CommandRecordingObserved) 'Inconsistent counters were accepted.'
    }

    Run-Case 'production-log-fields-and-combined-settings-are-recognized' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false source_commit=ecc7b4d6ef7fcef9c73a1b033d3ff9b15b58e192`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=resolve_config version=0.2.0 colour_preservation_percent=100 depth_protection=1 effect_percent=100 applies_to_scaled_path_only=true`n"
        $text+="event=adapter_ready input_width=1920 input_height=1080 nr_width=1632 nr_height=918`n"
        $text+="event=frame seen=120 scaled=110 nr_recorded=100 resolved=100 fallback=20 gpu_completed=99 allocated_bytes=64000000 allocated_slots=3`n"
        $s=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($s.CommandRecordingObserved -and $s.CompositeRecordingObserved -and $s.GpuRetirementObserved) 'Production log fields were not parsed.'
        Assert-True ($s.ColourPreservationPercent -eq 100 -and $s.DepthProtection -and $s.NrWidth -eq 1632 -and $s.NrHeight -eq 918) 'Combined settings or extents missing.'
        Assert-True (-not $s.RuntimeValidated) 'Composite recording was treated as image proof.'
        $text+="event=session_start utc=2026-09-15T03:00:00Z runtime_validated=false source_commit=ecc7b4d6ef7fcef9c73a1b033d3ff9b15b58e192`n"
        $s=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True (-not $s.CompositeSettingsFound -and -not $s.CommandRecordingObserved) 'Old combined settings leaked into the latest session.'
    }
    Run-Case 'combined-config-without-work-is-not-effect-evidence' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false source_commit=ecc7b4d6ef7fcef9c73a1b033d3ff9b15b58e192`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=resolve_config version=0.2.0 colour_preservation_percent=100 depth_protection=1 effect_percent=100 applies_to_scaled_path_only=true`n"
        $s=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($s.CompositeSettingsFound -and -not $s.CompositeRecordingObserved) 'INI values became effect evidence.'
        $text=$text.Replace('scale_percent=85','scale_percent=100')
        $s=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($s.Result -eq 'BASELINE_100_PERCENT' -and -not $s.CompositeRecordingObserved) '100 percent bypass was treated as combined processing.'
    }
    Run-Case 'zero-effect-setting-does-not-claim-composite-effect' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=resolve_config version=0.2.0 colour_preservation_percent=100 depth_protection=1 effect_percent=0 applies_to_scaled_path_only=true`n"
        $text+="event=frame seen=120 scaled=110 nr_recorded=100 resolved=100 fallback=20 gpu_completed=99 allocated_bytes=64000000 allocated_slots=3`n"
        $s=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($s.CommandRecordingObserved -and -not $s.CompositeRecordingObserved) 'Zero effect was treated as an enabled composite effect.'
    }

    Run-Case 'pool-samples-report-budget-and-retirement-without-fps-claim' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $sample='event=pool_sample tick_ms=3000 seen=120 scaled=110 resolved=100 fallback=20 allocated_bytes=80 allocated_slots=4 retained_uses=2 retired_uses=100 released_borrowed_refs=800 trimmed_slots=1 trimmed_bytes=20 local_valid=1 local_usage_bytes=90 local_budget_bytes=100 nonlocal_valid=1 nonlocal_usage_bytes=5 ffx_frame_time_ms=16.6 ffx_reset=0 reset_dispatches=1 addon_failed=0 last_fallback_ever=none'
        $text+=$sample+"`n"+$sample.Replace('local_usage_bytes=90','local_usage_bytes=110').Replace('allocated_bytes=80','allocated_bytes=40')+"`n"
        $s=Get-PoolSessionSummary $text
        Assert-True ($s.Samples -eq 2 -and $s.LocalSamples -eq 2 -and $s.OverBudgetSamples -eq 1) 'Budget samples incorrectly classified.'
        Assert-True ($s.PeakLocalUsageBytes -eq 110 -and $s.PeakAddonBytes -eq 80 -and $s.Latest.allocated_bytes -eq 40) 'Pool high-water/recovery evidence missing.'
        $text+="event=session_start utc=2026-09-15T03:00:00Z runtime_validated=false`n"
        Assert-True ((Get-PoolSessionSummary $text).Samples -eq 0) 'Previous pool samples leaked into latest session.'
    }
    Run-Case 'pool-unavailable-budget-and-new-version-remain-observations' {
        param($f)
        $text="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $text+="event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`n"
        $text+="event=resolve_config version=0.2.3 colour_preservation_percent=100 depth_protection=1 effect_percent=100 applies_to_scaled_path_only=true`n"
        $text+="event=pool_sample tick_ms=3000 allocated_bytes=80 allocated_slots=4 retained_uses=2 retired_uses=100 released_borrowed_refs=800 trimmed_slots=1 trimmed_bytes=20 local_valid=0 local_usage_bytes=110 local_budget_bytes=0 nonlocal_valid=0 nonlocal_usage_bytes=0 ffx_frame_time_ms=16.6 ffx_reset=0 addon_failed=0 last_fallback_ever=none`n"
        $s=Get-PoolSessionSummary $text
        Assert-True ($s.Samples -eq 1 -and $s.LocalSamples -eq 0 -and $s.OverBudgetSamples -eq 0) 'Unavailable budget treated as real usage evidence.'
        $a=Get-AddonSessionSummary $text '2026-09-15T01:00:00Z'
        Assert-True ($a.CompositeSettingsFound -and -not $a.RuntimeValidated -and -not $a.CommandRecordingObserved) '0.2.3 settings were rejected or treated as gameplay proof.'
    }

    Run-Case 'luma-stability-config-is-observed-not-visual-proof' {
        param($f)
        $header="event=session_start utc=2026-09-15T02:00:00Z runtime_validated=false`n"
        $config="event=resolve_config version=0.2.4 colour_preservation_percent=100 depth_protection=1 effect_percent=50 applies_to_scaled_path_only=true`n"
        foreach ($strength in @(0,65,100)) {
            $line="event=luma_stability_config version=0.2.4 strength_percent=$strength applies_to_scaled_path_only=true temporal_filter=0`n"
            $a=Get-AddonSessionSummary ($header+$config+$line) '2026-09-15T01:00:00Z'
            Assert-True ($a.CompositeSettingsFound -and $a.LumaStabilitySettingsFound -and $a.LumaStabilityPercent -eq $strength) 'Stability setting was not parsed.'
            Assert-True (-not $a.RuntimeValidated -and -not $a.CommandRecordingObserved) 'Settings were misreported as game execution.'
        }
        $bad="event=luma_stability_config version=0.2.4 strength_percent=101 applies_to_scaled_path_only=true temporal_filter=0`n"
        $a=Get-AddonSessionSummary ($header+$config+$bad) '2026-09-15T01:00:00Z'
        Assert-True (-not $a.LumaStabilitySettingsFound -and $null -eq $a.LumaStabilityPercent) 'Out-of-range setting accepted.'
        $a=Get-AddonSessionSummary ($header+$config+$line+$header+$config) '2026-09-15T01:00:00Z'
        Assert-True (-not $a.LumaStabilitySettingsFound) 'Stale session stability setting was reused.'
    }
    $failed=@($results | Where-Object { $_.Status -eq 'FAIL' })
    $edition=$(if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { 'Desktop' })
    $windows51=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and $edition -eq 'Desktop')
    $summary=[pscustomobject]@{
        Scope='Synthetic file-management fixtures only; no game/ABI/runtime verification'
        PowerShellVersion=$PSVersionTable.PSVersion.ToString();PowerShellEdition=$edition
        OperatingSystem=[Environment]::OSVersion.VersionString;WindowsPowerShell51=$windows51
        Passed=(@($results | Where-Object {$_.Status -eq 'PASS'}).Count);Failed=$failed.Count;Tests=@($results.ToArray())
    }
    $json=$summary | ConvertTo-Json -Depth 6
    $evidenceFolder=Join-Path $componentRoot 'test-results'
    New-Item -ItemType Directory -Path $evidenceFolder -Force | Out-Null
    Write-Text (Join-Path $evidenceFolder 'installer-tests.json') $json
    $json
    if ($failed.Count) { exit 1 }
    exit 0
} finally {
    $script:ExpectedNrHash=$productionHash; $script:PackageRoot=$productionPackage
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
