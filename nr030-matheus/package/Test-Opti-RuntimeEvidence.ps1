#requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Collect-Opti-RuntimeEvidence.ps1') -Action Collect
$testScriptRoot=$PSScriptRoot
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiRuntimeEvidenceTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$cases=New-Object 'System.Collections.Generic.List[object]'
$originalCollect=${function:Collect-MotionEvidence};$originalCopy=${function:Copy-Verified}
$originalCheck=${function:Check-Complete}
$script:RuntimeTestProcess=$false
function Get-Process { param([string[]]$Name,[object]$ErrorAction) if ($script:RuntimeTestProcess) { [pscustomobject]@{ProcessName='Cyberpunk2077'} } }
function Invoke-WebRequest { throw 'Unexpected network call from evidence collector.' }
function Invoke-RestMethod { throw 'Unexpected network call from evidence collector.' }
function Assert-RuntimeTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-RuntimeThrows([scriptblock]$Code,[string]$Pattern) {
    $errorRecord=$null;try { & $Code | Out-Null } catch { $errorRecord=$_ }
    Assert-RuntimeTest ($null -ne $errorRecord) ('Expected failure: '+$Pattern)
    Assert-RuntimeTest ($errorRecord.Exception.Message -match $Pattern) ('Unexpected failure: '+$errorRecord.Exception.Message)
}
function New-RuntimeFixture([string]$Name) {
    $root=Join-Path $fixtureRoot $Name;$paths=Get-Paths (Join-Path $root 'MO2')
    $script:PackageRoot=Join-Path $root 'package'
    foreach ($folder in @($script:PackageRoot,$paths.Plugins,$paths.OldPlugins)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $configured=Join-Path $paths.Root 'OptiScaler-current.log'
    foreach ($bin in @($paths.Bin,$paths.OldBin)) {
        Write-Text (Join-Path $bin 'OptiScaler.ini') ("[Log]`r`nLogToFile=true`r`nLogLevel=1`r`nSingleFile=auto`r`nLogFileName="+$configured+"`r`n[UpscaleRatio]`r`nUpscaleRatioOverrideEnabled=true`r`nUpscaleRatioOverrideValue=2.000000`r`n[QualityOverrides]`r`nQualityRatioOverrideEnabled=auto`r`n[XeFG]`r`nInterpolationCount=4`r`n[FrameGen]`r`nEnabled=true`r`n")
        Write-Text (Join-Path $bin 'dxgi.dll') ('Exact diagnostic fixture bytes '+$bin)
        Write-Text (Join-Path $bin 'libxess_fg.dll') 'MUST NOT COPY FRAMEGEN DLL'
        Write-Text (Join-Path $bin 'OptiScaler.log') 'Deliberately stale default OptiScaler log'
        (Get-Item -LiteralPath (Join-Path $bin 'OptiScaler.log')).LastWriteTimeUtc=[DateTime]::Parse('2026-09-13T12:00:00Z').ToUniversalTime()
    }
    foreach ($plugins in @($paths.Plugins,$paths.OldPlugins)) {
        Write-Text (Join-Path $plugins 'MatheusNR030.ini') "[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nEffectPercent=0`r`n"
        Write-Text (Join-Path $plugins 'dlssnr_on_amd.ini') "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`n"
        Write-Text (Join-Path $plugins 'nvngx_dlssnr.dll') 'MUST NOT COPY MODEL DLL'
        Write-Text (Join-Path $plugins 'dlssnr_on_amd_weights.bin') 'MUST NOT COPY WEIGHTS'
        Write-Text (Join-Path $plugins 'dlssnr_on_amd.log') 'NR log evidence fixture'
    }
    $session="event=session_start utc=2026-09-15T15:52:23.242Z runtime_validated=false source_commit="+('a'*40)+"`r`nevent=hook_active static_abi_verified=true runtime_validated=false scale_percent=85`r`nevent=frame seen=120 scaled=120 nr_recorded=120 resolved=0 fallback=0 gpu_completed=0`r`n"
    Write-Text (Join-Path $paths.OldPlugins 'MatheusNR030.log') $session
    Write-Text $configured '[15:53:00.123] [D] XeFG SDK and OptiScaler current diagnostic fixture'
    (Get-Item -LiteralPath $configured).LastWriteTimeUtc=[DateTime]::Parse('2026-09-15T15:56:00Z').ToUniversalTime()
    return [pscustomobject]@{Root=$root;Paths=$paths;Configured=$configured}
}
function Get-RuntimeGameHashes($Paths) {
    $hashes=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Paths.Root -File -Recurse)) { $hashes[$file.FullName]=Get-Hash $file.FullName }
    return $hashes
}
function Assert-RuntimeGameHashes($Paths,$Before) {
    $after=Get-RuntimeGameHashes $Paths
    Assert-RuntimeTest ($after.Count -eq $Before.Count) 'Game file inventory changed.'
    foreach ($path in $Before.Keys) { Assert-RuntimeTest ($after[$path] -ceq $Before[$path]) ('Game file changed: '+$path) }
}
function Read-RuntimeManifest([string]$Zip) {
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try { return ((Read-RuntimeZipText $archive 'RUNTIME_EVIDENCE.json') | ConvertFrom-Json) }
    finally { $archive.Dispose() }
}
function Run-RuntimeCase([string]$Name,[scriptblock]$Code) {
    try {
        Set-Item Function:Check-Complete -Value { param($Paths) 'Synthetic check text; installation is intentionally not validated by this collector test.' }
        $f=New-RuntimeFixture $Name;& $Code $f
        $cases.Add([pscustomobject]@{Name=$Name;Status='PASS';Error=$null});Write-Host ('PASS '+$Name)
    } catch { $cases.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage;ScriptStackTrace=$_.ScriptStackTrace});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message+'; '+$_.InvocationInfo.PositionMessage) }
    finally {
        $script:RuntimeTestProcess=$false
        Set-Item Function:Collect-MotionEvidence -Value $originalCollect
        Set-Item Function:Copy-Verified -Value $originalCopy
        Set-Item Function:Check-Complete -Value $originalCheck
    }
}
try {
    Run-RuntimeCase 'exact-two-loader-copies-full-logs-and-five-times-settings-preserved' {
        param($f)
        $before=Get-RuntimeGameHashes $f.Paths
        $zip=Collect-OptiRuntimeEvidence $f.Paths 6>$null
        Assert-RuntimeTest ((Split-Path -Leaf $zip) -like 'MOTION_RUNTIME_EVIDENCE-*.zip') 'Runtime evidence name is ambiguous.'
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $parsedInventory=(Read-RuntimeZipText $archive 'inventory.json') | ConvertFrom-Json
            $inventory=@($parsedInventory)
            Assert-RuntimeTest ($inventory.Count -gt 2 -and $inventory[0] -isnot [array]) 'JSON inventory was deserialized as nested arrays.'
            Assert-RuntimeZipInventory $archive $inventory
            $dlls=@($archive.Entries | Where-Object { $_.FullName -like '*.dll' })
            Assert-RuntimeTest ($dlls.Count -eq 2 -and $null -ne $archive.GetEntry('ark/dxgi.dll') -and $null -ne $archive.GetEntry('overwrite/dxgi.dll')) 'Unrequested DLL or missing exact loader copy.'
            Assert-RuntimeTest (@($archive.Entries | Where-Object { $_.FullName -like '*.bin' }).Count -eq 0) 'NR model weights were included.'
            Assert-RuntimeTest ($null -ne $archive.GetEntry('configured-ark/OptiScaler-configured.log')) 'Configured current Opti log missing.'
            Assert-RuntimeTest ((Read-RuntimeZipText $archive 'ark/OptiScaler.ini').Contains('InterpolationCount=4')) 'User 5X config not preserved in evidence.'
        } finally { $archive.Dispose() }
        Assert-RuntimeGameHashes $f.Paths $before
        $m=Read-RuntimeManifest $zip
        Assert-RuntimeTest (@($m.Binaries | Where-Object { $_.Status -ceq 'COPIED_AND_HASH_VERIFIED' -and -not $_.MatchesExpected }).Count -eq 2) 'Actual differing hashes were rejected or misreported.'
        Assert-RuntimeTest (-not $m.GraphicsFixVerified -and -not $m.GameFilesChanged) 'Collector claimed graphics validation or mutation.'
    }
    Run-RuntimeCase 'missing-both-loaders-is-explicit-without-blocking-logs' {
        param($f)
        foreach ($bin in @($f.Paths.Bin,$f.Paths.OldBin)) { Remove-Item -LiteralPath (Join-Path $bin 'dxgi.dll') }
        $zip=Collect-OptiRuntimeEvidence $f.Paths 6>$null;$m=Read-RuntimeManifest $zip
        Assert-RuntimeTest (@($m.Binaries | Where-Object { $_.Status -ceq 'MISSING' }).Count -eq 2) 'Missing loader evidence was hidden.'
    }
    Run-RuntimeCase 'fresh-timestamp-and-stale-default-do-not-prove-runtime' {
        param($f)
        $zip=Collect-OptiRuntimeEvidence $f.Paths 6>$null;$m=Read-RuntimeManifest $zip
        Assert-RuntimeTest (@($m.Observations.OptiLogs | Where-Object { $_.Result -ceq 'TIMESTAMP_COMPATIBLE_ONLY' }).Count -eq 2) 'Newer configured logs not recognized.'
        Assert-RuntimeTest (@($m.Observations.OptiLogs | Where-Object { $_.Result -ceq 'STALE_BEFORE_ADDON_SESSION' }).Count -eq 2) 'Old default logs presented as current.'
        Assert-RuntimeTest (-not $m.Observations.TimestampComparisonProvesRuntime -and @($m.Observations.OptiLogs | Where-Object { $_.RuntimeValidated }).Count -eq 0) 'Timestamp comparison promoted to runtime proof.'
        Assert-RuntimeTest ($m.Observations.AddonSessions[0].NrRecorded -eq 120) 'Latest actual add-on counters missing.'
    }
    Run-RuntimeCase 'disabled-logging-and-missing-configured-file-produce-warnings' {
        param($f)
        Remove-Item -LiteralPath $f.Configured
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('LogToFile=true','LogToFile=auto'))
        $zip=Collect-OptiRuntimeEvidence $f.Paths 6>$null;$m=Read-RuntimeManifest $zip
        Assert-RuntimeTest (@($m.Observations.Warnings | Where-Object { $_ -like 'OPTISCALER_FILE_LOGGING_NOT_EXPLICITLY_ENABLED ark*' }).Count -eq 1) 'auto=off logging was hidden.'
        Assert-RuntimeTest (@($m.Observations.OptiLogs | Where-Object { $_.Entry -like 'configured-*' -and $_.Result -ceq 'NOT_COLLECTED_OR_MISSING' }).Count -eq 2) 'Missing configured logs were not explicit.'
    }
    Run-RuntimeCase 'malformed-latest-session-cannot-expose-old-session-success' {
        param($f)
        [IO.File]::AppendAllText((Join-Path $f.Paths.OldPlugins 'MatheusNR030.log'),"`r`nevent=session_start incomplete=true`r`n")
        $zip=Collect-OptiRuntimeEvidence $f.Paths 6>$null;$m=Read-RuntimeManifest $zip
        Assert-RuntimeTest ($null -eq $m.Observations.ComparedAddonSessionUtc -and -not $m.Observations.AddonSessions[0].ValidLatestHeader) 'Earlier session leaked across malformed latest header.'
        Assert-RuntimeTest (@($m.Observations.OptiLogs | Where-Object { $_.Result -ceq 'TIMESTAMP_COMPATIBLE_ONLY' }).Count -eq 0) 'Malformed latest session still validated log freshness.'
    }
    Run-RuntimeCase 'loader-concurrent-edit-prevents-final-archive-keeps-base-evidence' {
        param($f)
        $script:RuntimeRaceSource=Join-Path $f.Paths.Bin 'dxgi.dll'
        Set-Item Function:Collect-MotionEvidence -Value {
            param($Paths)
            $zip=& $originalCollect $Paths
            [IO.File]::AppendAllText($script:RuntimeRaceSource,'concurrent loader edit')
            return $zip
        }
        Assert-RuntimeThrows { Collect-OptiRuntimeEvidence $f.Paths 6>$null } 'Evidence source changed during collection'
        $results=Join-Path $script:PackageRoot 'Results'
        Assert-RuntimeTest (@(Get-ChildItem -LiteralPath $results -File -Filter 'MOTION_RUNTIME_EVIDENCE-*.zip').Count -eq 0) 'Conflicting loader evidence presented as complete.'
        Assert-RuntimeTest (@(Get-ChildItem -LiteralPath $results -File -Filter 'MOTION_EVIDENCE-*.zip').Count -eq 1) 'Original log evidence was destroyed after extension failure.'
    }
    Run-RuntimeCase 'copy-corruption-cannot-produce-complete-runtime-zip' {
        param($f)
        Set-Item Function:Copy-Verified -Value {
            param($Source,$Destination)
            & $originalCopy $Source $Destination
            if ($Source -like '*dxgi.dll') { [IO.File]::AppendAllText($Destination,'injected copy corruption') }
        }
        Assert-RuntimeThrows { Collect-OptiRuntimeEvidence $f.Paths 6>$null } 'Copied dxgi.dll changed during collection'
        Assert-RuntimeTest (@(Get-ChildItem -LiteralPath (Join-Path $script:PackageRoot 'Results') -File -Filter 'MOTION_RUNTIME_EVIDENCE-*.zip').Count -eq 0) 'Corrupt DLL copy presented as complete.'
    }
    Run-RuntimeCase 'game-running-is-rejected-before-output-or-game-writes' {
        param($f)
        $before=Get-RuntimeGameHashes $f.Paths;$script:RuntimeTestProcess=$true
        Assert-RuntimeThrows { Collect-OptiRuntimeEvidence $f.Paths 6>$null } 'Close Cyberpunk'
        Assert-RuntimeTest (-not (Test-Path -LiteralPath (Join-Path $script:PackageRoot 'Results'))) 'Running-game rejection created output.'
        Assert-RuntimeGameHashes $f.Paths $before
    }
    Run-RuntimeCase 'oversize-loader-is-rejected-before-copy' {
        param($f)
        $file=[IO.File]::Open((Join-Path $f.Paths.Bin 'dxgi.dll'),[IO.FileMode]::Open,[IO.FileAccess]::Write)
        try { $file.SetLength(128MB+1) } finally { $file.Dispose() }
        Assert-RuntimeThrows { Collect-OptiRuntimeEvidence $f.Paths 6>$null } '128 MiB diagnostic limit'
    }
    Run-RuntimeCase 'reparse-loader-parent-is-rejected' {
        param($f)
        $external=Join-Path $f.Root 'external-loader';New-Item -ItemType Directory -Path $external | Out-Null
        $sentinel=Join-Path $external 'dxgi.dll'
        Write-Text $sentinel 'Outside loader must not be collected'
        $sentinelHash=Get-Hash $sentinel
        Remove-Item -LiteralPath $f.Paths.OldBin -Recurse -Force
        $windows=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
        if ($windows) {
            # Native directory junctions require no symlink privilege. Use the
            # native create/delete pair independently of PowerShell's provider.
            $command='mklink /J "'+$f.Paths.OldBin+'" "'+$external+'"'
            $output=& $env:ComSpec /d /c $command 2>&1
            Assert-RuntimeTest ($LASTEXITCODE -eq 0) ('Native junction creation failed: '+($output -join ' '))
        } else { New-Item -ItemType SymbolicLink -Path $f.Paths.OldBin -Target $external | Out-Null }
        try {
            Assert-RuntimeTest (((Get-Item -LiteralPath $f.Paths.OldBin -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Fixture did not create a real reparse directory.'
            Assert-RuntimeThrows { Collect-OptiRuntimeEvidence $f.Paths 6>$null } 'Reparse/junction path is not allowed'
        } finally {
            if ($windows) {
                # No /s: remove only this generated junction, never its target.
                $cleanupCommand='rmdir "'+$f.Paths.OldBin+'"'
                $cleanupOutput=& $env:ComSpec /d /c $cleanupCommand 2>&1
                Assert-RuntimeTest ($LASTEXITCODE -eq 0) ('Native junction cleanup failed: '+($cleanupOutput -join ' '))
            }
            else { Remove-Item -LiteralPath $f.Paths.OldBin -Force }
            Assert-RuntimeTest (-not (Test-Path -LiteralPath $f.Paths.OldBin)) 'Reparse fixture remained after cleanup.'
            Assert-RuntimeTest ((Test-Path -LiteralPath $sentinel -PathType Leaf) -and (Get-Hash $sentinel) -ceq $sentinelHash) 'Junction test modified or removed its external target.'
        }
    }
} finally {
    $failures=@($cases.ToArray() | Where-Object { $_.Status -cne 'PASS' }).Count
    $output=Join-Path $testScriptRoot 'test-results';New-Item -ItemType Directory -Path $output -Force | Out-Null
    Write-Json (Join-Path $output 'opti-runtime-evidence-tests.json') ([pscustomobject]@{Suite='opti-runtime-evidence';PowerShellVersion=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51=($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Passed=($cases.Count-$failures);Failed=$failures;Tests=@($cases.ToArray());GameRuntimeVerified=$false;GraphicsFixVerified=$false})
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
Write-Host ('Runtime evidence tests: '+($cases.Count-$failures)+'/'+$cases.Count+' passed.')
if ($failures) { exit 1 }
