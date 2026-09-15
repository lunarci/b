#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Apply','Restore','Status')][string]$Action='Status',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2',
    [switch]$PreserveEffect
)
$originalColorAction=$Action;$originalColorRoot=$Mo2Root;$originalColorPreserveEffect=[bool]$PreserveEffect
. (Join-Path $PSScriptRoot 'Setup.ps1') -Action Check
$script:OriginalColorBaselineHash='8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d'
$script:OriginalColorPreviousDiagnosticHash='41953c54e46417a88670a9e91b96a8e87198c2fa66174bdf6d810d834b175d75'
$script:OriginalColorPredicationHash='9da458986e1a7f0a9a45f979b08b04017ef2f1f2b6c384926b89ecc05d27638b'
function Test-OriginalColorKnownSource([string]$Hash) { return ($Hash -cin @($script:OriginalColorBaselineHash,$script:OriginalColorPreviousDiagnosticHash,$script:OriginalColorPredicationHash)) }

function Get-OriginalColorJsonHash($Value) {
    # PowerShell 7 parses ISO dates as DateTime and may normalize fractional
    # zeros; 5.1 keeps strings. Normalize once before hashing so a JSON reload
    # within either supported runtime cannot create a false state conflict.
    $normalized=($Value | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($normalized | ConvertTo-Json -Depth 12 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Copy-OriginalColorObject($Value) { return ($Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }
function Get-OriginalColorSnapshot($Paths) {
    $map=Get-ProtectedSnapshot $Paths
    foreach ($path in (@(Get-OwnedPaths $Paths)+@($Paths.State))) {
        Assert-NoReparse $path
        $map[(Full-Path $path)]=$null
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('A directory occupies a controlled file path: '+$path) }
            $map[(Full-Path $path)]=Get-Hash $path
        }
    }
    return $map
}
function Assert-OriginalColorSnapshot($Paths,$Before) {
    $after=Get-OriginalColorSnapshot $Paths
    if ($Before.Count -ne $after.Count) { throw 'Files changed while preparing the original-color trial. No new trial write is allowed.' }
    foreach ($path in $Before.Keys) {
        if (-not $after.ContainsKey($path) -or $after[$path] -cne $Before[$path]) { throw ('Files changed while preparing the original-color trial: '+$path) }
    }
}
function Get-OriginalColorTargets($Paths) {
    $primary=Join-Path $Paths.Plugins 'MatheusNR030.asi'
    Assert-NoReparse $primary
    if (-not (Test-Path -LiteralPath $primary -PathType Leaf)) { throw ('Existing primary add-on ASI is required: '+$primary) }
    $targets=@($primary);$shadow=Join-Path $Paths.OldPlugins 'MatheusNR030.asi'
    Assert-NoReparse $shadow
    if (Test-Path -LiteralPath $shadow) {
        if (-not (Test-Path -LiteralPath $shadow -PathType Leaf)) { throw 'A directory occupies the overwrite ASI path.' }
        $targets += $shadow
    }
    return $targets
}
function Get-OriginalColorEffectTargets($Paths) {
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        $path=Join-Path $folder 'MatheusNR030.ini';Assert-NoReparse $path
        if (-not (Test-Path -LiteralPath $path)) {
            if (Same-Path $folder $Paths.Plugins) { throw ('Existing primary INI is required: '+$path) }
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('INI path is not a file: '+$path) }
        $path
    }
}
function Get-OriginalColorEffect([string]$Text) {
    if ([regex]::Matches($Text,'(?im)^\s*\[MatheusNR030\]\s*(?:[;#][^\r\n]*)?\r?$').Count -ne 1) { throw 'Exactly one [MatheusNR030] section is required.' }
    $value=Read-IniValue $Text 'MatheusNR030' 'EffectPercent'
    $inside=$false;$raw=$null
    foreach ($line in [regex]::Split($Text,'\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]') { $inside=($matches[1] -ieq 'MatheusNR030');continue }
        if ($inside -and $line -match '^\s*EffectPercent\s*=\s*(.*)$') { $raw=$matches[1].Trim() }
    }
    [pscustomobject]@{Present=($null -ne $value);Value=$value;NativeZero=($null -ne $raw -and $raw -ceq '0')}
}
function Test-OriginalColorIniNativeReady([string]$Path,[string]$Text) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) { return $false }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf -and
        $Text -match '^\s*\[MatheusNR030\]') { return $false }
    return $true
}
function Set-OriginalColorEffectText([string]$Text,[bool]$Present,[AllowNull()][string]$Value) {
    $setting=Get-OriginalColorEffect $Text
    if ($setting.Present -eq $Present -and (-not $Present -or ($setting.Value -ceq $Value -and ($Value -cne '0' -or $setting.NativeZero)))) { return $Text }
    $newline="`r`n";if ($Text.Contains("`n") -and -not $Text.Contains("`r`n")) { $newline="`n" }
    $inside=$false;$result=New-Object Text.StringBuilder
    foreach ($match in [regex]::Matches($Text,'[^\r\n]*(?:\r\n|\n|\r|$)')) {
        if (-not $match.Length) { continue }
        $line=$match.Value;$body=$line.TrimEnd([char[]]"`r`n");$ending=$line.Substring($body.Length)
        if ($body -match '^\s*\[([^\]]+)\]') {
            $inside=($matches[1] -ieq 'MatheusNR030')
            if ($inside -and $Present -and -not $setting.Present) {
                if (-not $ending) { $ending=$newline }
                $null=$result.Append($body+$ending+'EffectPercent='+$Value+$newline);continue
            }
        } elseif ($inside -and $body -match '^(\s*EffectPercent\s*=\s*)([^;#]*?)(\s*(?:[;#].*)?)$') {
            if ($Present) { $null=$result.Append($matches[1]+$Value+$ending) }
            continue
        }
        $null=$result.Append($line)
    }
    return $result.ToString()
}
function Write-OriginalColorIni([string]$Source,[string]$Destination,[string]$Text) {
    $bytes=[IO.File]::ReadAllBytes($Source)
    $hasBom=($bytes.Length -ge 2 -and (($bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) -or ($bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff))) -or
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)
    # Native profile APIs reliably recognize UTF-16LE. Retain plain ASCII /
    # UTF-8 without a BOM; normalize Unicode/BOM forms to UTF-16LE when edited.
    # The exact original byte stream remains in its verified backup.
    $encoding=New-Object Text.UTF8Encoding($false)
    if ($hasBom) { $encoding=[Text.Encoding]::Unicode }
    [IO.File]::WriteAllText($Destination,$Text,$encoding)
}
function Read-OriginalColorEffects($Paths,$Trial) {
    $property=$Trial.PSObject.Properties['EffectFiles']
    if ($null -eq $property) { return @() }
    $records=@($property.Value);$targets=@(Get-OriginalColorEffectTargets $Paths);$seen=@{}
    if ($records.Count -ne $targets.Count) { throw 'Effect INI inventory changed after trial application.' }
    $effectFolder=Get-Value $Trial 'EffectBackupFolder'
    if ($null -eq $effectFolder) { $effectFolder=$Trial.BackupFolder }
    $effectFolder=Full-Path ([string]$effectFolder);Assert-NoReparse $effectFolder
    if (-not (Same-Path (Split-Path -Parent $effectFolder) $Paths.Backup) -or ([IO.Path]::GetFileName($effectFolder) -notmatch '^original-color-apply-')) { throw 'Effect backup folder is outside its owned backup root.' }
    for ($index=0;$index -lt $records.Count;$index++) {
        $record=$records[$index];$path=Full-Path ([string](Get-Value $record 'Path'))
        if (-not @($targets | Where-Object { Same-Path $_ $path }).Count -or $seen.ContainsKey($path)) { throw 'Unowned or duplicate Effect INI path.' }
        $seen[$path]=$true;$backup=Join-Path $effectFolder ('original-effect-'+$index+'.ini')
        if (-not (Same-Path ([string](Get-Value $record 'Backup')) $backup) -or [string](Get-Value $record 'BeforeHash') -notmatch '^[0-9a-f]{64}$' -or
            [string](Get-Value $record 'InstalledHash') -notmatch '^[0-9a-f]{64}$' -or (Get-Value $record 'EffectPresent') -isnot [bool]) { throw 'Invalid original Effect INI backup record.' }
        Assert-NoReparse $backup
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $record.BeforeHash) { throw 'Original Effect INI backup is missing or changed.' }
        $original=Get-OriginalColorEffect ([IO.File]::ReadAllText($backup))
        if ($original.Present -ne $record.EffectPresent -or $original.Value -cne (Get-Value $record 'EffectValue')) { throw 'Original Effect value does not match its backup.' }
        $null=Get-OriginalColorEffect ([IO.File]::ReadAllText($path))
    }
    return $records
}
function Assert-OriginalColorApplySettings($Paths) {
    $issues=New-Object 'System.Collections.Generic.List[string]'
    foreach ($definition in @(
        [pscustomobject]@{Name='MatheusNR030.ini';Section='MatheusNR030';Pairs=@(@('Enabled','1'),@('ScalePercent','85'))},
        [pscustomobject]@{Name='dlssnr_on_amd.ini';Section='DlssNrOnAmd';Pairs=@(@('Enabled','1'),@('PreUpscale','1'),@('Async','0'))}
    )) {
        foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
            $path=Join-Path $folder $definition.Name;Assert-NoReparse $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                if (Same-Path $folder $Paths.Plugins) { throw ('Existing primary INI is required: '+$path) }
                continue
            }
            $text=[IO.File]::ReadAllText($path)
            foreach ($pair in $definition.Pairs) {
                if ((Read-IniValue $text $definition.Section $pair[0]) -cne $pair[1]) {
                    $issues.Add('['+$definition.Section+'] '+$pair[0]+'='+$pair[1]+' required in '+$path)
                }
            }
        }
    }
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        $path=Join-Path $folder 'dlssnr_on_amd.asi';Assert-NoReparse $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if (Same-Path $folder $Paths.Plugins) { throw ('The existing pinned base NR ASI is required: '+$path) }
            continue
        }
        if ((Get-Hash $path) -cne $script:ExpectedNrHash) { throw ('Pinned base NR hash mismatch: '+$path) }
    }
    foreach ($path in @(Get-OriginalColorEffectTargets $Paths)) { $null=Get-OriginalColorEffect ([IO.File]::ReadAllText($path)) }
    if ($issues.Count) { throw ('Trial requires compatible unchanged NR settings: '+($issues -join '; ')+'. No files were changed.') }
    # Do not call the historical 4X-only Assert-Base gate. Only the add-on
    # EffectPercent setting is controlled; NR, OptiScaler and XeFG stay intact.
}
function Read-OriginalColorAddonState($Paths) {
    Assert-NoReparse $Paths.State
    if ((Test-Path -LiteralPath $Paths.State) -and -not (Test-Path -LiteralPath $Paths.State -PathType Leaf)) {
        throw ('A directory occupies the add-on state path: '+$Paths.State)
    }
    return Read-AddonState $Paths
}
function Test-OriginalColorStateExisted($Trial) {
    $property=$Trial.PSObject.Properties['OriginalStateExisted']
    # The first diagnostic package always required an existing state file.
    if ($null -eq $property) { return $true }
    if ($property.Value -isnot [bool]) { throw 'Invalid OriginalStateExisted trial flag.' }
    return $property.Value
}
function New-OriginalColorObservedState($Paths) {
    # This object describes files verified now; it is never written as a
    # historical installation record or used to fabricate a previous backup.
    [pscustomobject]@{
        SchemaVersion=1;AddonName='MatheusNR030';PluginFolder=$Paths.Plugins
        RecordPurpose='OriginalColorDiagnosticTrial';OwnershipBasis='CurrentFilesVerifiedAtTrialApply'
        Files=@(
            [pscustomobject]@{Name='MatheusNR030.asi';InstalledHash=(Get-Hash (Join-Path $Paths.Plugins 'MatheusNR030.asi'))},
            [pscustomobject]@{Name='MatheusNR030.ini';InstalledHash=(Get-Hash (Join-Path $Paths.Plugins 'MatheusNR030.ini'))}
        )
        OwnsBaseNr=$false;OwnsOptiScaler=$false;OwnsXeFG=$false;RuntimeVerified=$false
    }
}
function Read-OriginalColorTrial($Paths,$State) {
    $trial=Get-Value $State 'OriginalColorTrial'
    if ($null -eq $trial) { return $null }
    if ((Get-Value $trial 'SchemaVersion') -ne 1 -or -not (Same-Path ([string](Get-Value $trial 'Root')) $Paths.Root) -or
        -not (Test-OriginalColorKnownSource ([string](Get-Value $trial 'BaselineHash'))) -or
        [string](Get-Value $trial 'TargetHash') -notmatch '^[0-9a-f]{64}$') { throw 'Invalid original-color trial record.' }
    $folder=Full-Path ([string](Get-Value $trial 'BackupFolder'));Assert-NoReparse $folder
    if (-not (Same-Path (Split-Path -Parent $folder) $Paths.Backup) -or
        ([IO.Path]::GetFileName($folder) -notmatch '^original-color-apply-')) { throw 'Trial backup path is outside its owned backup folder.' }
    $stateBackup=Join-Path $folder 'original-state.json'
    if (Test-OriginalColorStateExisted $trial) {
        if (-not (Same-Path ([string](Get-Value $trial 'OriginalStateBackup')) $stateBackup) -or
            [string](Get-Value $trial 'OriginalStateHash') -notmatch '^[0-9a-f]{64}$') { throw 'Invalid original state backup record.' }
        Assert-NoReparse $stateBackup
        if (-not (Test-Path -LiteralPath $stateBackup -PathType Leaf) -or (Get-Hash $stateBackup) -cne $trial.OriginalStateHash) { throw 'Original state backup is missing or changed.' }
        $original=Read-AddonState ([pscustomobject]@{State=$stateBackup;Plugins=$Paths.Plugins})
        if ($null -ne (Get-Value $original 'OriginalColorTrial') -or
            (@($original.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0].InstalledHash -cne $trial.BaselineHash)) { throw 'Original add-on state is inconsistent with the baseline.' }
    } elseif ($null -ne (Get-Value $trial 'OriginalStateBackup') -or $null -ne (Get-Value $trial 'OriginalStateHash')) {
        throw 'An originally absent state must not contain a fabricated original backup.'
    }
    $core=Copy-OriginalColorObject $State;$core.PSObject.Properties.Remove('OriginalColorTrial')
    if ((Get-OriginalColorJsonHash $core) -cne (Get-Value $trial 'StateCoreHash')) { throw 'Add-on state changed after the trial was applied.' }
    $targets=@(Get-OriginalColorTargets $Paths);$records=@(Get-Value $trial 'Files')
    if ($records.Count -ne $targets.Count) { throw 'Trial ASI inventory changed after application.' }
    $seen=@{}
    for ($index=0;$index -lt $records.Count;$index++) {
        $record=$records[$index];$path=Full-Path ([string](Get-Value $record 'Path'))
        if (-not @($targets | Where-Object { Same-Path $_ $path }).Count -or $seen.ContainsKey($path)) { throw 'Unowned or duplicate trial ASI path.' }
        $seen[$path]=$true;$backup=Join-Path $folder ('original-'+$index+'.asi')
        if (-not (Same-Path ([string](Get-Value $record 'Backup')) $backup) -or -not (Test-OriginalColorKnownSource ([string](Get-Value $record 'Sha256')))) { throw 'Invalid original ASI backup record.' }
        Assert-NoReparse $backup
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $record.Sha256) { throw 'Original ASI backup is missing or changed.' }
        if ((Get-Hash $path) -cne $trial.TargetHash) { throw ('Trial ASI is missing or changed: '+$path) }
    }
    if ((@($State.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0].InstalledHash) -cne $trial.TargetHash) { throw 'Trial ASI ownership is inconsistent.' }
    $null=@(Read-OriginalColorEffects $Paths $trial)
    return $trial
}
function Show-OriginalColorStatus($Paths) {
    $state=Read-OriginalColorAddonState $Paths
    if ($null -eq $state) {
        Write-Host ('No original-color trial record exists at '+$Paths.State+'. Existing files can be verified when Apply is selected. No files were changed.');return
    }
    Assert-OwnedFiles $Paths $state -AllowModifiedIni
    $trial=Read-OriginalColorTrial $Paths $state
    if ($null -eq $trial) { Write-Host 'Original-color diagnostic trial is not active.' }
    else { Write-Host ('Original-color diagnostic ASI is installed; SHA-256='+$trial.TargetHash+'. Runtime and visual quality are unverified.') }
    if ($null -ne $trial -and (Get-Value $trial 'PreserveEffectApplied') -eq $true) {
        Write-Host 'This repair preserved current INI settings. Earlier trial backups, if present, remain available for Restore.'
    } else { Write-Host 'This control changes add-on ASIs and sets add-on EffectPercent=0 with a backup. Base NR, OptiScaler and XeFG are preserved.' }
}
function Invoke-OriginalColorControl($Paths,[ValidateSet('Apply','Restore')][string]$Mode,[scriptblock]$BeforeOperation=$null,[switch]$PreserveEffect) {
    Assert-Stopped;Assert-NoReparse $Paths.Root;Assert-NoReparse $Paths.Backup
    $state=Read-OriginalColorAddonState $Paths
    $originalStateExisted=($null -ne $state)
    $trial=$null
    if ($originalStateExisted) {
        Assert-OwnedFiles $Paths $state -AllowModifiedIni
        $trial=Read-OriginalColorTrial $Paths $state
    }
    if ($Mode -ceq 'Restore' -and $null -eq $trial) { throw 'No active original-color trial exists. No files were changed.' }
    $manifest=$null
    if ($Mode -ceq 'Apply') {
        $manifest=Get-VerifiedManifest
        $payload=Join-Path (Join-Path $script:PackageRoot 'payload') 'MatheusNR030.asi';$targetHash=Get-Hash $payload
        if ($targetHash -ceq $script:OriginalColorBaselineHash) { throw 'The diagnostic payload must differ from the exact 0.2.4 baseline.' }
        $targets=@(Get-OriginalColorTargets $Paths)
        Assert-OriginalColorApplySettings $Paths
        if ($null -ne $trial) {
            if ($trial.TargetHash -ceq $targetHash) {
                if ($PreserveEffect) { Write-Host 'The same repair binary is already installed. Current NR/effect/OptiScaler/XeFG settings and original backups are preserved. Gameplay result is not verified by installation.';return }
                foreach ($path in @(Get-OriginalColorEffectTargets $Paths)) {
                    $effect=Get-OriginalColorEffect ([IO.File]::ReadAllText($path))
                    if (-not $effect.NativeZero -or -not (Test-OriginalColorIniNativeReady $path ([IO.File]::ReadAllText($path)))) { throw ('EffectPercent changed after the trial was applied: '+$path+'. Run Restore, then Apply to set Effect 0 while retaining the correct original backup.') }
                }
                Write-Host 'The same diagnostic trial is already installed with EffectPercent=0. Original backups are preserved.';return
            }
            if (-not (Test-OriginalColorKnownSource $trial.TargetHash)) { throw 'The active trial ASI is not a supported exact upgrade source. Its original backups were preserved.' }
        } else {
            foreach ($path in $targets) {
                if (-not (Test-OriginalColorKnownSource (Get-Hash $path))) { throw ('Exact supported 0.2.4 or original-color ASI is required: '+$path) }
            }
            if (-not $originalStateExisted) { $state=New-OriginalColorObservedState $Paths }
        }
    }
    $before=Get-ProtectedSnapshot $Paths;$allBefore=Get-OriginalColorSnapshot $Paths
    $folder=New-BackupFolder $Paths ('original-color-'+$Mode.ToLowerInvariant())
    $operations=New-Object 'System.Collections.Generic.List[object]'
    $sourceHashes=@{}
    if ($Mode -ceq 'Apply') {
        $originalState=$null;$originalStateHash=$null;$recordFolder=$folder
        if ($null -ne $trial) {
            $originalStateExisted=Test-OriginalColorStateExisted $trial
            $originalState=$trial.OriginalStateBackup;$originalStateHash=$trial.OriginalStateHash
            $recordFolder=$trial.BackupFolder;$baselineHash=$trial.BaselineHash
            $records=@(Copy-OriginalColorObject @($trial.Files))
        } else {
            if ($originalStateExisted) {
                $originalState=Join-Path $folder 'original-state.json';Copy-Verified $Paths.State $originalState
                $originalStateHash=Get-Hash $originalState
            }
            $records=@();$index=0
            foreach ($path in @(Get-OriginalColorTargets $Paths)) {
                $backup=Join-Path $folder ('original-'+$index+'.asi');Copy-Verified $path $backup
                $records += [pscustomobject]@{Path=(Full-Path $path);Backup=$backup;Sha256=(Get-Hash $backup)};$index++
            }
            $baselineHash=$records[0].Sha256
        }
        $staged=Join-Path $folder 'diagnostic.asi';Copy-Verified $payload $staged
        if ((Get-Hash $staged) -cne $targetHash) { throw 'Diagnostic payload changed while staging.' }
        $sourceHashes[$staged]=$targetHash
        $effectRecords=@();$effectStages=@{};$effectIndex=0;$effectFolder=$folder
        $priorEffects=@()
        if ($null -ne $trial) {
            $priorEffects=@(Read-OriginalColorEffects $Paths $trial)
            if ($priorEffects.Count) {
                $effectFolder=Get-Value $trial 'EffectBackupFolder'
                if ($null -eq $effectFolder) { $effectFolder=$trial.BackupFolder }
            }
        }
        if ($PreserveEffect) {
            if ($priorEffects.Count) { $effectRecords=@(Copy-OriginalColorObject $priorEffects) }
        } else { foreach ($path in @(Get-OriginalColorEffectTargets $Paths)) {
            if ($priorEffects.Count) {
                $effectRecord=Copy-OriginalColorObject (@($priorEffects | Where-Object { Same-Path $_.Path $path })[0])
            } else {
                $backup=Join-Path $folder ('original-effect-'+$effectIndex+'.ini');Copy-Verified $path $backup
                $originalEffect=Get-OriginalColorEffect ([IO.File]::ReadAllText($backup))
                $effectRecord=[pscustomobject]@{Path=(Full-Path $path);Backup=$backup;BeforeHash=(Get-Hash $backup);InstalledHash=$null;EffectPresent=$originalEffect.Present;EffectValue=$originalEffect.Value}
            }
            $text=[IO.File]::ReadAllText($path);$effect=Get-OriginalColorEffect $text
            $effectStage=Join-Path $folder ('prepared-effect-'+$effectIndex+'.ini')
            if ($effect.NativeZero -and (Test-OriginalColorIniNativeReady $path $text)) { Copy-Verified $path $effectStage }
            else { Write-OriginalColorIni $path $effectStage (Set-OriginalColorEffectText $text $true '0') }
            $sourceHashes[$effectStage]=Get-Hash $effectStage;$effectStages[$path]=$effectStage
            $effectRecord.InstalledHash=$sourceHashes[$effectStage];$effectRecords += $effectRecord
            $effectIndex++
        } }
        $newState=Copy-OriginalColorObject $state
        (@($newState.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0]).InstalledHash=$targetHash
        $iniInstalledHash=Get-Hash (Join-Path $Paths.Plugins 'MatheusNR030.ini')
        if (-not $PreserveEffect) { $iniInstalledHash=$effectRecords[0].InstalledHash }
        (@($newState.Files | Where-Object { $_.Name -ceq 'MatheusNR030.ini' })[0]).InstalledHash=$iniInstalledHash
        $newState.PSObject.Properties.Remove('OriginalColorTrial')
        foreach ($entry in @(@('AddonVersion',$manifest.addon_version),@('SourceCommit',$manifest.source_commit),@('BuildRunId',$manifest.build_run_id),@('InstalledUtc',[DateTime]::UtcNow.ToString('o')),@('ManifestSha256',(Get-Hash (Join-Path $script:PackageRoot 'package-manifest.json'))))) {
            $newState | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
        }
        $newTrial=[pscustomobject]@{SchemaVersion=1;Root=$Paths.Root;BaselineHash=$baselineHash;TargetHash=$targetHash;BackupFolder=$recordFolder;OriginalStateExisted=$originalStateExisted;OriginalStateBackup=$originalState;OriginalStateHash=$originalStateHash;StateCoreHash=(Get-OriginalColorJsonHash $newState);Files=$records;PreserveEffectApplied=[bool]$PreserveEffect}
        if ($effectRecords.Count) {
            $newTrial | Add-Member -NotePropertyName 'EffectFiles' -NotePropertyValue $effectRecords
            $newTrial | Add-Member -NotePropertyName 'EffectBackupFolder' -NotePropertyValue $effectFolder
        }
        $newState | Add-Member -NotePropertyName 'OriginalColorTrial' -NotePropertyValue $newTrial -Force
        foreach ($record in $records) { $operations.Add([pscustomobject]@{Path=$record.Path;Action='Copy';Source=$staged}) }
        if (-not $PreserveEffect) { foreach ($record in $effectRecords) {
            if ($record.InstalledHash -cne (Get-Hash $record.Path)) { $operations.Add([pscustomobject]@{Path=$record.Path;Action='Copy';Source=$effectStages[$record.Path]}) }
        } }
        $prepared=Join-Path $folder 'prepared-state.json';Write-Json $prepared $newState
        $sourceHashes[$prepared]=Get-Hash $prepared
    } else {
        $restoreIndex=0
        foreach ($record in $trial.Files) {
            $staged=Join-Path $folder ('restore-original-'+$restoreIndex+'.asi')
            Copy-Verified $record.Backup $staged
            if ((Get-Hash $staged) -cne $record.Sha256) { throw 'Original ASI backup changed while staging restore.' }
            $sourceHashes[$staged]=$record.Sha256
            $operations.Add([pscustomobject]@{Path=$record.Path;Action='Copy';Source=$staged})
            $restoreIndex++
        }
        $effectIndex=0
        foreach ($record in @(Read-OriginalColorEffects $Paths $trial)) {
            $current=[IO.File]::ReadAllText($record.Path);$original=[IO.File]::ReadAllText($record.Backup)
            $effectStage=Join-Path $folder ('restore-effect-'+$effectIndex+'.ini')
            $currentWithoutEffect=Set-OriginalColorEffectText $current $false $null
            $originalWithoutEffect=Set-OriginalColorEffectText $original $false $null
            if ($currentWithoutEffect -ceq $originalWithoutEffect) {
                Copy-Verified $record.Backup $effectStage
                if ((Get-Hash $effectStage) -cne $record.BeforeHash) { throw 'Original Effect INI changed while staging restore.' }
            } else {
                $restored=Set-OriginalColorEffectText $current $record.EffectPresent $record.EffectValue
                if ($restored -ceq $current) { Copy-Verified $record.Path $effectStage }
                else { Write-OriginalColorIni $record.Path $effectStage $restored }
            }
            $sourceHashes[$effectStage]=Get-Hash $effectStage
            if ($sourceHashes[$effectStage] -cne (Get-Hash $record.Path)) { $operations.Add([pscustomobject]@{Path=$record.Path;Action='Copy';Source=$effectStage}) }
            $effectIndex++
        }
        $prepared=$null
        if (Test-OriginalColorStateExisted $trial) {
            $prepared=Join-Path $folder 'prepared-state.json';Copy-Verified $trial.OriginalStateBackup $prepared
            if ((Get-Hash $prepared) -cne $trial.OriginalStateHash) { throw 'Original state backup changed while staging restore.' }
            $sourceHashes[$prepared]=$trial.OriginalStateHash
        }
    }
    if ($null -eq $prepared) { $operations.Add([pscustomobject]@{Path=$Paths.State;Action='Delete';Source=$null}) }
    else { $operations.Add([pscustomobject]@{Path=$Paths.State;Action='Copy';Source=$prepared}) }
    # Preparation detects changes before entering the transaction. The first
    # operation gate also detects edits after transaction backups were taken,
    # so a pre-write conflict never rolls old bytes over somebody else's edit.
    Assert-OriginalColorSnapshot $Paths $allBefore
    $gate={ param($index)
        if ($null -ne $BeforeOperation) { & $BeforeOperation $index }
        if ($index -eq 0) { Assert-OriginalColorSnapshot $Paths $allBefore }
        $operation=$operations[$index];$destination=Full-Path $operation.Path;Assert-NoReparse $destination
        $currentHash=$null
        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw ('Trial destination changed before write: '+$destination) }
            $currentHash=Get-Hash $destination
        }
        if (-not $allBefore.ContainsKey($destination) -or $currentHash -cne $allBefore[$destination]) { throw ('Trial destination changed before write: '+$destination) }
        if ($operation.Action -ceq 'Copy') {
            $source=$operation.Source;Assert-NoReparse $source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
                -not $sourceHashes.ContainsKey($source) -or (Get-Hash $source) -cne $sourceHashes[$source]) {
                throw ('Staged trial source changed before copy: '+$source)
            }
        }
    }.GetNewClosure()
    Invoke-OwnTransaction $Paths @($operations.ToArray()) $folder $before $gate
    if ($Mode -ceq 'Apply') {
        if ($PreserveEffect) { Write-Host 'NR add-on repair installed; current NR/effect/OptiScaler/XeFG settings preserved. Gameplay result not verified by installation.' }
        else { Write-Host 'Diagnostic ASI installed and add-on EffectPercent=0 prepared with verified original backups. Base NR, ScalePercent=85, OptiScaler and XeFG were preserved. This is not a verified visual fix.' }
    }
    else {
        if (Test-OriginalColorStateExisted $trial) { Write-Host 'Exact original add-on ASIs and ownership record restored. Original Effect settings restored; other later INI edits were preserved.' }
        else { Write-Host 'Exact original add-on ASIs restored and trial-created ownership record removed. Original Effect settings restored; other later INI edits were preserved.' }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $originalColorRoot
        if ($originalColorAction -ceq 'Status') { Show-OriginalColorStatus $paths }
        else { Invoke-OriginalColorControl $paths $originalColorAction -PreserveEffect:$originalColorPreserveEffect }
        exit 0
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
