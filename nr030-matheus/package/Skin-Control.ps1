#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('ApplySkin0','RestoreSkin','CheckSkin')][string]$Action='CheckSkin',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2'
)
$skinRequestedAction=$Action;$skinRequestedRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Complete-Setup.ps1') -Action Check
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# This control experiment is restricted to the reviewed C7 NR and 0.2.4 add-on.
# There is no command-line hash override and no binary download/replacement.
$script:SkinNrHash='c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de'
$script:SkinAddonHash='8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d'

function Get-SkinPaths($Paths) {
    $folder=Join-Path $Paths.Root 'Matheus_NR030_Skin_Backup'
    [pscustomobject]@{Folder=$folder;State=(Join-Path $folder 'active-install.json')}
}
function Get-SkinIniTargets($Paths) {
    $primary=Join-Path $Paths.Plugins 'dlssnr_on_amd.ini'
    Assert-NoReparse $primary
    if (-not (Test-Path -LiteralPath $primary -PathType Leaf)) { throw ('Existing primary NR INI is required: '+$primary) }
    $primary
    $secondary=Join-Path $Paths.OldPlugins 'dlssnr_on_amd.ini';Assert-NoReparse $secondary
    if (Test-Path -LiteralPath $secondary) {
        if (-not (Test-Path -LiteralPath $secondary -PathType Leaf)) { throw ('NR INI path is not a file: '+$secondary) }
        $secondary
    }
}
function Assert-SkinBinaries($Paths) {
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        foreach ($item in @(@('dlssnr_on_amd.asi',$script:SkinNrHash),@('MatheusNR030.asi',$script:SkinAddonHash))) {
            $path=Join-Path $folder $item[0];Assert-NoReparse $path
            if (-not (Test-Path -LiteralPath $path) -and (Same-Path $folder $Paths.OldPlugins)) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Hash $path) -cne $item[1]) {
                throw ('Skin control requires the exact C7 NR and 0.2.4 add-on binaries. Hash mismatch or missing file: '+$path)
            }
        }
    }
}
function Get-SkinSetting([string]$Text,[string]$Key,[int]$Default) {
    $value=Read-IniValue $Text 'DlssNrOnAmd' $Key
    if ($null -eq $value) { return [pscustomobject]@{Present=$false;Literal=$null;Value=$Default} }
    $number=0
    if ($value -notmatch '^[+-]?[0-9]+$' -or -not [int]::TryParse($value,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) {
        throw ('Unrecognized integer setting: [DlssNrOnAmd] '+$Key+'='+$value+'. No setting was changed.')
    }
    return [pscustomobject]@{Present=$true;Literal=$value;Value=$number}
}
function Get-SkinSettings([string]$Path) {
    Assert-NoReparse $Path;$text=[IO.File]::ReadAllText($Path)
    if ([regex]::Matches($text,'(?im)^\s*\[DlssNrOnAmd\]\s*(?:[;#][^\r\n]*)?\r?$').Count -ne 1) {
        throw ('Exactly one [DlssNrOnAmd] section is required: '+$Path)
    }
    $skinLiteral=Read-IniValue $text 'DlssNrOnAmd' 'SkinStructure';[single]$skinValue=-1.0
    if (-not [string]::IsNullOrEmpty($skinLiteral) -and (-not [single]::TryParse($skinLiteral,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$skinValue) -or [single]::IsNaN($skinValue) -or [single]::IsInfinity($skinValue))) {
        throw ('Unrecognized finite SkinStructure value: '+$skinLiteral+'. No setting was changed.')
    }
    [pscustomobject]@{Path=$Path;Text=$text;Skin=([pscustomobject]@{Present=($null -ne $skinLiteral);Literal=$skinLiteral;Value=$skinValue});AutoMask=(Get-SkinSetting $text 'UseAutoMask' 1);PreHistory=(Get-SkinSetting $text 'PreHistory' 0);Temporal=(Get-SkinSetting $text 'Temporal' 1)}
}
function Show-SkinSettings($Paths) {
    foreach ($path in @(Get-SkinIniTargets $Paths)) {
        $settings=Get-SkinSettings $path
        Write-Host ('Skin settings: '+$path+'; SkinStructure='+$settings.Skin.Value.ToString('R',[Globalization.CultureInfo]::InvariantCulture)+'; SkinStructurePresent='+$settings.Skin.Present+'; UseAutoMask='+$settings.AutoMask.Value+'; PreHistory='+$settings.PreHistory.Value+'; Temporal='+$settings.Temporal.Value+'; RuntimeVerified=false')
    }
}
function Read-SkinState($Paths,[string[]]$Targets) {
    $skin=Get-SkinPaths $Paths;Assert-NoReparse $skin.State
    if (-not (Test-Path -LiteralPath $skin.State)) { return $null }
    $state=Read-Json $skin.State
    if ((Get-Value $state 'SchemaVersion') -ne 1 -or (Get-Value $state 'Name') -cne 'MatheusNR030Skin' -or -not (Same-Path ([string](Get-Value $state 'Root')) $Paths.Root)) { throw 'Invalid skin-control record.' }
    $files=@(Get-Value $state 'Files');$seen=@{}
    if ($files.Count -ne $Targets.Count) { throw 'NR INI inventory changed after skin control. Restore is blocked to preserve newer files.' }
    $prefix=(Full-Path (Get-CompletePaths $Paths).Backup)+[IO.Path]::DirectorySeparatorChar
    foreach ($entry in $files) {
        $path=[string](Get-Value $entry 'Path');Assert-CompleteTarget $path $Targets
        if ($seen.ContainsKey((Full-Path $path))) { throw 'Duplicate skin-control destination.' };$seen[(Full-Path $path)]=$true
        $backup=[string](Get-Value $entry 'Backup');Assert-NoReparse $backup
        if (-not (Full-Path $backup).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [string](Get-Value $entry 'BeforeHash') -notmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $entry.BeforeHash) { throw 'Skin-control original backup is missing or changed.' }
        if ([string](Get-Value $entry 'InstalledHash') -notmatch '^[0-9a-f]{64}$' -or (Get-Hash $path) -cne $entry.InstalledHash) { throw ('NR INI changed after skin control. Preserve those edits; automatic apply/restore is blocked: '+$path) }
    }
    return $state
}
function Invoke-SkinControl($Paths,[ValidateSet('ApplySkin0','RestoreSkin')][string]$Mode,[scriptblock]$BeforeOperation=$null) {
    Assert-Stopped;Assert-SkinBinaries $Paths
    $targets=@(Get-SkinIniTargets $Paths);$settings=@($targets | ForEach-Object { Get-SkinSettings $_ })
    $skin=Get-SkinPaths $Paths;$complete=Get-CompletePaths $Paths
    Assert-NoReparse $skin.Folder;Assert-NoReparse $complete.Backup
    $oldSkin=Read-SkinState $Paths $targets;$prior=Read-CompleteState $Paths
    if ($Mode -ceq 'ApplySkin0') {
        foreach ($setting in $settings) {
            if ($setting.AutoMask.Value -ne 1) { throw ('UseAutoMask must already resolve to 1. SkinStructure=0 would not provide the reviewed masked control; no setting changed: '+$setting.Path) }
        }
        if ($null -ne $oldSkin) { Write-Host 'SkinStructure=0 is already recorded. The original backup was preserved.';Show-SkinSettings $Paths;return }
    } elseif ($null -eq $oldSkin) { throw 'No active skin-control backup exists. No setting was changed.' }
    $patched=@{}
    if ($Mode -ceq 'ApplySkin0') { foreach ($setting in $settings) { $patched[$setting.Path]=Set-CompleteIniValue $setting.Text 'DlssNrOnAmd' 'SkinStructure' '0' } }
    # Validation above performs no writes. Every destination, including both
    # ownership records, has a verified snapshot for one rollback transaction.
    $folder=New-CompleteBackup $Paths 'skin-control'
    $snapshots=@(New-CompleteSnapshots ($targets+@($complete.State,$skin.State)) $folder)
    $operations=New-Object 'System.Collections.Generic.List[object]';$newSkinFiles=@()
    foreach ($path in $targets) {
        $source=Join-Path $folder ('staged-'+$operations.Count+'.ini')
        if ($Mode -ceq 'ApplySkin0') {
            Write-Text $source $patched[$path]
            $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $path })[0]
            $newSkinFiles += [pscustomobject]@{Path=$path;Backup=$snapshot.Backup;BeforeHash=$snapshot.BeforeHash;InstalledHash=(Get-Hash $source)}
        } else { Copy-Verified @($oldSkin.Files | Where-Object { Same-Path $_.Path $path })[0].Backup $source }
        $operations.Add([pscustomobject]@{Action='Copy';Source=$source;Path=$path;InstalledHash=(Get-Hash $source)})
    }
    $records=New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $prior) { foreach ($entry in @($prior.Files)) { $records.Add($entry) } }
    foreach ($op in $operations.ToArray()) {
        $existing=@($records.ToArray() | Where-Object { Same-Path $_.Path $op.Path })
        if ($existing.Count) {
            if (-not (Test-CompleteInstalledRecord $existing[0])) {
                # Runtime/user INI tuning is valid. Preserve it as this new
                # restoration baseline; the older backup file remains intact.
                $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $op.Path })[0]
                $existing[0].Existed=$true;$existing[0].Backup=$snapshot.Backup;$existing[0].BeforeHash=$snapshot.BeforeHash
            }
            $existing[0].InstalledExists=$true;$existing[0].InstalledHash=$op.InstalledHash
        }
        else {
            $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $op.Path })[0]
            $records.Add([pscustomobject]@{Path=$op.Path;Existed=$true;Backup=$snapshot.Backup;BeforeHash=$snapshot.BeforeHash;InstalledExists=$true;InstalledHash=$op.InstalledHash})
        }
    }
    if ($null -eq $prior) { $prior=[pscustomobject]@{SchemaVersion=1;Name='MatheusNR030Complete';Root=$Paths.Root;CreatedUtc=[DateTime]::UtcNow.ToString('o');Files=@();OwnsGpuDriver=$false;OwnsOptiScalerBinary=$false;OwnsXeFgBinary=$false;RuntimeVerified=$false} }
    $prior.Files=@($records.ToArray());$completeStage=Join-Path $folder 'complete-state.json';Write-Json $completeStage $prior
    $operations.Add([pscustomobject]@{Action='Copy';Source=$completeStage;Path=$complete.State;InstalledHash=(Get-Hash $completeStage)})
    if ($Mode -ceq 'ApplySkin0') {
        $skinStage=Join-Path $folder 'skin-state.json'
        Write-Json $skinStage ([pscustomobject]@{SchemaVersion=1;Name='MatheusNR030Skin';Root=$Paths.Root;Files=$newSkinFiles;RuntimeVerified=$false})
        $operations.Add([pscustomobject]@{Action='Copy';Source=$skinStage;Path=$skin.State;InstalledHash=(Get-Hash $skinStage)})
    } else { $operations.Add([pscustomobject]@{Action='Delete';Source=$null;Path=$skin.State;InstalledHash=$null}) }
    $journal=Join-Path $folder 'transaction.json';Write-Json $journal ([pscustomobject]@{Status='prepared';Mode=$Mode;Files=$snapshots})
    Assert-Stopped;Assert-SkinBinaries $Paths
    foreach ($snapshot in $snapshots) {
        if ($snapshot.Existed) { if ((Get-Hash $snapshot.Path) -cne $snapshot.BeforeHash) { throw ('File changed during skin-control preparation: '+$snapshot.Path) } }
        elseif (Test-Path -LiteralPath $snapshot.Path) { throw ('File appeared during skin-control preparation: '+$snapshot.Path) }
    }
    try {
        $index=0
        foreach ($op in $operations.ToArray()) {
            if ($null -ne $BeforeOperation) { & $BeforeOperation $index };$index++
            Assert-NoReparse $op.Path
            if ($op.Action -ceq 'Copy') { New-Item -ItemType Directory -Path (Split-Path -Parent $op.Path) -Force | Out-Null;Copy-Verified $op.Source $op.Path }
            else { Remove-Item -LiteralPath $op.Path -Force }
        }
        $null=Read-CompleteState $Paths
        if ($Mode -ceq 'ApplySkin0') { $null=Read-SkinState $Paths $targets }
        Write-Json $journal ([pscustomobject]@{Status='completed';Mode=$Mode;Files=$snapshots})
    } catch {
        $failure=$_
        try { Restore-CompleteSnapshots $snapshots }
        catch { throw ('Skin-control rollback needs review. Keep backup '+$folder+': '+$_.Exception.Message) }
        Write-Json $journal ([pscustomobject]@{Status='rolled-back';Mode=$Mode;Error=$failure.Exception.Message;Files=$snapshots})
        throw $failure
    }
    if ($Mode -ceq 'ApplySkin0') { Write-Host 'SkinStructure=0 configured in existing NR INIs. This is a targeted control experiment; image quality is not verified.' }
    else { Write-Host 'Original NR INI bytes restored from the skin-control backup.' }
    Show-SkinSettings $Paths
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $skinRequestedRoot
        if ($skinRequestedAction -ceq 'CheckSkin') { Show-SkinSettings $paths }
        else { Invoke-SkinControl $paths $skinRequestedAction }
        exit 0
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
