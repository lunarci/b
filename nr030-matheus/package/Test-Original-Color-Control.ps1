#requires -Version 5.1
[CmdletBinding()]
param()
$componentRoot=$PSScriptRoot
. (Join-Path $componentRoot 'Original-Color-Control.ps1') -Action Status
$productionBaseline=$script:OriginalColorBaselineHash;$productionNr=$script:ExpectedNrHash
$originalStopped=(Get-Item Function:\Assert-Stopped).ScriptBlock
$script:OriginalColorTestRunning=$false
function Assert-Stopped { if ($script:OriginalColorTestRunning) { throw 'Close Cyberpunk 2077 and Mod Organizer.' } }
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('OriginalColorTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-TrialTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('ASSERTION: '+$Message) } }
function Assert-TrialThrows([scriptblock]$Code,[string]$Pattern) {
    $failure=$null;try { & $Code | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch $Pattern) { throw ('Expected '+$Pattern+'; got '+[string]$failure) }
}
function Write-TrialPe([string]$Path,[byte]$Marker) {
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[60]=64;$bytes[64]=0x50;$bytes[65]=0x45
    $bytes[68]=0x64;$bytes[69]=0x86;$bytes[87]=0x20;$bytes[100]=$Marker
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function New-TrialFixture([string]$Name) {
    $paths=Get-Paths (Join-Path $fixtureRoot $Name)
    foreach ($folder in @($paths.Plugins,$paths.OldPlugins)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-TrialPe (Join-Path $folder 'MatheusNR030.asi') 1
        Write-TrialPe (Join-Path $folder 'dlssnr_on_amd.asi') 2
        Write-Text (Join-Path $folder 'MatheusNR030.ini') "; preserve bytes`r`n[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nEffectPercent=0`r`nLumaStabilityPercent=100`r`n"
        [IO.File]::WriteAllText((Join-Path $folder 'dlssnr_on_amd.ini'),"[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`nSkinStructure=0`r`n",[Text.Encoding]::Unicode)
        Write-Text (Join-Path $folder 'nvngx_dlssnr.dll') 'MODEL MUST NOT CHANGE'
    }
    foreach ($folder in @($paths.Bin,$paths.OldBin)) {
        [IO.File]::WriteAllText((Join-Path $folder 'OptiScaler.ini'),"[XeFG]`nInterpolationCount=4`n[UpscaleRatio]`nUpscaleRatioOverrideValue=2.000000`n",[Text.Encoding]::Unicode)
        Write-Text (Join-Path $folder 'OptiScaler.dll') 'PRESERVE OPTISCALER'
        Write-Text (Join-Path $folder 'libxess_fg.dll') 'PRESERVE XEFG'
    }
    # Synthetic hashes exist only inside this test process. Production has no
    # CLI or environment override and retains its pinned baseline constants.
    $script:OriginalColorBaselineHash=Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.asi')
    $script:ExpectedNrHash=Get-Hash (Join-Path $paths.Plugins 'dlssnr_on_amd.asi')
    New-Item -ItemType Directory -Path $paths.Backup | Out-Null
    Write-Json $paths.State ([pscustomobject]@{SchemaVersion=1;AddonName='MatheusNR030';PluginFolder=$paths.Plugins;AddonVersion='0.2.4';Files=@([pscustomobject]@{Name='MatheusNR030.asi';InstalledHash=$script:OriginalColorBaselineHash},[pscustomobject]@{Name='MatheusNR030.ini';InstalledHash=(Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.ini'))});RuntimeVerified=$false})
    $package=Join-Path $paths.Root 'test-package';New-Item -ItemType Directory -Path (Join-Path $package 'payload') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $componentRoot 'protected-files.json') -Destination $package
    Write-TrialPe (Join-Path $package 'payload/MatheusNR030.asi') 3
    Write-Text (Join-Path $package 'payload/MatheusNR030.ini') 'PACKAGED DEFAULT MUST NEVER BE INSTALLED'
    $entries=@();foreach ($name in @('MatheusNR030.asi','MatheusNR030.ini')) {
        $file=Join-Path $package ('payload/'+$name);$entries += [pscustomobject]@{name=$name;sha256=(Get-Hash $file);size=(Get-Item -LiteralPath $file).Length}
    }
    Write-Json (Join-Path $package 'package-manifest.json') ([pscustomobject]@{schema_version=1;addon_name='MatheusNR030';build_verified=$true;abi_verified=$true;base_nr_sha256=$script:ExpectedNrHash;source_commit=('a'*40);addon_version='0.2.4-original-color-trial';build_run_id='123456';build_evidence='https://github.com/lunarci/b/actions/runs/123456';abi_evidence='SYNTHETIC TEST ONLY';game_runtime_verified=$false;runtime_log_schema='matheusnr030-events-v1';files=$entries})
    $script:PackageRoot=$package
    [pscustomobject]@{Paths=$paths;Package=$package;Primary=(Join-Path $paths.Plugins 'MatheusNR030.asi');Secondary=(Join-Path $paths.OldPlugins 'MatheusNR030.asi');Payload=(Join-Path $package 'payload/MatheusNR030.asi')}
}
function Assert-TrialUnrelated($Paths,$Before) {
    $after=Get-OriginalColorSnapshot $Paths
    Assert-TrialTest ($after.Count -eq $Before.Count) 'File inventory changed.'
    foreach ($path in $Before.Keys) {
        if ($path -eq $Paths.State -or [IO.Path]::GetFileName($path) -ceq 'MatheusNR030.asi') { continue }
        Assert-TrialTest ($after[$path] -ceq $Before[$path]) ('An unrelated file or INI changed: '+$path)
    }
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        $path=Join-Path $folder 'OptiScaler.ini'
        if (Test-Path -LiteralPath $path -PathType Leaf) { Assert-TrialTest ((Read-IniValue ([IO.File]::ReadAllText($path)) 'XeFG' 'InterpolationCount') -ceq '4') 'Intentional 5X configuration changed.' }
    }
}
function Run-TrialCase([string]$Name,[scriptblock]$Body) {
    $script:OriginalColorTestRunning=$false
    try { $fixture=New-TrialFixture $Name;& $Body $fixture;$results.Add([pscustomobject]@{Name=$Name;Status='PASS'});Write-Host ('PASS '+$Name) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) }
}
try {
    Run-TrialCase 'apply-restores-exact-asi-and-state-preserving-all-inis-and-xefg-five-times' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        Assert-TrialUnrelated $f.Paths $before
        foreach ($path in @($f.Primary,$f.Secondary)) { Assert-TrialTest ((Get-Hash $path) -ceq (Get-Hash $f.Payload)) 'Diagnostic ASI was not installed.' }
        $state=Read-AddonState $f.Paths;Assert-OwnedFiles $f.Paths $state -AllowModifiedIni
        $trial=Read-OriginalColorTrial $f.Paths $state;Assert-TrialTest ($null -ne $trial) 'Trial record absent.'
        $active=Get-OriginalColorSnapshot $f.Paths;Show-OriginalColorStatus $f.Paths;Assert-OriginalColorSnapshot $f.Paths $active
        Invoke-OriginalColorControl $f.Paths Restore
        Assert-OriginalColorSnapshot $f.Paths $before
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths) -AllowModifiedIni
    }
    Run-TrialCase 'missing-overwrite-remains-absent-and-reapply-preserves-first-backup' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.OldBin -Recurse -Force
        $before=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        $active=Get-OriginalColorSnapshot $f.Paths;$first=(Read-AddonState $f.Paths).OriginalColorTrial.BackupFolder
        Invoke-OriginalColorControl $f.Paths Apply;Assert-OriginalColorSnapshot $f.Paths $active
        Assert-TrialTest ((Read-AddonState $f.Paths).OriginalColorTrial.BackupFolder -ceq $first) 'Reapply replaced original backup.'
        Assert-TrialTest (-not (Test-Path -LiteralPath $f.Paths.OldBin)) 'Missing overwrite path was created.'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'restore-preserves-later-user-ini-edits-and-does-not-require-payload' {
        param($f)
        $originalState=Get-Hash $f.Paths.State
        Invoke-OriginalColorControl $f.Paths Apply
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $path=Join-Path $folder 'MatheusNR030.ini'
            Write-Text $path ([IO.File]::ReadAllText($path).Replace('EffectPercent=0','EffectPercent=25'))
        }
        $opti=Join-Path $f.Paths.Bin 'OptiScaler.ini';[IO.File]::AppendAllText($opti,"; later user change`n",[Text.Encoding]::Unicode)
        $before=Get-OriginalColorSnapshot $f.Paths
        Remove-Item -LiteralPath $f.Payload
        Invoke-OriginalColorControl $f.Paths Restore
        Assert-TrialUnrelated $f.Paths $before
        Assert-TrialTest ((Get-Hash $f.Paths.State) -ceq $originalState) 'Original state bytes changed.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths) -AllowModifiedIni
    }
    Run-TrialCase 'wrong-settings-base-hash-unowned-or-modified-addon-block-before-writes' {
        param($f)
        $ini=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini';$text=[IO.File]::ReadAllText($ini)
        foreach ($edit in @(@('EffectPercent=0','EffectPercent=50'),@('ScalePercent=85','ScalePercent=100'),@('Enabled=1','Enabled=0'))) {
            Write-Text $ini ($text.Replace($edit[0],$edit[1]));$before=Get-OriginalColorSnapshot $f.Paths
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Trial requires';Assert-OriginalColorSnapshot $f.Paths $before
        }
        Write-Text $ini $text
        $nr=Join-Path $f.Paths.OldPlugins 'dlssnr_on_amd.asi';$old=[IO.File]::ReadAllBytes($nr);Write-TrialPe $nr 99
        $before=Get-OriginalColorSnapshot $f.Paths;Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Pinned base NR hash mismatch';Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($nr,$old)
        Write-TrialPe $f.Secondary 88;$before=Get-OriginalColorSnapshot $f.Paths
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Modified add-on file';Assert-OriginalColorSnapshot $f.Paths $before
        Write-TrialPe $f.Secondary 1
        $stateFile=[IO.File]::ReadAllBytes($f.Paths.State);Remove-Item -LiteralPath $f.Paths.State
        $before=Get-OriginalColorSnapshot $f.Paths;Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'ownership record';Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($f.Paths.State,$stateFile)
    }
    Run-TrialCase 'tampered-backups-trial-state-or-binaries-block-restore' {
        param($f)
        Invoke-OriginalColorControl $f.Paths Apply
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        foreach ($path in @($trial.Files[0].Backup,$trial.OriginalStateBackup,$f.Primary)) {
            $old=[IO.File]::ReadAllBytes($path);Write-Text $path 'TAMPERED';$before=Get-OriginalColorSnapshot $f.Paths
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore } 'backup is missing or changed|Modified add-on file';Assert-OriginalColorSnapshot $f.Paths $before
            [IO.File]::WriteAllBytes($path,$old)
        }
        $state=Read-AddonState $f.Paths;$state.AddonVersion='unexpected later ownership edit';Write-Json $f.Paths.State $state
        $before=Get-OriginalColorSnapshot $f.Paths;Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore } 'state changed after';Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'apply-and-restore-failures-rollback-each-write-including-second-asi' {
        param($f)
        foreach ($failureIndex in @(0,1,2)) {
            $before=Get-OriginalColorSnapshot $f.Paths
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected trial apply failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'injected trial apply failure';Assert-OriginalColorSnapshot $f.Paths $before
        }
        Invoke-OriginalColorControl $f.Paths Apply
        foreach ($failureIndex in @(0,1,2)) {
            $before=Get-OriginalColorSnapshot $f.Paths
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected trial restore failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore $inject } 'injected trial restore failure';Assert-OriginalColorSnapshot $f.Paths $before
        }
        Invoke-OriginalColorControl $f.Paths Restore
    }
    Run-TrialCase 'pre-first-write-conflict-never-rolls-back-over-external-edit' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        $inject={ param($index) if ($index -eq 0) { Write-TrialPe $f.Primary 77 } }.GetNewClosure()
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'Files changed while preparing'
        $before[$f.Primary]=Get-Hash $f.Primary;Assert-OriginalColorSnapshot $f.Paths $before
        $bytes=[IO.File]::ReadAllBytes($f.Primary);Assert-TrialTest ($bytes[100] -eq 77) 'Pre-write external edit was overwritten by rollback.'
    }
    Run-TrialCase 'staged-source-tamper-blocks-apply-and-rolls-back-partial-restore' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        $applyInject={ param($index) if ($index -eq 0) {
            $folder=@(Get-ChildItem -LiteralPath $f.Paths.Backup -Directory | Where-Object { $_.Name -like 'original-color-apply-*' } | Sort-Object LastWriteTimeUtc -Descending)[0]
            Write-TrialPe (Join-Path $folder.FullName 'diagnostic.asi') 66
        } }.GetNewClosure()
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $applyInject } 'Staged trial source changed before copy'
        Assert-OriginalColorSnapshot $f.Paths $before
        Invoke-OriginalColorControl $f.Paths Apply
        $active=Get-OriginalColorSnapshot $f.Paths
        $restoreInject={ param($index) if ($index -eq 1) {
            $folder=@(Get-ChildItem -LiteralPath $f.Paths.Backup -Directory | Where-Object { $_.Name -like 'original-color-restore-*' } | Sort-Object LastWriteTimeUtc -Descending)[0]
            Write-TrialPe (Join-Path $folder.FullName 'restore-original-1.asi') 77
        } }.GetNewClosure()
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore $restoreInject } 'Staged trial source changed before copy'
        Assert-OriginalColorSnapshot $f.Paths $active
        Invoke-OriginalColorControl $f.Paths Restore
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'running-game-and-corrupt-payload-block-and-status-is-read-only' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths;$script:OriginalColorTestRunning=$true
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Close Cyberpunk';Assert-OriginalColorSnapshot $f.Paths $before
        $script:OriginalColorTestRunning=$false
        Show-OriginalColorStatus $f.Paths;Assert-OriginalColorSnapshot $f.Paths $before
        Write-TrialPe $f.Payload 55
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Payload SHA-256/size mismatch';Assert-OriginalColorSnapshot $f.Paths $before
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore } 'No active original-color trial';Assert-OriginalColorSnapshot $f.Paths $before
    }
} finally {
    $script:OriginalColorBaselineHash=$productionBaseline;$script:ExpectedNrHash=$productionNr;$script:PackageRoot=$componentRoot
    Set-Item Function:\Assert-Stopped $originalStopped
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$report=[pscustomobject]@{SchemaVersion=1;Component='OriginalColorControl';PowerShellVersion=$PSVersionTable.PSVersion.ToString();NativeWindows=($env:OS -ceq 'Windows_NT');WindowsPowerShell51=($env:OS -ceq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Passed=@($results | Where-Object { $_.Status -ceq 'PASS' }).Count;Failed=@($results | Where-Object { $_.Status -ceq 'FAIL' }).Count;TestCount=$results.Count;Tests=@($results.ToArray());GameplayVisualQualityVerified=$false}
$output=Join-Path $componentRoot 'test-results';New-Item -ItemType Directory -Path $output -Force | Out-Null
Write-Json (Join-Path $output 'original-color-control-tests.json') $report
Write-Host ('Original-color control tests: '+$report.Passed+' passed, '+$report.Failed+' failed.')
if ($report.Failed) { exit 1 }
exit 0
