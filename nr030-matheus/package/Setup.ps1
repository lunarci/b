#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Check','Remove')][string]$Action = 'Check',
    [string]$Mo2Root = 'C:\CYBERPUNK_ARK_PACK_MO2'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PackageRoot = $PSScriptRoot
$script:ExpectedNrHash = 'c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de'
$script:AddonNames = @('MatheusNR030.asi','MatheusNR030.ini')
$script:Utf8 = New-Object System.Text.UTF8Encoding($true)

function Get-Value($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Required JSON file is missing: ' + $Path) }
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
function Write-Text([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,$script:Utf8)
}
function Write-Json([string]$Path,$Value) { Write-Text $Path ($Value | ConvertTo-Json -Depth 12) }
function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Full-Path([string]$Path) { return [IO.Path]::GetFullPath($Path) }
function Same-Path([string]$A,[string]$B) { return ((Full-Path $A) -ieq (Full-Path $B)) }
function Assert-NoReparse([string]$Path) {
    $cursor = Full-Path $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse/junction path is not allowed: ' + $cursor)
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Get-Paths([string]$Root) {
    $rootPath = Full-Path $Root
    $bin = Join-Path $rootPath 'mods/ARK_OptiScaler_/Root/bin/x64'
    $backup = Join-Path $rootPath 'Matheus_NR030_Addon_Backup'
    [pscustomobject]@{
        Root=$rootPath; Bin=$bin; Plugins=(Join-Path $bin 'plugins')
        OldBin=(Join-Path $rootPath 'overwrite/Root/bin/x64')
        OldPlugins=(Join-Path $rootPath 'overwrite/Root/bin/x64/plugins')
        BaseState=(Join-Path $rootPath 'NR030_ARK_Backup/active-install.json')
        Backup=$backup; State=(Join-Path $backup 'active-install.json')
    }
}
function Read-IniValue([string]$Text,[string]$Section,[string]$Key) {
    $inside=$false; $values=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [regex]::Split($Text,'\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]') { $inside=($matches[1] -ieq $Section); continue }
        if ($inside -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*([^;#]*)')) {
            $values.Add($matches[1].Trim().Trim('"'))
        }
    }
    if ($values.Count -gt 1) { throw ('Ambiguous duplicate INI key: ['+$Section+'] '+$Key) }
    if ($values.Count -eq 1) { return $values[0] }
    return $null
}
function Assert-PeX64([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $reader=New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 128 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Missing MZ header.' }
        $stream.Position=0x3c; $offset=$reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length-24)) { throw 'Invalid PE header offset.' }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'An x64 PE DLL is required.' }
        $stream.Position=$offset+22
        if (($reader.ReadUInt16() -band 0x2000) -eq 0) { throw 'The payload is not marked as a DLL.' }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Get-VerifiedManifest {
    $manifest=Read-Json (Join-Path $script:PackageRoot 'package-manifest.json')
    if ((Get-Value $manifest 'schema_version') -ne 1 -or (Get-Value $manifest 'addon_name') -cne 'MatheusNR030') {
        throw 'Unsupported add-on manifest.'
    }
    foreach ($field in @('build_verified','abi_verified')) {
        $value=Get-Value $manifest $field
        if ($value -isnot [bool] -or -not $value) { throw ('Installation blocked: '+$field+' is not verified.') }
    }
    if ((Get-Value $manifest 'base_nr_sha256') -cne $script:ExpectedNrHash) { throw 'Manifest does not target the pinned NR 0.3.0 binary.' }
    if ([string](Get-Value $manifest 'source_commit') -notmatch '^[0-9a-f]{40}$') { throw 'A fixed source commit is required.' }
    foreach ($field in @('addon_version','build_run_id','build_evidence','abi_evidence')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Value $manifest $field))) { throw ('Missing evidence: '+$field) }
    }
    $runtimeVerified=Get-Value $manifest 'game_runtime_verified'
    if ($runtimeVerified -isnot [bool] -or $runtimeVerified) { throw 'This experimental package must explicitly retain game_runtime_verified=false.' }
    if ((Get-Value $manifest 'runtime_log_schema') -cne 'matheusnr030-events-v1') { throw 'Unsupported runtime observation schema.' }
    $runId=[string](Get-Value $manifest 'build_run_id')
    if ($runId -notmatch '^[0-9]+$' -or (Get-Value $manifest 'build_evidence') -cne ('https://github.com/lunarci/b/actions/runs/'+$runId)) {
        throw 'Build evidence does not match the recorded GitHub Actions run.'
    }
    $files=@(Get-Value $manifest 'files')
    if ($files.Count -ne 2) { throw 'Manifest must contain exactly the two add-on payload files.' }
    foreach ($name in $script:AddonNames) {
        $entry=@($files | Where-Object { (Get-Value $_ 'name') -ceq $name })
        if ($entry.Count -ne 1) { throw ('Missing or duplicate payload: '+$name) }
        $hash=[string](Get-Value $entry[0] 'sha256'); $size=Get-Value $entry[0] 'size'
        if ($hash -notmatch '^[0-9a-f]{64}$' -or $null -eq $size -or [long]$size -le 0) { throw ('Unverified payload metadata: '+$name) }
        $path=Join-Path (Join-Path $script:PackageRoot 'payload') $name
        Assert-NoReparse $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing payload: '+$name) }
        if ((Get-Item -LiteralPath $path).Length -ne [long]$size -or (Get-Hash $path) -cne $hash) { throw ('Payload SHA-256/size mismatch: '+$name) }
        if ($name -like '*.asi') { Assert-PeX64 $path }
    }
    return $manifest
}
function Assert-Stopped {
    if (@(Get-Process -Name 'Cyberpunk2077','ModOrganizer' -ErrorAction SilentlyContinue).Count) {
        throw 'Close Cyberpunk 2077 and Mod Organizer before changing add-on files.'
    }
}
function Get-ProtectedSnapshot($Paths) {
    $result=@{}
    $policy=Read-Json (Join-Path $script:PackageRoot 'protected-files.json')
    $extensions=@(Get-Value $policy 'protected_extensions')
    if (($extensions -join '|') -cne '.dll|.asi|.ini|.bin') { throw 'Unexpected protected-file policy.' }
    foreach ($folder in @($Paths.Bin,$Paths.Plugins,$Paths.OldBin,$Paths.OldPlugins)) {
        Assert-NoReparse $folder
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Force)) {
            if ($script:AddonNames -contains $file.Name -or $extensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
            Assert-NoReparse $file.FullName
            $result[(Full-Path $file.FullName)]=Get-Hash $file.FullName
        }
    }
    if (Test-Path -LiteralPath $Paths.BaseState -PathType Leaf) {
        Assert-NoReparse $Paths.BaseState
        $result[(Full-Path $Paths.BaseState)]=Get-Hash $Paths.BaseState
    }
    return $result
}
function Assert-SnapshotUnchanged($Paths,$Before) {
    $after=Get-ProtectedSnapshot $Paths
    if ($Before.Count -ne $after.Count) { throw 'Protected base-file inventory changed. The add-on transaction will be rolled back.' }
    foreach ($path in $Before.Keys) {
        if (-not $after.ContainsKey($path) -or $after[$path] -cne $Before[$path]) {
            throw ('Protected base file changed: '+$path)
        }
    }
}
function Assert-Base($Paths) {
    Assert-NoReparse $Paths.Root; Assert-NoReparse $Paths.Bin; Assert-NoReparse $Paths.Backup
    if (-not (Test-Path -LiteralPath $Paths.Plugins -PathType Container)) { throw ('The fixed ARK plugins folder is missing: '+$Paths.Plugins) }
    # Legacy base-installer metadata is optional: compatibility is established
    # below from the installed NR hash and effective INI files. Never synthesize
    # this record. The separate add-on ownership record remains mandatory when
    # updating or removing existing add-on files.
    $hasBaseState=Test-Path -LiteralPath $Paths.BaseState
    if ($hasBaseState) {
        Assert-NoReparse $Paths.BaseState
        $base=Read-Json $Paths.BaseState
        if ((Get-Value $base 'Version') -ne 2 -or -not (Same-Path ([string](Get-Value $base 'PluginFolder')) $Paths.Plugins)) { throw 'The v1.4 base installation record does not match the fixed ARK path.' }
    }
    $nr=Join-Path $Paths.Plugins 'dlssnr_on_amd.asi'
    if (-not (Test-Path -LiteralPath $nr -PathType Leaf)) { throw ('Base NR file is missing: '+$nr+'. Use 01_INSTALL_ADDON.cmd to obtain the required base files.') }
    $nrHash=Get-Hash $nr
    if ($nrHash -cne $script:ExpectedNrHash) { throw ('The pinned NR 0.3.0 ASI SHA-256 does not match: '+$nr+'; actual='+$nrHash+'; expected='+$script:ExpectedNrHash) }
    $optiPaths=@(Join-Path $Paths.Bin 'OptiScaler.ini')
    $shadowOpti=Join-Path $Paths.OldBin 'OptiScaler.ini'
    if (Test-Path -LiteralPath $shadowOpti -PathType Leaf) { $optiPaths += $shadowOpti }
    foreach ($path in $optiPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing base INI: '+$path) }
        $text=[IO.File]::ReadAllText($path)
        foreach ($entry in @(@('Upscalers','Dx12Upscaler','ffx'),@('FrameGen','FGInput','dlssg'),@('FrameGen','FGOutput','xefg'),@('Inputs','EnableFfxInputs','false'),@('Plugins','LoadAsiPlugins','true'))) {
            if ((Read-IniValue $text $entry[0] $entry[1]) -ine $entry[2]) { throw ('Preserved route is not confirmed: '+$path+' ['+$entry[0]+'] '+$entry[1]) }
        }
        if ((Read-IniValue $text 'Inputs' 'EnableDlssInputs') -ieq 'false') { throw 'DLSS input is disabled in the existing configuration.' }
        $pluginPath=Read-IniValue $text 'Plugins' 'Path'
        if ($pluginPath -and $pluginPath -notin @('auto','plugins','.\plugins','./plugins')) { throw 'A custom ASI plugin path is unsupported by this fixed-path add-on.' }
        $interpolation=Read-IniValue $text 'XeFG' 'InterpolationCount'
        if ($interpolation -ne '3') { throw 'The existing XeFG 4X setting (InterpolationCount=3) is not explicit. No setting is changed.' }
        if ((Read-IniValue $text 'DlssNr' 'Enabled') -in @('true','1')) { throw 'A second built-in NR pipeline is enabled; add-on installation is blocked.' }
    }
    $nrPaths=@(Join-Path $Paths.Plugins 'dlssnr_on_amd.ini')
    $shadowNr=Join-Path $Paths.OldPlugins 'dlssnr_on_amd.ini'
    if (Test-Path -LiteralPath $shadowNr -PathType Leaf) { $nrPaths += $shadowNr }
    foreach ($path in $nrPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing NR INI: '+$path) }
        $text=[IO.File]::ReadAllText($path)
        foreach ($entry in @(@('Enabled','1'),@('PreUpscale','1'),@('Async','0'))) {
            if ((Read-IniValue $text 'DlssNrOnAmd' $entry[0]) -ne $entry[1]) { throw ('Base NR mode does not match: '+$entry[0]+'. Existing settings are preserved.') }
        }
    }
    $shadowAsi=Join-Path $Paths.OldPlugins 'dlssnr_on_amd.asi'
    if ((Test-Path -LiteralPath $shadowAsi -PathType Leaf) -and (Get-Hash $shadowAsi) -cne $script:ExpectedNrHash) { throw 'The overwrite NR binary differs from the pinned base runtime.' }
    if (-not $hasBaseState) { Write-Host 'Legacy base installation record is absent. Base compatibility was verified from the installed NR hash and INI settings.' }
    return Get-ProtectedSnapshot $Paths
}
function Read-AddonState($Paths) {
    if (-not (Test-Path -LiteralPath $Paths.State -PathType Leaf)) { return $null }
    Assert-NoReparse $Paths.State
    $state=Read-Json $Paths.State
    if ((Get-Value $state 'SchemaVersion') -ne 1 -or (Get-Value $state 'AddonName') -cne 'MatheusNR030' -or
        -not (Same-Path ([string](Get-Value $state 'PluginFolder')) $Paths.Plugins)) { throw 'Invalid add-on state; no files were changed.' }
    $files=@(Get-Value $state 'Files')
    if ($files.Count -ne 2) { throw 'Invalid add-on file inventory.' }
    foreach ($name in $script:AddonNames) {
        $entry=@($files | Where-Object { (Get-Value $_ 'Name') -ceq $name })
        if ($entry.Count -ne 1 -or [string](Get-Value $entry[0] 'InstalledHash') -notmatch '^[0-9a-f]{64}$') { throw 'Invalid add-on ownership record.' }
    }
    return $state
}
function Get-OwnedPaths($Paths) {
    $items=@()
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        foreach ($name in $script:AddonNames) { $items += Join-Path $folder $name }
    }
    return $items
}
function Assert-OwnedFiles($Paths,$State,[switch]$AllowModifiedIni) {
    foreach ($path in @(Get-OwnedPaths $Paths)) {
        Assert-NoReparse $path
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('A directory occupies an add-on file path: '+$path) }
        if ($null -eq $State) { throw ('Unowned add-on-named file already exists: '+$path) }
        $name=[IO.Path]::GetFileName($path)
        $entry=@($State.Files | Where-Object { $_.Name -ceq $name })[0]
        if ((Get-Hash $path) -cne $entry.InstalledHash) {
            if ($AllowModifiedIni -and $name -ceq 'MatheusNR030.ini') { continue }
            throw ('Modified add-on file is protected; no files changed: '+$path)
        }
    }
}
function New-BackupFolder($Paths,[string]$Label) {
    Assert-NoReparse $Paths.Backup
    $folder=Join-Path $Paths.Backup ($Label+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return $folder
}
function Copy-Verified([string]$Source,[string]$Destination) {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if ((Get-Hash $Source) -cne (Get-Hash $Destination)) { throw ('Copy verification failed: '+$Destination) }
}
function Invoke-OwnTransaction($Paths,$Operations,[string]$Folder,$Before,[scriptblock]$BeforeOperation=$null) {
    $allowed=@(Get-OwnedPaths $Paths)+@($Paths.State)
    $seen=@{}; $records=New-Object 'System.Collections.Generic.List[object]'
    foreach ($op in @($Operations)) {
        $full=Full-Path $op.Path
        if (-not @($allowed | Where-Object { Same-Path $_ $full }).Count -or $seen.ContainsKey($full)) { throw 'Transaction contains an unowned or duplicate destination.' }
        $seen[$full]=$true; Assert-NoReparse $full
        if ($op.Action -notin @('Copy','Delete')) { throw 'Unknown transaction operation.' }
        $exists=Test-Path -LiteralPath $full -PathType Leaf
        $backup=Join-Path $Folder ('before-'+$records.Count+'.bin')
        if ($exists) { Copy-Verified $full $backup }
        if ($op.Action -eq 'Copy' -and -not (Test-Path -LiteralPath $op.Source -PathType Leaf)) { throw 'Staged source is missing.' }
        $records.Add([pscustomobject]@{Path=$full;Action=$op.Action;Source=$op.Source;Existed=$exists;Backup=$backup})
    }
    $journal=Join-Path $Folder 'transaction.json'
    Write-Json $journal ([pscustomobject]@{Status='prepared';Files=@($records.ToArray())})
    $written=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($record in $records) {
            if ($null -ne $BeforeOperation) { & $BeforeOperation $written.Count }
            $written.Add($record)
            if ($record.Action -eq 'Copy') { Copy-Verified $record.Source $record.Path }
            elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) { Remove-Item -LiteralPath $record.Path -Force }
        }
        Assert-SnapshotUnchanged $Paths $Before
        Write-Json $journal ([pscustomobject]@{Status='completed';Files=@($records.ToArray())})
    } catch {
        $failure=$_; $rollbackErrors=New-Object 'System.Collections.Generic.List[string]'
        for ($i=$written.Count-1;$i -ge 0;$i--) {
            $record=$written[$i]
            try {
                if ($record.Existed) { Copy-Verified $record.Backup $record.Path }
                elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) { Remove-Item -LiteralPath $record.Path -Force }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        Write-Json $journal ([pscustomobject]@{Status='rolled-back';Error=$failure.Exception.Message;RollbackErrors=@($rollbackErrors.ToArray());Files=@($records.ToArray())})
        if ($rollbackErrors.Count) { throw ('Rollback needs review. Backup: '+$Folder+'; '+($rollbackErrors -join '; ')) }
        throw $failure
    }
}
function Install-Addon($Paths,[scriptblock]$BeforeOperation=$null) {
    $manifest=Get-VerifiedManifest
    Assert-Stopped
    $before=Assert-Base $Paths
    $state=Read-AddonState $Paths
    Assert-OwnedFiles $Paths $state
    $folder=New-BackupFolder $Paths 'install'
    $operations=New-Object 'System.Collections.Generic.List[object]'
    $files=@()
    foreach ($name in $script:AddonNames) {
        $source=Join-Path (Join-Path $script:PackageRoot 'payload') $name
        $staged=Join-Path $folder $name; Copy-Verified $source $staged
        $operations.Add([pscustomobject]@{Path=(Join-Path $Paths.Plugins $name);Action='Copy';Source=$staged})
        $files += [pscustomobject]@{Name=$name;InstalledHash=(Get-Hash $staged)}
        $shadow=Join-Path $Paths.OldPlugins $name
        if (Test-Path -LiteralPath $shadow -PathType Leaf) { $operations.Add([pscustomobject]@{Path=$shadow;Action='Delete';Source=$null}) }
    }
    $newState=[pscustomobject]@{
        SchemaVersion=1;AddonName='MatheusNR030';AddonVersion=$manifest.addon_version;PluginFolder=$Paths.Plugins
        InstalledUtc=[DateTime]::UtcNow.ToString('o');SourceCommit=$manifest.source_commit;BuildRunId=$manifest.build_run_id
        ManifestSha256=(Get-Hash (Join-Path $script:PackageRoot 'package-manifest.json'));Files=$files
        ProtectedBaseline=$before;OwnsBaseNr=$false;OwnsOptiScaler=$false;OwnsXeFG=$false;RuntimeVerified=$false
    }
    $prepared=Join-Path $folder 'prepared-state.json'; Write-Json $prepared $newState
    $operations.Add([pscustomobject]@{Path=$Paths.State;Action='Copy';Source=$prepared})
    Invoke-OwnTransaction $Paths @($operations.ToArray()) $folder $before $BeforeOperation
    Write-Host 'Add-on files installed. Base NR 0.3.0 / OptiScaler / XeFG files and settings were preserved.'
    Write-Host 'Runtime operation is not verified by installation. Use 03_CHECK_ADDON.cmd after a new game session.'
}
function Remove-Addon($Paths,[scriptblock]$BeforeOperation=$null) {
    Assert-Stopped
    $state=Read-AddonState $Paths
    if ($null -eq $state) { throw 'No add-on ownership record exists. No files were removed.' }
    # User tuning in the owned INI is allowed: preserve an exact named backup before removal.
    # A changed executable ASI remains a hard stop, before any removal occurs.
    Assert-OwnedFiles $Paths $state -AllowModifiedIni
    $before=Get-ProtectedSnapshot $Paths
    $folder=New-BackupFolder $Paths 'remove'
    $savedSettings=@()
    $iniRecord=@($state.Files | Where-Object { $_.Name -ceq 'MatheusNR030.ini' })[0]
    foreach ($location in @([pscustomobject]@{Folder=$Paths.Plugins;Label='ARK'},[pscustomobject]@{Folder=$Paths.OldPlugins;Label='overwrite'})) {
        $ini=Join-Path $location.Folder 'MatheusNR030.ini'
        if ((Test-Path -LiteralPath $ini -PathType Leaf) -and (Get-Hash $ini) -cne $iniRecord.InstalledHash) {
            $saved=Join-Path $folder ($location.Label+'-MatheusNR030.ini')
            Copy-Verified $ini $saved
            $savedSettings += [pscustomobject]@{OriginalPath=$ini;SavedPath=$saved;Sha256=(Get-Hash $saved)}
        }
    }
    if ($savedSettings.Count) { Write-Json (Join-Path $folder 'saved-user-settings.json') @($savedSettings) }
    $operations=New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @(Get-OwnedPaths $Paths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $operations.Add([pscustomobject]@{Path=$path;Action='Delete';Source=$null}) }
    }
    $operations.Add([pscustomobject]@{Path=$Paths.State;Action='Delete';Source=$null})
    Invoke-OwnTransaction $Paths @($operations.ToArray()) $folder $before $BeforeOperation
    Write-Host 'Only MatheusNR030 add-on files were removed. Base NR and XeFG were preserved.'
    foreach ($saved in $savedSettings) { Write-Host ('Your tuned add-on settings were saved: '+$saved.SavedPath) }
}
function Get-LogFolders($Paths) {
    $folders=@($Paths.Plugins,$Paths.OldPlugins)
    $mo2Ini=Join-Path $Paths.Root 'ModOrganizer.ini'
    if (Test-Path -LiteralPath $mo2Ini -PathType Leaf) {
        foreach ($line in [regex]::Split([IO.File]::ReadAllText($mo2Ini),'\r?\n')) {
            if ($line -match '^\s*(?:gamePath|game_path)\s*=\s*(.+)$') {
                $game=$matches[1].Trim().Trim('"')
                if ($game -match '^@ByteArray\((.*)\)$') { $game=$matches[1] }
                $game=$game.Replace('\\','\')
                if ($game -and (Test-Path -LiteralPath $game -PathType Container)) { $folders += Join-Path $game 'bin/x64/plugins' }
            }
        }
    }
    return @($folders | Select-Object -Unique)
}
function Get-LatestLog([string[]]$Folders,[string]$Name) {
    $logs=@($Folders | ForEach-Object { $candidate=Join-Path $_ $Name; if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate } } | Sort-Object LastWriteTimeUtc -Descending)
    if ($logs.Count) { return $logs[0] }
    return $null
}
function Get-BaseSessionSummary([string]$Text) {
    $starts=[regex]::Matches($Text,'(?m)^dlssnr_amd\s+v[^\r\n]*loaded into[^\r\n]*')
    if (-not $starts.Count) { return [pscustomobject]@{HeaderFound=$false;Nr030=$false;PreUpscale=$false;CompletedJob=$false;FinalStats=$null} }
    $session=$Text.Substring($starts[$starts.Count-1].Index)
    $stats=[regex]::Matches($session,'(?m)^frames [^\r\n]+')
    [pscustomobject]@{
        HeaderFound=$true;Nr030=($session -match '^dlssnr_amd v0\.3\.0 ')
        PreUpscale=($session -match 'pre-upscale mode: the network runs on the')
        CompletedJob=($session -match '(?m)^network job \d+ done|^timing \(avg of')
        FinalStats=$(if ($stats.Count) { $stats[$stats.Count-1].Value } else { $null })
    }
}
function Get-PoolSessionSummary([string]$Text) {
    $result=[pscustomobject]@{Samples=0;LocalSamples=0;OverBudgetSamples=0;PeakLocalUsageBytes=0L;PeakAddonBytes=0L;Latest=$null}
    $starts=[regex]::Matches($Text,'(?m)^event=session_start [^\r\n]*')
    if (-not $starts.Count) { return $result }
    $session=$Text.Substring($starts[$starts.Count-1].Index)
    foreach ($line in [regex]::Matches($session,'(?m)^event=pool_sample [^\r\n]*')) {
        $fields=@{}
        foreach ($pair in [regex]::Matches($line.Value,'([a-z_]+)=([^\s]+)')) { $fields[$pair.Groups[1].Value]=$pair.Groups[2].Value }
        $valid=$true
        foreach ($key in @('tick_ms','allocated_bytes','allocated_slots','retained_uses','retired_uses','released_borrowed_refs','trimmed_slots','trimmed_bytes','local_valid','local_usage_bytes','local_budget_bytes','nonlocal_valid','nonlocal_usage_bytes','ffx_reset','addon_failed')) {
            $value=0L
            if (-not $fields.ContainsKey($key) -or -not [long]::TryParse($fields[$key],[ref]$value) -or $value -lt 0) { $valid=$false;break }
            $fields[$key]=$value
        }
        if (-not $valid) { continue }
        $result.Samples++;$result.Latest=[pscustomobject]$fields
        $result.PeakAddonBytes=[Math]::Max($result.PeakAddonBytes,$fields.allocated_bytes)
        if ($fields.local_valid -eq 1 -and $fields.local_budget_bytes -gt 0) {
            $result.LocalSamples++
            $result.PeakLocalUsageBytes=[Math]::Max($result.PeakLocalUsageBytes,$fields.local_usage_bytes)
            if ($fields.local_usage_bytes -gt $fields.local_budget_bytes) { $result.OverBudgetSamples++ }
        }
    }
    return $result
}
function Get-AddonSessionSummary([string]$Text,[string]$InstalledUtc) {
    # All fields are observations, never a visual-quality, performance, or neural-inference verdict.
    $result=[pscustomobject]@{
        HeaderFound=$false;SessionUtc=$null;StartedAfterInstall=$false;HookActive=$false
        ScalePercent=$null;Seen=0L;Scaled=0L;NrRecorded=0L;Resolved=0L;Fallback=0L;GpuCompleted=0L
        StatsFound=$false;CommandRecordingObserved=$false;GpuRetirementObserved=$false
        SourceCommit=$null;InputWidth=$null;InputHeight=$null;NrWidth=$null;NrHeight=$null
        ColourPreservationPercent=$null;DepthProtection=$null;EffectPercent=$null
        CompositeSettingsFound=$false;CompositeRecordingObserved=$false
        RuntimeValidated=$false;Result='UNVERIFIED'
    }
    $starts=[regex]::Matches($Text,'(?m)^event=session_start utc=([^\s]+) runtime_validated=false(?: source_commit=([0-9a-f]{40}|unrecorded))?[ \t\r]*$')
    if (-not $starts.Count) { return $result }
    $start=$starts[$starts.Count-1];$session=$Text.Substring($start.Index)
    $result.HeaderFound=$true;$result.SessionUtc=$start.Groups[1].Value
    if ($start.Groups[2].Success) { $result.SourceCommit=$start.Groups[2].Value }
    $sessionTime=[DateTimeOffset]::MinValue;$installTime=[DateTimeOffset]::MinValue
    $style=[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParse($result.SessionUtc,[Globalization.CultureInfo]::InvariantCulture,$style,[ref]$sessionTime) -and
        [DateTimeOffset]::TryParse($InstalledUtc,[Globalization.CultureInfo]::InvariantCulture,$style,[ref]$installTime)) {
        $result.StartedAfterInstall=($sessionTime -ge $installTime)
    }
    $hooks=[regex]::Matches($session,'(?m)^event=hook_active static_abi_verified=true runtime_validated=false scale_percent=(75|85|100)\s*$')
    if ($hooks.Count) { $result.HookActive=$true;$result.ScalePercent=[int]$hooks[$hooks.Count-1].Groups[1].Value }
    $config=[regex]::Matches($session,'(?m)^event=resolve_config version=0\.2\.[012] colour_preservation_percent=(100|[0-9]{1,2}) depth_protection=([01]) effect_percent=(100|[0-9]{1,2}) applies_to_scaled_path_only=true[ \t\r]*$')
    if ($config.Count) {
        $last=$config[$config.Count-1];$result.CompositeSettingsFound=$true
        $result.ColourPreservationPercent=[int]$last.Groups[1].Value
        $result.DepthProtection=([int]$last.Groups[2].Value -eq 1)
        $result.EffectPercent=[int]$last.Groups[3].Value
    }
    $ready=[regex]::Matches($session,'(?m)^event=adapter_ready input_width=(\d{1,5}) input_height=(\d{1,5}) nr_width=(\d{1,5}) nr_height=(\d{1,5})[ \t\r]*$')
    if ($ready.Count) {
        $last=$ready[$ready.Count-1]
        $result.InputWidth=[int]$last.Groups[1].Value;$result.InputHeight=[int]$last.Groups[2].Value
        $result.NrWidth=[int]$last.Groups[3].Value;$result.NrHeight=[int]$last.Groups[4].Value
    }
    $stats=[regex]::Matches($session,'(?m)^event=frame seen=(\d+) scaled=(\d+) nr_recorded=(\d+) resolved=(\d+) fallback=(\d+) gpu_completed=(\d+)(?: allocated_bytes=\d+ allocated_slots=\d+)?[ \t\r]*$')
    if ($stats.Count) {
        $last=$stats[$stats.Count-1];$values=@();$valid=$true
        for ($i=1;$i -le 6;$i++) {
            $number=0L
            if (-not [long]::TryParse($last.Groups[$i].Value,[ref]$number)) { $valid=$false;break }
            $values += $number
        }
        if ($valid -and $values[3] -le $values[2] -and $values[2] -le $values[1] -and $values[1] -le $values[0]) {
            $result.StatsFound=$true
            $result.Seen=$values[0];$result.Scaled=$values[1];$result.NrRecorded=$values[2]
            $result.Resolved=$values[3];$result.Fallback=$values[4];$result.GpuCompleted=$values[5]
        }
    }
    if (-not $result.StartedAfterInstall) { $result.Result='STALE_OR_NO_INSTALL_TIME';return $result }
    if (-not $result.HookActive) { $result.Result='NO_ACTIVE_HOOK_OBSERVED';return $result }
    if ($result.ScalePercent -eq 100) { $result.Result='BASELINE_100_PERCENT';return $result }
    if (-not $result.StatsFound -or $result.NrRecorded -eq 0 -or $result.Resolved -eq 0) { $result.Result='NO_NR_RESOLVE_RECORDING_OBSERVED';return $result }
    $result.CommandRecordingObserved=$true
    $result.CompositeRecordingObserved=($result.CompositeSettingsFound -and $result.EffectPercent -gt 0)
    $result.GpuRetirementObserved=($result.GpuCompleted -gt 0)
    $result.Result='NR_RESOLVE_COMMAND_RECORDING_OBSERVED'
    return $result
}
function Check-Addon($Paths) {
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('MatheusNR030 read-only check '+[DateTime]::UtcNow.ToString('o'))
    $lines.Add('Install path: '+$Paths.Plugins)
    try { $null=Get-VerifiedManifest; $lines.Add('Package build/ABI/hash gates: PASS') } catch { $lines.Add('Package installation gate: BLOCKED - '+$_.Exception.Message) }
    try { $snapshot=Assert-Base $Paths; $lines.Add('Base NR hash and preserved settings: PASS'); foreach ($path in @($snapshot.Keys | Sort-Object)) { $lines.Add('Protected '+$snapshot[$path]+' '+$path) } } catch { $lines.Add('Base check: NOT CONFIRMED - '+$_.Exception.Message) }
    $state=$null
    $filesConfirmed=$false
    try {
        $state=Read-AddonState $Paths; Assert-OwnedFiles $Paths $state -AllowModifiedIni
        $lines.Add('Add-on ownership record present: '+($null -ne $state))
        $missing=@($script:AddonNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Paths.Plugins $_) -PathType Leaf) })
        $filesConfirmed=($null -ne $state -and $missing.Count -eq 0)
        $lines.Add('Installed add-on payload complete: '+$filesConfirmed)
        $lines.Add('Tuned owned INI files are permitted; executable ASI hashes must still match.')
    } catch { $lines.Add('Add-on file check: '+$_.Exception.Message) }
    $folders=Get-LogFolders $Paths
    $baseLog=Get-LatestLog $folders 'dlssnr_on_amd.log'
    if ($null -ne $baseLog) {
        $baseText=[IO.File]::ReadAllText($baseLog.FullName)
        $summary=Get-BaseSessionSummary $baseText
        $lines.Add('Base log: '+$baseLog.FullName+'; modified UTC '+$baseLog.LastWriteTimeUtc.ToString('o'))
        $lines.Add('LAST SESSION only: '+($summary | ConvertTo-Json -Compress))
        if ($null -ne $state) { $lines.Add('Log file modified after add-on install: '+($baseLog.LastWriteTimeUtc -ge [DateTime]::Parse($state.InstalledUtc).ToUniversalTime())) }
        $lines.Add('A file timestamp alone does not prove the final session began after installation.')
        $baseStarts=[regex]::Matches($baseText,'(?m)^dlssnr_amd\s+v[^\r\n]*loaded into[^\r\n]*')
        if ($baseStarts.Count) {
            $baseSession=$baseText.Substring($baseStarts[$baseStarts.Count-1].Index)
            $lines.Add('Base NR current-session input formats / timing:')
            foreach ($line in @([regex]::Matches($baseSession,'(?m)^(?:dlssnr_amd |ffxCreateContext:|pre-upscale mode:|staging ready:|timing \(avg)[^\r\n]*') | Select-Object -Last 16)) { $lines.Add($line.Value) }
        }
    } else { $lines.Add('Base NR log not found.') }
    $addonLog=Get-LatestLog $folders 'MatheusNR030.log'
    if ($null -ne $addonLog) {
        $lines.Add('Add-on log: '+$addonLog.FullName+'; modified UTC '+$addonLog.LastWriteTimeUtc.ToString('o'))
        $addonText=[IO.File]::ReadAllText($addonLog.FullName)
        $installedUtc=''
        if ($filesConfirmed) { $installedUtc=[string](Get-Value $state 'InstalledUtc') }
        $addonSummary=Get-AddonSessionSummary $addonText $installedUtc
        $lines.Add('ADD-ON LAST SESSION observations: '+($addonSummary | ConvertTo-Json -Compress))
        $lines.Add('Combined colour/depth settings recorded: '+$addonSummary.CompositeSettingsFound+'; composite command recording observed: '+$addonSummary.CompositeRecordingObserved)
        if ($addonSummary.StartedAfterInstall -and $addonSummary.StatsFound -and $addonSummary.Seen -gt 0 -and $addonSummary.Scaled -eq 0) {
            $lines.Add('NOT APPLIED: no NR input downscaling was recorded. A configured ScalePercent=85 alone is not successful application.')
        }
        $poolSummary=Get-PoolSessionSummary $addonText
        $lines.Add('POOL / MEMORY LAST SESSION: '+($poolSummary | ConvertTo-Json -Compress -Depth 5))
        $lines.Add('DXGI local_usage is process usage, not addon-only VRAM. Over-budget observations do not prove the map-drop cause; ffx_frame_time_ms is supplied dispatch data, not measured FPS.')
        $lines.Add('Recent pool samples for map-before/map-after comparison:')
        $lastStart=[regex]::Matches($addonText,'(?m)^event=session_start [^\r\n]*')
        if ($lastStart.Count) {
            $lastSession=$addonText.Substring($lastStart[$lastStart.Count-1].Index)
            foreach ($sample in @([regex]::Matches($lastSession,'(?m)^event=pool_sample [^\r\n]*') | Select-Object -Last 90)) { $lines.Add($sample.Value) }
        }
        $lines.Add('nr_recorded/resolved count recorded GPU commands; gpu_completed counts retired resource slots. They do not establish image correctness or speed gains.')
        $lines.Add('Add-on log tail:')
        foreach ($line in @([regex]::Split($addonText,'\r?\n') | Select-Object -Last 35)) { $lines.Add($line) }
    } else { $lines.Add('MatheusNR030.log not found.') }
    $lines.Add('GAMEPLAY / IMAGE QUALITY / PERFORMANCE: UNVERIFIED. DLL load/build and GPU command recording do not prove inference quality. XeFG Active/4X requires its own runtime check.')
    $text=$lines -join "`r`n"
    foreach ($line in $lines) { Write-Host $line }
    return $text
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $Mo2Root
        switch ($Action) {
            'Install' { Install-Addon $paths }
            'Remove' { Remove-Addon $paths }
            'Check' {
                $report=Check-Addon $paths
                # Check does not write to the game/MO2 tree; only its own package Results folder.
                $results=Join-Path $script:PackageRoot 'Results'
                Assert-NoReparse $results
                New-Item -ItemType Directory -Path $results -Force | Out-Null
                Write-Text (Join-Path $results 'MATHEUS_CHECK.txt') $report
            }
        }
        exit 0
    } catch {
        Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
