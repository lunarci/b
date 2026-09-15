#requires -Version 5.1
[CmdletBinding()]
param([string]$EvidenceZip='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Setup.ps1') -Action Check
$results=New-Object 'System.Collections.Generic.List[object]'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('NR030-SessionEvidence-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
function Assert-Evidence([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Test-EvidenceCase([string]$Name,[scriptblock]$Run) {
    try { & $Run; $results.Add([pscustomobject]@{Name=$Name;Status='PASS';Message=''}) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Message=$_.Exception.Message}) }
}
$source='a'*40
$header="event=session_start utc=2026-09-15T14:56:13.511Z runtime_validated=false source_commit=$source`n"
$log=$header+@'
event=hook_active static_abi_verified=true runtime_validated=false scale_percent=85
event=resolve_config version=0.2.4 colour_preservation_percent=100 depth_protection=1 effect_percent=0 applies_to_scaled_path_only=true
event=effect_zero_handoff diagnostic_build=true mode=original_color_passthrough nr_execution_unchanged=true applies_to_scaled_path_only=true visual_verified=false
event=adapter_ready input_width=1920 input_height=1080 nr_width=1632 nr_height=918
event=frame seen=6840 scaled=6840 nr_recorded=6840 resolved=0 fallback=0 gpu_completed=0 allocated_bytes=215613440 allocated_slots=5
event=original_color_stats passthrough=6840 seen=6840 nr_recorded=6840
'@
$installed='2026-09-15T14:55:00Z'
try {
    Test-EvidenceCase 'original-colour-recording-is-not-gpu-or-visual-proof' {
        $s=Get-AddonSessionSummary $log $installed $source
        Assert-Evidence ($s.Result -ceq 'ORIGINAL_COLOR_PASSTHROUGH_RECORDING_OBSERVED' -and $s.OriginalColourPassthrough -eq 6840 -and $s.SourceMatchesInstalled) 'Original colour diagnostic was misclassified.'
        Assert-Evidence ($s.CommandRecordingObserved -and -not $s.CompositeRecordingObserved -and -not $s.GpuRetirementObserved -and -not $s.RuntimeValidated) 'Recording was promoted to GPU, composite or image verification.'
    }
    Test-EvidenceCase 'source-mismatch-and-missing-source-do-not-pass' {
        foreach ($text in @($log,$log.Replace(" source_commit=$source",''))) {
            $s=Get-AddonSessionSummary $text $installed ('b'*40)
            Assert-Evidence ($s.Result -ceq 'SOURCE_COMMIT_NOT_CONFIRMED' -and -not $s.CommandRecordingObserved) 'Wrong or absent source was accepted as current installed build.'
        }
    }
    Test-EvidenceCase 'stale-session-does-not-pass' {
        $s=Get-AddonSessionSummary $log '2026-09-15T15:00:00Z' $source
        Assert-Evidence ($s.Result -ceq 'STALE_OR_NO_INSTALL_TIME' -and -not $s.CommandRecordingObserved) 'Previous-install session was accepted.'
    }
    Test-EvidenceCase 'latest-empty-or-malformed-session-blocks-old-recording' {
        foreach ($tail in @($header,'event=session_start incomplete=true')) {
            $s=Get-AddonSessionSummary ($log+"`n"+$tail) $installed $source
            Assert-Evidence (-not $s.CommandRecordingObserved -and -not $s.OriginalColourRecordingObserved) 'Previous session recording leaked into the final session.'
        }
    }
    Test-EvidenceCase 'mode-config-and-counter-evidence-are-all-required' {
        foreach ($text in @(
            $log.Replace('mode=original_color_passthrough','mode=positive_effect_resolve_unchanged'),
            $log.Replace('effect_percent=0','effect_percent=50'),
            $log.Replace('event=original_color_stats','event=ignored_stats'))) {
            $s=Get-AddonSessionSummary $text $installed $source
            Assert-Evidence (-not $s.OriginalColourRecordingObserved -and -not $s.CommandRecordingObserved) 'An incomplete original-colour record was accepted.'
        }
    }
    Test-EvidenceCase 'mismatched-truncated-and-overflow-counters-do-not-pass' {
        foreach ($text in @(
            $log.Replace('passthrough=6840','passthrough=6841'),
            $log.Replace('passthrough=6840 seen=6840','passthrough=6800 seen=6800'),
            $log.Replace('passthrough=6840','passthrough=999999999999999999999999'),
            ($log+"`nevent=frame seen=6900 scaled=6900 nr_recorded=6900 resolved=0 fallback=0 gpu_completed=0`n"))) {
            $s=Get-AddonSessionSummary $text $installed $source
            Assert-Evidence (-not $s.OriginalColourRecordingObserved) 'Inconsistent or incomplete latest counters were accepted.'
        }
    }
    Test-EvidenceCase 'ordinary-positive-effect-recording-still-works' {
        $text=$log.Replace('mode=original_color_passthrough','mode=positive_effect_resolve_unchanged').Replace('effect_percent=0','effect_percent=50').Replace('resolved=0','resolved=6840').Replace('gpu_completed=0','gpu_completed=6835')
        $s=Get-AddonSessionSummary $text $installed $source
        Assert-Evidence ($s.Result -ceq 'NR_RESOLVE_COMMAND_RECORDING_OBSERVED' -and $s.CompositeRecordingObserved -and $s.GpuRetirementObserved -and -not $s.RuntimeValidated) 'Existing resolve semantics regressed.'
    }
    $predication="`nevent=predication_mode admission=observed_disabled_only active_or_unknown=skip_nr preserve_before_ffx=true scale100_covered=false`n"
    $predication+="event=predication_stats admitted=6840 bypass_unknown=1 bypass_active=0 bypass_untracked=0 observed_sets=8000 observed_resets=12000 observed_clears=100 private_sets=14000 private_restores=6840 tracked_lists=5 capacity_bypass=0`n"
    Test-EvidenceCase 'no-active-predicate-is-not-evidence-of-artifact-cause' {
        $s=Get-AddonSessionSummary ($log+$predication) $installed $source
        Assert-Evidence ($s.PredicationAssessment -ceq 'NO_ACTIVE_CALLER_PREDICATION_OBSERVED' -and $s.PredicationStats.Admitted -eq 6840 -and $s.PredicationStats.BypassUnknown -eq 1 -and -not $s.RuntimeValidated) 'Known-disabled observations were treated as evidence of the artifact cause.'
    }
    Test-EvidenceCase 'active-predicate-bypass-is-observation-not-fix-proof' {
        $s=Get-AddonSessionSummary ($log+$predication.Replace('bypass_active=0','bypass_active=7')) $installed $source
        Assert-Evidence ($s.PredicationAssessment -ceq 'ACTIVE_CALLER_NR_BYPASS_OBSERVED' -and $s.PredicationStats.BypassActive -eq 7 -and -not $s.RuntimeValidated) 'Active predicate bypass was missing or became visual verification.'
    }
    Test-EvidenceCase 'predication-evidence-requires-current-mode-source-and-valid-counters' {
        foreach ($text in @(
            $log+$predication.Replace('admission=observed_disabled_only','admission=unrecognized'),
            $log+$predication.Replace('admitted=6840','admitted=9999999999999999999999999999'),
            $log+$predication.Replace('tracked_lists=5','tracked_lists=65'),
            $log+$predication+"`n"+$header)) {
            $s=Get-AddonSessionSummary $text $installed $source
            Assert-Evidence ($s.PredicationAssessment -ceq 'NOT_CONFIRMED') 'Incomplete or previous predication evidence was accepted.'
        }
        $s=Get-AddonSessionSummary ($log+$predication) $installed ('b'*40)
        Assert-Evidence ($s.PredicationAssessment -ceq 'NOT_CONFIRMED') 'Wrong-source predication was accepted.'
    }
    Test-EvidenceCase 'check-allows-preserved-four-five-times-without-relaxing-installer' {
        $checkPaths=Get-Paths (Join-Path $fixture 'BaseCheck')
        New-Item -ItemType Directory -Path $checkPaths.Plugins -Force | Out-Null
        $nr=Join-Path $checkPaths.Plugins 'dlssnr_on_amd.asi'
        Write-Text $nr 'Synthetic base NR fixture; not executable.'
        Write-Text (Join-Path $checkPaths.Plugins 'dlssnr_on_amd.ini') "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`n"
        $opti="[Upscalers]`r`nDx12Upscaler=ffx`r`n[FrameGen]`r`nFGInput=dlssg`r`nFGOutput=xefg`r`n[Inputs]`r`nEnableFfxInputs=false`r`n[Plugins]`r`nLoadAsiPlugins=true`r`n[XeFG]`r`nInterpolationCount="
        $originalHash=$script:ExpectedNrHash
        try {
            $script:ExpectedNrHash=Get-Hash $nr
            foreach ($count in @('3','4')) {
                $ini=Join-Path $checkPaths.Bin 'OptiScaler.ini';Write-Text $ini ($opti+$count+"`r`n")
                $before=Get-ProtectedSnapshot $checkPaths
                $report=Check-Addon $checkPaths 6>$null
                Assert-Evidence ($report -match 'Base NR hash and preserved settings: PASS') 'Read-only base checker rejected a preserved 4X/5X setting.'
                Assert-SnapshotUnchanged $checkPaths $before
                $rejected=$false
                try { $null=Assert-Base $checkPaths } catch { $rejected=$true }
                Assert-Evidence ($rejected -eq ($count -ceq '4')) 'Legacy installer count requirement changed.'
            }
        } finally { $script:ExpectedNrHash=$originalHash }
    }
    $paths=Get-Paths (Join-Path $fixture 'MO2')
    New-Item -ItemType Directory -Path $paths.Bin -Force | Out-Null
    $optiLog=Join-Path $paths.Bin 'OptiScaler.log'
    $configured=Join-Path $paths.Root 'OptiScaler-debug.log'
    Write-Text (Join-Path $paths.Bin 'OptiScaler.ini') ("[Log]`r`nLogFileName="+$configured+"`r`n[XeFG]`r`nInterpolationCount=4`r`n")
    Write-Text $optiLog 'Old OptiScaler session; timestamp is deliberately stale.'
    (Get-Item -LiteralPath $optiLog).LastWriteTimeUtc=[DateTime]::Parse('2026-09-13T12:16:44Z').ToUniversalTime()
    $hashes=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.Root -Recurse -File)) { $hashes[$file.FullName]=Get-Hash $file.FullName }
    Test-EvidenceCase 'old-default-and-missing-configured-log-are-explicit' {
        $s=@(Get-OptiLogFreshness $paths '2026-09-15T14:56:13.511Z')
        Assert-Evidence (@($s | Where-Object {$_.Side -eq 'ark' -and $_.Kind -eq 'default' -and $_.Result -eq 'STALE_BEFORE_ADDON_SESSION'}).Count -eq 1) 'Old default log was not classified as stale.'
        Assert-Evidence (@($s | Where-Object {$_.Side -eq 'ark' -and $_.Kind -eq 'configured' -and $_.Result -eq 'CONFIGURED_LOG_MISSING'}).Count -eq 1) 'Missing configured log was hidden.'
    }
    Test-EvidenceCase 'timestamp-compatibility-does-not-prove-runtime' {
        $s=@(Get-OptiLogFreshness $paths '2026-09-12T00:00:00Z')
        Assert-Evidence (@($s | Where-Object {$_.Kind -eq 'default' -and $_.Result -eq 'TIMESTAMP_COMPATIBLE_ONLY'}).Count -eq 1) 'Compatible timestamp was not recognized.'
        Assert-Evidence (@($s | Where-Object {$_.RuntimeValidated}).Count -eq 0) 'Timestamp was promoted to runtime verification.'
    }
    Test-EvidenceCase 'missing-session-time-cannot-classify-log-as-current' {
        $s=@(Get-OptiLogFreshness $paths '')
        Assert-Evidence (@($s | Where-Object {$_.Kind -eq 'default' -and $_.Result -eq 'NO_SESSION_TIME_FOR_COMPARISON'}).Count -eq 1) 'Missing session time was accepted as current.'
    }
    Test-EvidenceCase 'all-file-hashes-preserved-by-read-only-checks' {
        $files=@(Get-ChildItem -LiteralPath $paths.Root -Recurse -File)
        Assert-Evidence ($files.Count -eq $hashes.Count) 'Read-only checker created or removed a game-tree file.'
        foreach ($file in $files) { Assert-Evidence ((Get-Hash $file.FullName) -ceq $hashes[$file.FullName]) 'Read-only checker changed a file.' }
    }
    if ($EvidenceZip) {
        Test-EvidenceCase 'provided-private-evidence-current-session-regression' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip=[IO.Compression.ZipFile]::OpenRead($EvidenceZip)
            try {
                $reader=New-Object IO.StreamReader(($zip.GetEntry('overwrite/MatheusNR030.log')).Open())
                try { $actual=$reader.ReadToEnd() } finally { $reader.Dispose() }
                $s=Get-AddonSessionSummary $actual $installed 'a2cd9c849b4d07ea9671b0a5f03ebb3f7aa6995b'
                Assert-Evidence ($s.Result -ceq 'ORIGINAL_COLOR_PASSTHROUGH_RECORDING_OBSERVED' -and $s.OriginalColourPassthrough -eq 6840 -and $s.NrRecorded -eq 6840 -and $s.Resolved -eq 0) 'Provided evidence was misclassified.'
                Assert-Evidence (-not $s.RuntimeValidated -and -not $s.GpuRetirementObserved) 'Provided evidence was incorrectly marked GPU/visual verified.'
            } finally { $zip.Dispose() }
        }
    }
    $failed=@($results | Where-Object {$_.Status -eq 'FAIL'})
    $summary=[pscustomobject]@{
        Scope='Read-only session parsing and file-timestamp classification; no game/GPU/visual verification'
        WindowsPowerShell51=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        PowerShellVersion=$PSVersionTable.PSVersion.ToString();Passed=(@($results | Where-Object {$_.Status -eq 'PASS'}).Count)
        Failed=$failed.Count;Tests=@($results.ToArray())
    }
    $folder=Join-Path $PSScriptRoot 'test-results'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $json=$summary | ConvertTo-Json -Depth 5
    Write-Text (Join-Path $folder 'session-evidence-tests.json') $json
    $json
    if ($failed.Count) { exit 1 }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
