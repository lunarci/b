#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Apply','Restore','Status')][string]$Action='Status',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2'
)
$originalColorAction=$Action;$originalColorRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Setup.ps1') -Action Check
$script:OriginalColorBaselineHash='8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d'

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
function Assert-OriginalColorApplySettings($Paths) {
    foreach ($definition in @(
        [pscustomobject]@{Name='MatheusNR030.ini';Section='MatheusNR030';Pairs=@(@('Enabled','1'),@('ScalePercent','85'),@('EffectPercent','0'))},
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
                    throw ('Trial requires ['+$definition.Section+'] '+$pair[0]+'='+$pair[1]+' in '+$path+'. Existing settings were not changed.')
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
    # Deliberately do not call Assert-Base: its historical 4X gate is not a
    # requirement of this trial. No OptiScaler, XeFG or INI value is written.
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
            [pscustomobject]@{Name='MatheusNR030.asi';InstalledHash=$script:OriginalColorBaselineHash},
            [pscustomobject]@{Name='MatheusNR030.ini';InstalledHash=(Get-Hash (Join-Path $Paths.Plugins 'MatheusNR030.ini'))}
        )
        OwnsBaseNr=$false;OwnsOptiScaler=$false;OwnsXeFG=$false;RuntimeVerified=$false
    }
}
function Read-OriginalColorTrial($Paths,$State) {
    $trial=Get-Value $State 'OriginalColorTrial'
    if ($null -eq $trial) { return $null }
    if ((Get-Value $trial 'SchemaVersion') -ne 1 -or -not (Same-Path ([string](Get-Value $trial 'Root')) $Paths.Root) -or
        (Get-Value $trial 'BaselineHash') -cne $script:OriginalColorBaselineHash -or
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
            (@($original.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0].InstalledHash -cne $script:OriginalColorBaselineHash)) { throw 'Original add-on state is inconsistent with the baseline.' }
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
        if (-not (Same-Path ([string](Get-Value $record 'Backup')) $backup) -or (Get-Value $record 'Sha256') -cne $script:OriginalColorBaselineHash) { throw 'Invalid original ASI backup record.' }
        Assert-NoReparse $backup
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $script:OriginalColorBaselineHash) { throw 'Original ASI backup is missing or changed.' }
        if ((Get-Hash $path) -cne $trial.TargetHash) { throw ('Trial ASI is missing or changed: '+$path) }
    }
    if ((@($State.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0].InstalledHash) -cne $trial.TargetHash) { throw 'Trial ASI ownership is inconsistent.' }
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
    Write-Host 'This control changes add-on ASI files only. INI settings, base NR, OptiScaler and XeFG are preserved.'
}
function Invoke-OriginalColorControl($Paths,[ValidateSet('Apply','Restore')][string]$Mode,[scriptblock]$BeforeOperation=$null) {
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
            if ($trial.TargetHash -cne $targetHash) { throw 'A different trial is already active. Restore it before applying this package.' }
            Write-Host 'The same diagnostic trial is already installed. Original backups and all settings are preserved.';return
        }
        foreach ($path in $targets) {
            if ((Get-Hash $path) -cne $script:OriginalColorBaselineHash) { throw ('Exact 0.2.4 baseline ASI is required: '+$path) }
        }
        if (-not $originalStateExisted) {
            $state=New-OriginalColorObservedState $Paths
            Assert-OwnedFiles $Paths $state -AllowModifiedIni
        }
    }
    $before=Get-ProtectedSnapshot $Paths;$allBefore=Get-OriginalColorSnapshot $Paths
    $folder=New-BackupFolder $Paths ('original-color-'+$Mode.ToLowerInvariant())
    $operations=New-Object 'System.Collections.Generic.List[object]'
    $sourceHashes=@{}
    if ($Mode -ceq 'Apply') {
        $originalState=$null;$originalStateHash=$null
        if ($originalStateExisted) {
            $originalState=Join-Path $folder 'original-state.json';Copy-Verified $Paths.State $originalState
            $originalStateHash=Get-Hash $originalState
        }
        $records=@();$index=0
        foreach ($path in @(Get-OriginalColorTargets $Paths)) {
            $backup=Join-Path $folder ('original-'+$index+'.asi');Copy-Verified $path $backup
            $records += [pscustomobject]@{Path=(Full-Path $path);Backup=$backup;Sha256=(Get-Hash $backup)};$index++
        }
        $staged=Join-Path $folder 'diagnostic.asi';Copy-Verified $payload $staged
        if ((Get-Hash $staged) -cne $targetHash) { throw 'Diagnostic payload changed while staging.' }
        $sourceHashes[$staged]=$targetHash
        $newState=Copy-OriginalColorObject $state
        (@($newState.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0]).InstalledHash=$targetHash
        foreach ($entry in @(@('AddonVersion',$manifest.addon_version),@('SourceCommit',$manifest.source_commit),@('BuildRunId',$manifest.build_run_id),@('InstalledUtc',[DateTime]::UtcNow.ToString('o')),@('ManifestSha256',(Get-Hash (Join-Path $script:PackageRoot 'package-manifest.json'))))) {
            $newState | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
        }
        $newTrial=[pscustomobject]@{SchemaVersion=1;Root=$Paths.Root;BaselineHash=$script:OriginalColorBaselineHash;TargetHash=$targetHash;BackupFolder=$folder;OriginalStateExisted=$originalStateExisted;OriginalStateBackup=$originalState;OriginalStateHash=$originalStateHash;StateCoreHash=(Get-OriginalColorJsonHash $newState);Files=$records}
        $newState | Add-Member -NotePropertyName 'OriginalColorTrial' -NotePropertyValue $newTrial
        foreach ($record in $records) { $operations.Add([pscustomobject]@{Path=$record.Path;Action='Copy';Source=$staged}) }
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
    if ($Mode -ceq 'Apply') { Write-Host 'Diagnostic ASI installed. Only existing add-on ASIs and their ownership record changed. This is not a verified visual fix.' }
    else {
        if (Test-OriginalColorStateExisted $trial) { Write-Host 'Exact original add-on ASIs and ownership record restored. All INI files, including later user edits, were preserved.' }
        else { Write-Host 'Exact original add-on ASIs restored and trial-created ownership record removed. All INI files, including later user edits, were preserved.' }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $originalColorRoot
        if ($originalColorAction -ceq 'Status') { Show-OriginalColorStatus $paths }
        else { Invoke-OriginalColorControl $paths $originalColorAction }
        exit 0
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
