#requires -Version 5.1
[CmdletBinding()]
param()
$componentRoot=$PSScriptRoot
. (Join-Path $componentRoot 'Original-Color-Control.ps1') -Action Status
$productionBaseline=$script:OriginalColorBaselineHash;$productionNr=$script:ExpectedNrHash;$productionPrevious=$script:OriginalColorPreviousDiagnosticHash
$originalStopped=(Get-Item Function:\Assert-Stopped).ScriptBlock
$script:OriginalColorTestRunning=$false
function Assert-Stopped { if ($script:OriginalColorTestRunning) { throw 'Close Cyberpunk 2077 and Mod Organizer.' } }
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('OriginalColorTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
$script:NativeEffectApiVerified=$false
if ($env:OS -ceq 'Windows_NT') {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class OriginalColorNativeIni {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, EntryPoint="GetPrivateProfileStringW")]
    public static extern uint ReadString(string section, string key, string fallback, StringBuilder value, uint capacity, string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, EntryPoint="GetPrivateProfileIntW")]
    public static extern uint ReadInt(string section, string key, int fallback, string path);
}
'@
}

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
    Write-TrialPe (Join-Path $package 'previous-diagnostic.asi') 4
    $script:OriginalColorPreviousDiagnosticHash=Get-Hash (Join-Path $package 'previous-diagnostic.asi')
    Write-TrialPe (Join-Path $package 'payload/MatheusNR030.asi') 3
    Write-Text (Join-Path $package 'payload/MatheusNR030.ini') 'PACKAGED DEFAULT MUST NEVER BE INSTALLED'
    $entries=@();foreach ($name in @('MatheusNR030.asi','MatheusNR030.ini')) {
        $file=Join-Path $package ('payload/'+$name);$entries += [pscustomobject]@{name=$name;sha256=(Get-Hash $file);size=(Get-Item -LiteralPath $file).Length}
    }
    Write-Json (Join-Path $package 'package-manifest.json') ([pscustomobject]@{schema_version=1;addon_name='MatheusNR030';build_verified=$true;abi_verified=$true;base_nr_sha256=$script:ExpectedNrHash;source_commit=('a'*40);addon_version='0.2.4-original-color-trial';build_run_id='123456';build_evidence='https://github.com/lunarci/b/actions/runs/123456';abi_evidence='SYNTHETIC TEST ONLY';game_runtime_verified=$false;runtime_log_schema='matheusnr030-events-v1';files=$entries})
    $script:PackageRoot=$package
    [pscustomobject]@{Paths=$paths;Package=$package;Primary=(Join-Path $paths.Plugins 'MatheusNR030.asi');Secondary=(Join-Path $paths.OldPlugins 'MatheusNR030.asi');Payload=(Join-Path $package 'payload/MatheusNR030.asi')}
}
function Set-TrialPayload($Fixture,[byte]$Marker) {
    Write-TrialPe $Fixture.Payload $Marker
    $manifestPath=Join-Path $Fixture.Package 'package-manifest.json';$manifest=Read-Json $manifestPath
    $entry=@($manifest.files | Where-Object { $_.name -ceq 'MatheusNR030.asi' })[0]
    $entry.sha256=Get-Hash $Fixture.Payload;$entry.size=(Get-Item -LiteralPath $Fixture.Payload).Length
    Write-Json $manifestPath $manifest
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
            Write-Text $path ([IO.File]::ReadAllText($path).Replace('EffectPercent=0','EffectPercent=25').Replace('LumaStabilityPercent=100','LumaStabilityPercent=42'))
        }
        $opti=Join-Path $f.Paths.Bin 'OptiScaler.ini';[IO.File]::AppendAllText($opti,"; later user change`n",[Text.Encoding]::Unicode)
        $before=Get-OriginalColorSnapshot $f.Paths
        Remove-Item -LiteralPath $f.Payload
        Invoke-OriginalColorControl $f.Paths Restore
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $path=Join-Path $folder 'MatheusNR030.ini';$text=[IO.File]::ReadAllText($path)
            Assert-TrialTest ((Read-IniValue $text 'MatheusNR030' 'EffectPercent') -ceq '0' -and (Read-IniValue $text 'MatheusNR030' 'LumaStabilityPercent') -ceq '42') 'Effect restore lost a later unrelated edit.'
            $before[$path]=Get-Hash $path
        }
        Assert-TrialUnrelated $f.Paths $before
        Assert-TrialTest ((Get-Hash $f.Paths.State) -ceq $originalState) 'Original state bytes changed.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths) -AllowModifiedIni
    }
    Run-TrialCase 'wrong-settings-base-hash-unowned-or-modified-addon-block-before-writes' {
        param($f)
        $ini=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini';$text=[IO.File]::ReadAllText($ini)
        foreach ($edit in @(@('ScalePercent=85','ScalePercent=100'),@('Enabled=1','Enabled=0'))) {
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
        $primaryBytes=[IO.File]::ReadAllBytes($f.Primary);Remove-Item -LiteralPath $f.Primary
        $before=Get-OriginalColorSnapshot $f.Paths;Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } ([regex]::Escape('Existing primary add-on ASI is required: '+$f.Primary));Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($f.Primary,$primaryBytes);[IO.File]::WriteAllBytes($f.Paths.State,$stateFile)
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
    Run-TrialCase 'missing-record-adopts-verified-files-and-restores-absence-primary-and-overwrite' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.State
        foreach ($variant in @('with-overwrite','primary-only')) {
            if ($variant -ceq 'primary-only') { Remove-Item -LiteralPath $f.Paths.OldBin -Recurse -Force }
            $before=Get-OriginalColorSnapshot $f.Paths
            Show-OriginalColorStatus $f.Paths;Assert-OriginalColorSnapshot $f.Paths $before
            Invoke-OriginalColorControl $f.Paths Apply;Assert-TrialUnrelated $f.Paths $before
            $state=Read-AddonState $f.Paths;$trial=Read-OriginalColorTrial $f.Paths $state
            Assert-TrialTest ($trial.OriginalStateExisted -is [bool] -and -not $trial.OriginalStateExisted) 'Original record absence was not retained.'
            Assert-TrialTest ($null -eq $trial.OriginalStateBackup -and $null -eq $trial.OriginalStateHash) 'A historical state backup was fabricated.'
            Assert-TrialTest (-not (Test-Path -LiteralPath (Join-Path $trial.BackupFolder 'original-state.json'))) 'An absent original state was fabricated on disk.'
            Assert-TrialTest ($state.OwnershipBasis -ceq 'CurrentFilesVerifiedAtTrialApply') 'Current file verification basis was not explicit.'
            $active=Get-OriginalColorSnapshot $f.Paths
            Invoke-OriginalColorControl $f.Paths Apply;Assert-OriginalColorSnapshot $f.Paths $active
            Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
            Assert-TrialTest (-not (Test-Path -LiteralPath $f.Paths.State)) 'Restoration did not recover original record absence.'
        }
    }
    Run-TrialCase 'missing-record-write-failures-preserve-absence-and-rollback-active-trial' {
        param($f)
        Remove-Item -LiteralPath $f.Paths.State;$before=Get-OriginalColorSnapshot $f.Paths
        foreach ($failureIndex in @(0,1,2)) {
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected recordless apply failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'injected recordless apply failure'
            Assert-OriginalColorSnapshot $f.Paths $before
        }
        Invoke-OriginalColorControl $f.Paths Apply;$active=Get-OriginalColorSnapshot $f.Paths
        foreach ($failureIndex in @(0,1,2)) {
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected recordless restore failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore $inject } 'injected recordless restore failure'
            Assert-OriginalColorSnapshot $f.Paths $active
        }
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'malformed-conflicting-or-directory-state-is-never-adopted' {
        param($f)
        $original=[IO.File]::ReadAllBytes($f.Paths.State)
        Write-Text $f.Paths.State '{ this is not JSON'
        $before=Get-OriginalColorSnapshot $f.Paths
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'JSON|Unexpected|Invalid';Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($f.Paths.State,$original)
        $state=Read-AddonState $f.Paths;$state.SchemaVersion=2;Write-Json $f.Paths.State $state
        $before=Get-OriginalColorSnapshot $f.Paths
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Invalid add-on state';Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($f.Paths.State,$original)
        $state=Read-AddonState $f.Paths;(@($state.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0]).InstalledHash=('f'*64);Write-Json $f.Paths.State $state
        $before=Get-OriginalColorSnapshot $f.Paths
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Modified add-on file';Assert-OriginalColorSnapshot $f.Paths $before
        [IO.File]::WriteAllBytes($f.Paths.State,$original);$before=Get-OriginalColorSnapshot $f.Paths
        Remove-Item -LiteralPath $f.Paths.State;New-Item -ItemType Directory -Path $f.Paths.State | Out-Null
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'directory occupies the add-on state path'
        Assert-TrialTest (Test-Path -LiteralPath $f.Paths.State -PathType Container) 'State directory was replaced.'
        Remove-Item -LiteralPath $f.Paths.State;[IO.File]::WriteAllBytes($f.Paths.State,$original)
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'missing-record-concurrent-state-creation-is-never-overwritten' {
        param($f)
        foreach ($conflictIndex in @(0,2)) {
            Remove-Item -LiteralPath $f.Paths.State -ErrorAction SilentlyContinue
            $before=Get-OriginalColorSnapshot $f.Paths
            $inject={ param($index) if ($index -eq $conflictIndex) { Write-Text $f.Paths.State 'EXTERNAL STATE CREATED CONCURRENTLY' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'Files changed while preparing|Trial destination changed before write'
            Assert-TrialTest ([IO.File]::ReadAllText($f.Paths.State) -ceq 'EXTERNAL STATE CREATED CONCURRENTLY') 'External state was overwritten or deleted.'
            $before[$f.Paths.State]=Get-Hash $f.Paths.State
            Assert-OriginalColorSnapshot $f.Paths $before
        }
    }
    Run-TrialCase 'legacy-trial-without-original-state-flag-restores-existing-record' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        $state=Read-AddonState $f.Paths;$state.OriginalColorTrial.PSObject.Properties.Remove('OriginalStateExisted');$state.OriginalColorTrial.PSObject.Properties.Remove('EffectFiles');Write-Json $f.Paths.State $state
        Invoke-OriginalColorControl $f.Paths Restore
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'effect-positive-values-and-missing-state-restore-independent-originals' {
        param($f)
        $primary=Join-Path $f.Paths.Plugins 'MatheusNR030.ini';$shadow=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini'
        Write-Text $primary ([IO.File]::ReadAllText($primary).Replace('EffectPercent=0','EffectPercent=50'))
        Write-Text $shadow ([IO.File]::ReadAllText($shadow).Replace('EffectPercent=0','EffectPercent=100'))
        Remove-Item -LiteralPath $f.Paths.State
        $before=Get-OriginalColorSnapshot $f.Paths;$protected=Get-ProtectedSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        foreach ($path in @($primary,$shadow)) { Assert-TrialTest (Get-OriginalColorEffect ([IO.File]::ReadAllText($path))).NativeZero 'Effect was not set to native-readable zero.' }
        Assert-SnapshotUnchanged $f.Paths $protected
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest ($trial.EffectFiles[0].EffectValue -ceq '50' -and $trial.EffectFiles[1].EffectValue -ceq '100') 'Independent original Effects were lost.'
        $active=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply;Assert-OriginalColorSnapshot $f.Paths $active
        Write-Text $primary ([IO.File]::ReadAllText($primary).Replace('EffectPercent=0','EffectPercent=25'))
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'EffectPercent changed after.*Run Restore, then Apply'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'effect-missing-or-empty-key-restores-original-presence' {
        param($f)
        $primary=Join-Path $f.Paths.Plugins 'MatheusNR030.ini';$shadow=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini'
        Write-Text $primary ([IO.File]::ReadAllText($primary).Replace("EffectPercent=0`r`n",''))
        Write-Text $shadow ([IO.File]::ReadAllText($shadow).Replace('EffectPercent=0','EffectPercent='))
        Remove-Item -LiteralPath $f.Paths.State
        $before=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        foreach ($path in @($primary,$shadow)) { Assert-TrialTest (Get-OriginalColorEffect ([IO.File]::ReadAllText($path))).NativeZero 'Missing/empty Effect was not set to zero.' }
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest (-not $trial.EffectFiles[0].EffectPresent -and $trial.EffectFiles[1].EffectPresent) 'Original key presence was not retained.'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'effect-restore-preserves-later-unrelated-ini-edits' {
        param($f)
        $primary=Join-Path $f.Paths.Plugins 'MatheusNR030.ini';$shadow=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini'
        Write-Text $primary ([IO.File]::ReadAllText($primary).Replace('EffectPercent=0','EffectPercent=50'))
        Write-Text $shadow ([IO.File]::ReadAllText($shadow).Replace("EffectPercent=0`r`n",''))
        Invoke-OriginalColorControl $f.Paths Apply
        foreach ($path in @($primary,$shadow)) {
            Write-Text $path ([IO.File]::ReadAllText($path).Replace('LumaStabilityPercent=100','LumaStabilityPercent=37').Replace('EffectPercent=0','EffectPercent=25')+"; retain this later note`n")
        }
        Invoke-OriginalColorControl $f.Paths Restore
        foreach ($path in @($primary,$shadow)) {
            $text=[IO.File]::ReadAllText($path)
            Assert-TrialTest ((Read-IniValue $text 'MatheusNR030' 'LumaStabilityPercent') -ceq '37' -and $text.Contains('; retain this later note')) 'Later unrelated user changes were discarded.'
            Assert-TrialTest ((Read-IniValue $text 'MatheusNR030' 'ScalePercent') -ceq '85') 'NR input scale changed.'
        }
        Assert-TrialTest ((Get-OriginalColorEffect ([IO.File]::ReadAllText($primary))).Value -ceq '50') 'Primary original Effect not restored.'
        Assert-TrialTest (-not (Get-OriginalColorEffect ([IO.File]::ReadAllText($shadow))).Present) 'Originally absent Effect key was not removed.'
    }
    Run-TrialCase 'effect-ini-and-state-write-failures-rollback-whole-transaction' {
        param($f)
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $path=Join-Path $folder 'MatheusNR030.ini';Write-Text $path ([IO.File]::ReadAllText($path).Replace('EffectPercent=0','EffectPercent=50'))
        }
        Remove-Item -LiteralPath $f.Paths.State;$before=Get-OriginalColorSnapshot $f.Paths
        foreach ($failureIndex in @(2,3,4)) {
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected Effect apply failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'injected Effect apply failure';Assert-OriginalColorSnapshot $f.Paths $before
        }
        Invoke-OriginalColorControl $f.Paths Apply;$active=Get-OriginalColorSnapshot $f.Paths
        foreach ($failureIndex in @(2,3,4)) {
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected Effect restore failure' } }.GetNewClosure()
            Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Restore $inject } 'injected Effect restore failure';Assert-OriginalColorSnapshot $f.Paths $active
        }
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'effect-duplicate-key-stops-before-any-write' {
        param($f)
        $path=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini'
        Write-Text $path ([IO.File]::ReadAllText($path)+"EffectPercent=100`n")
        Remove-Item -LiteralPath $f.Paths.State;$before=Get-OriginalColorSnapshot $f.Paths
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply } 'Ambiguous duplicate INI key.*EffectPercent'
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'effect-native-windows-parser-reads-zero-across-encodings' {
        param($f)
        $path=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'
        $cases=@(
            [pscustomobject]@{Name='ascii50';Encoding=[Text.Encoding]::ASCII;Value='50'},
            [pscustomobject]@{Name='utf8-bom-first-section-zero';Encoding=(New-Object Text.UTF8Encoding($true));Value='0'},
            [pscustomobject]@{Name='utf8-bom50-inline';Encoding=(New-Object Text.UTF8Encoding($true));Value='50 ; original comment'},
            [pscustomobject]@{Name='utf16-le-zero-inline';Encoding=[Text.Encoding]::Unicode;Value='0 ; original comment'},
            [pscustomobject]@{Name='utf16-be100';Encoding=[Text.Encoding]::BigEndianUnicode;Value='100'}
        )
        foreach ($case in $cases) {
            [IO.File]::WriteAllText($path,("[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nEffectPercent="+$case.Value+"`r`nLumaStabilityPercent=100`r`n"),$case.Encoding)
            $before=Get-OriginalColorSnapshot $f.Paths
            Invoke-OriginalColorControl $f.Paths Apply
            Assert-TrialTest (Get-OriginalColorEffect ([IO.File]::ReadAllText($path))).NativeZero ('Noncanonical Effect after '+$case.Name)
            if ($env:OS -ceq 'Windows_NT') {
                $buffer=New-Object Text.StringBuilder 256
                $null=[OriginalColorNativeIni]::ReadString('MatheusNR030','EffectPercent','__MISSING__',$buffer,256,$path)
                Assert-TrialTest ($buffer.ToString() -ceq '0') ('Native string parser did not read literal zero for '+$case.Name+': '+$buffer.ToString())
                Assert-TrialTest ([OriginalColorNativeIni]::ReadInt('MatheusNR030','EffectPercent',9876,$path) -eq 0) ('Native integer parser did not read zero for '+$case.Name)
                Assert-TrialTest ([OriginalColorNativeIni]::ReadInt('MatheusNR030','ScalePercent',9876,$path) -eq 85) ('Native scale changed for '+$case.Name)
            }
            Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
        }
        if ($env:OS -ceq 'Windows_NT') { $script:NativeEffectApiVerified=$true }
    }
    Run-TrialCase 'known-diagnostic-without-state-adopts-and-restores-own-bytes' {
        param($f)
        foreach ($path in @($f.Primary,$f.Secondary)) { Write-TrialPe $path 4 }
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=50'))
        }
        Remove-Item -LiteralPath $f.Paths.State;$before=Get-OriginalColorSnapshot $f.Paths
        Invoke-OriginalColorControl $f.Paths Apply
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest ($trial.BaselineHash -ceq $script:OriginalColorPreviousDiagnosticHash -and -not $trial.OriginalStateExisted) 'Known diagnostic baseline was not recorded correctly.'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'known-diagnostic-active-trial-upgrade-preserves-first-backups' {
        param($f)
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=50'))
        }
        $before=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 4;Invoke-OriginalColorControl $f.Paths Apply
        $originalTrial=Copy-OriginalColorObject (Read-AddonState $f.Paths).OriginalColorTrial
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini'
            Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('LumaStabilityPercent=100','LumaStabilityPercent=42'))
        }
        Set-TrialPayload $f 3;Invoke-OriginalColorControl $f.Paths Apply
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest ($trial.BackupFolder -ceq $originalTrial.BackupFolder -and $trial.OriginalStateHash -ceq $originalTrial.OriginalStateHash) 'Upgrade replaced the first original ASI/state backup.'
        Assert-TrialTest ($trial.EffectFiles[0].BeforeHash -ceq $originalTrial.EffectFiles[0].BeforeHash -and $trial.EffectFiles[0].EffectValue -ceq '50') 'Upgrade replaced the first original Effect backup.'
        foreach ($path in @($f.Primary,$f.Secondary)) { Assert-TrialTest ((Get-Hash $path) -ceq (Get-Hash $f.Payload)) 'New ASI did not replace the known previous diagnostic.' }
        Invoke-OriginalColorControl $f.Paths Restore
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';$text=[IO.File]::ReadAllText($ini)
            Assert-TrialTest ((Read-IniValue $text 'MatheusNR030' 'LumaStabilityPercent') -ceq '42' -and (Read-IniValue $text 'MatheusNR030' 'EffectPercent') -ceq '50') 'Upgrade restore lost unrelated edits made after the first trial.'
            $before[$ini]=Get-Hash $ini
        }
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'known-diagnostic-upgrade-failure-rolls-back-active-trial' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 4;Invoke-OriginalColorControl $f.Paths Apply
        $active=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 3
        $inject={ param($index) if ($index -eq 1) { throw 'injected diagnostic upgrade failure' } }
        Assert-TrialThrows { Invoke-OriginalColorControl $f.Paths Apply $inject } 'injected diagnostic upgrade failure'
        Assert-OriginalColorSnapshot $f.Paths $active
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'legacy-active-trial-without-effect-metadata-upgrades-and-restores' {
        param($f)
        $before=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 4;Invoke-OriginalColorControl $f.Paths Apply
        $state=Read-AddonState $f.Paths;$oldFolder=$state.OriginalColorTrial.BackupFolder
        $state.OriginalColorTrial.PSObject.Properties.Remove('EffectFiles');$state.OriginalColorTrial.PSObject.Properties.Remove('EffectBackupFolder');Write-Json $f.Paths.State $state
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=50'))
            $before[$ini]=Get-Hash $ini
        }
        Set-TrialPayload $f 3;Invoke-OriginalColorControl $f.Paths Apply
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest ($trial.BackupFolder -ceq $oldFolder -and $trial.EffectBackupFolder -cne $oldFolder) 'Legacy ASI backup was replaced or new Effect backup scope was wrong.'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'preserve-effect-current-values-and-known-binaries-without-state' {
        param($f)
        foreach ($marker in @(1,4)) { foreach ($value in @('0','50')) {
            foreach ($path in @($f.Primary,$f.Secondary)) { Write-TrialPe $path $marker }
            foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
                $ini=Join-Path $folder 'MatheusNR030.ini'
                Write-Text $ini (Set-OriginalColorEffectText ([IO.File]::ReadAllText($ini)) $true $value)
            }
            Remove-Item -LiteralPath $f.Paths.State -ErrorAction SilentlyContinue
            $before=Get-OriginalColorSnapshot $f.Paths
            Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
            Assert-TrialUnrelated $f.Paths $before
            $trial=(Read-AddonState $f.Paths).OriginalColorTrial
            Assert-TrialTest ($trial.PreserveEffectApplied -eq $true -and $null -eq (Get-Value $trial 'EffectFiles')) 'Preserve mode fabricated Effect ownership.'
            $active=Get-OriginalColorSnapshot $f.Paths
            Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect;Assert-OriginalColorSnapshot $f.Paths $active
            Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
        } }
    }
    Run-TrialCase 'preserve-effect-upgrade-keeps-prior-effect-restore-chain' {
        param($f)
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=50'))
        }
        $before=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 4;Invoke-OriginalColorControl $f.Paths Apply
        $oldTrial=Copy-OriginalColorObject (Read-AddonState $f.Paths).OriginalColorTrial
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini'
            Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=25').Replace('LumaStabilityPercent=100','LumaStabilityPercent=42'))
        }
        $atUpgrade=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 3;Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
        Assert-TrialUnrelated $f.Paths $atUpgrade
        $trial=(Read-AddonState $f.Paths).OriginalColorTrial
        Assert-TrialTest ($trial.EffectFiles[0].Backup -ceq $oldTrial.EffectFiles[0].Backup -and $trial.EffectFiles[0].BeforeHash -ceq $oldTrial.EffectFiles[0].BeforeHash) 'Preserve upgrade discarded prior Effect backup.'
        Invoke-OriginalColorControl $f.Paths Restore
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';$text=[IO.File]::ReadAllText($ini)
            Assert-TrialTest ((Read-IniValue $text 'MatheusNR030' 'EffectPercent') -ceq '50' -and (Read-IniValue $text 'MatheusNR030' 'LumaStabilityPercent') -ceq '42') 'Prior Effect chain or unrelated edits were lost.'
            $before[$ini]=Get-Hash $ini
        }
        Assert-OriginalColorSnapshot $f.Paths $before
    }
    Run-TrialCase 'preserve-effect-upgrade-without-effect-ownership-retains-later-values' {
        param($f)
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini';Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=0','EffectPercent=50'))
        }
        $before=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 4;Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            $ini=Join-Path $folder 'MatheusNR030.ini'
            Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('EffectPercent=50','EffectPercent=0').Replace('LumaStabilityPercent=100','LumaStabilityPercent=37'))
            $before[$ini]=Get-Hash $ini
        }
        $atUpgrade=Get-OriginalColorSnapshot $f.Paths
        Set-TrialPayload $f 3;Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
        Assert-TrialUnrelated $f.Paths $atUpgrade
        Assert-TrialTest ($null -eq (Get-Value (Read-AddonState $f.Paths).OriginalColorTrial 'EffectFiles')) 'Preserve-only chain invented Effect restoration.'
        Invoke-OriginalColorControl $f.Paths Restore;Assert-OriginalColorSnapshot $f.Paths $before
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
    $script:OriginalColorBaselineHash=$productionBaseline;$script:ExpectedNrHash=$productionNr;$script:OriginalColorPreviousDiagnosticHash=$productionPrevious;$script:PackageRoot=$componentRoot
    Set-Item Function:\Assert-Stopped $originalStopped
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$report=[pscustomobject]@{SchemaVersion=1;Component='OriginalColorControl';PowerShellVersion=$PSVersionTable.PSVersion.ToString();NativeWindows=($env:OS -ceq 'Windows_NT');WindowsPowerShell51=($env:OS -ceq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);NativeEffectApiVerified=$script:NativeEffectApiVerified;Passed=@($results | Where-Object { $_.Status -ceq 'PASS' }).Count;Failed=@($results | Where-Object { $_.Status -ceq 'FAIL' }).Count;TestCount=$results.Count;Tests=@($results.ToArray());GameplayVisualQualityVerified=$false}
$output=Join-Path $componentRoot 'test-results';New-Item -ItemType Directory -Path $output -Force | Out-Null
Write-Json (Join-Path $output 'original-color-control-tests.json') $report
Write-Host ('Original-color control tests: '+$report.Passed+' passed, '+$report.Failed+' failed.')
if ($report.Failed) { exit 1 }
exit 0
