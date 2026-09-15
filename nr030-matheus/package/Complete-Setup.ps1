#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Check','Remove','RestoreComplete','DisableNr','RecoverPerformance')][string]$Action='Check',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2'
)
$completeRequestedAction=$Action
$completeRequestedRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Setup.ps1') -Action Check
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# These are fixed distribution artifacts, not a "latest" release lookup. The
# model URL is a third-party mirror; a matching installed model is preferred.
# There is deliberately no command-line hash, URL, or prerequisite override.
$script:CompleteDependencies=@(
    [pscustomobject]@{Name='dlssnr_on_amd.asi';Entry='version-original.dll';Size=7290880L;Sha256='c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de';Archive='XeFG.opti.zip';ArchiveSize=10961394L;ArchiveSha256='c42c0d040c6851e8ef64876d1364fa32c7f266ec71c2ab3364b28d7f5e639471';Url='https://github.com/user-attachments/files/32174452/XeFG.opti.zip'},
    [pscustomobject]@{Name='nvngx_dlssnr.dll';Entry='nvngx_dlssnr.dll';Size=165840496L;Sha256='e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e';Archive='nvngx_dlssnr_310.8.0.zip';ArchiveSize=109425288L;ArchiveSha256='388c0a7912e15ec911b9c9e11a692142b11fe387ddf2b637d8c358138fffb3ac';Url='https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip'}
)

function Get-CompletePaths($Paths) {
    $backup=Join-Path $Paths.Root 'Matheus_NR030_Complete_Backup'
    [pscustomobject]@{Backup=$backup;State=(Join-Path $backup 'active-install.json');Cache=(Join-Path $script:PackageRoot 'download-cache')}
}
function Test-CompleteFile([string]$Path,[long]$Size,[string]$Hash) {
    Assert-NoReparse $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-Item -LiteralPath $Path).Length -eq $Size -and (Get-Hash $Path) -ceq $Hash)
}
function Get-CompleteBaseTargets($Paths) {
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        foreach ($name in @('dlssnr_on_amd.asi','nvngx_dlssnr.dll','dlssnr_on_amd.ini','dlssnr_on_amd_weights.bin')) { Join-Path $folder $name }
    }
    Join-Path $Paths.Bin 'OptiScaler.ini'
    Join-Path $Paths.OldBin 'OptiScaler.ini'
}
function Assert-CompleteTarget([string]$Path,[string[]]$Allowed) {
    Assert-NoReparse $Path
    if (-not @($Allowed | Where-Object { Same-Path $_ $Path }).Count) { throw ('Unrecognized complete-install destination: '+$Path) }
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('A directory occupies a required file path: '+$Path) }
}
function Get-CompleteHipPath($Paths) {
    $candidates=New-Object 'System.Collections.Generic.List[string]'
    if ($env:WINDIR) { $candidates.Add((Join-Path $env:WINDIR 'System32/amdhip64_7.dll')) }
    foreach ($folder in @($Paths.Bin,$Paths.Plugins,$Paths.OldBin,$Paths.OldPlugins)+@($env:PATH -split [IO.Path]::PathSeparator)) {
        if (-not [string]::IsNullOrWhiteSpace($folder)) { $candidates.Add((Join-Path $folder.Trim().Trim('"') 'amdhip64_7.dll')) }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Assert-PeX64 $candidate; return $candidate }
    }
    throw 'AMD HIP 7 runtime amdhip64_7.dll is missing. Install the supported AMD GPU driver from https://www.amd.com/en/support . No driver or SDK is changed by this package.'
}
function Save-CompleteDownload([string]$Url,[string]$Destination,[long]$MaximumBytes) {
    $uri=[Uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https') { throw 'Dependency downloads require HTTPS.' }
    Assert-NoReparse $Destination
    $priorProtocol=[Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol=$priorProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        for ($redirect=0;$redirect -le 8;$redirect++) {
            $request=[Net.HttpWebRequest]::Create($uri)
            $request.Method='GET';$request.AllowAutoRedirect=$false
            $request.Timeout=60000;$request.ReadWriteTimeout=60000
            $request.UserAgent='MatheusNR030-CompleteInstaller/1.0'
            $response=$null
            try {
                $response=$request.GetResponse()
                $status=[int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    $location=[string]$response.Headers['Location']
                    if ([string]::IsNullOrWhiteSpace($location)) { throw 'Download redirect has no Location.' }
                    $next=New-Object Uri($uri,$location)
                    if ($next.Scheme -cne 'https') { throw 'A dependency redirect attempted to leave HTTPS.' }
                    $uri=$next;continue
                }
                if ($status -ne 200) { throw ('Unexpected download HTTP status: '+$status) }
                if ($response.ContentLength -gt $MaximumBytes) { throw 'Download exceeds the pinned archive size.' }
                $inputStream=$response.GetResponseStream();$outputStream=$null
                try {
                    $outputStream=New-Object IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    $buffer=New-Object byte[] 65536;$total=0L
                    $timer=[Diagnostics.Stopwatch]::StartNew()
                    while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt $MaximumBytes -or $timer.Elapsed.TotalMinutes -gt 15) { throw 'Dependency download size or time limit exceeded.' }
                        $outputStream.Write($buffer,0,$read)
                    }
                    $outputStream.Flush()
                    if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) { throw 'Dependency download was truncated.' }
                } finally { if ($null -ne $outputStream) { $outputStream.Dispose() };$inputStream.Dispose() }
                return
            } finally { if ($null -ne $response) { $response.Dispose() } }
        }
        throw 'Too many dependency download redirects.'
    } finally { [Net.ServicePointManager]::SecurityProtocol=$priorProtocol }
}
function Get-CompleteResource($Paths,$Dependency,[string]$Stage,[scriptblock]$Download=$null) {
    $complete=Get-CompletePaths $Paths
    $cacheFile=Join-Path $complete.Cache $Dependency.Name
    $candidateFolders=@($Paths.Plugins,$Paths.OldPlugins,(Join-Path $script:PackageRoot 'input'),$complete.Cache)
    $source=$null
    foreach ($folder in $candidateFolders) {
        $candidate=Join-Path $folder $Dependency.Name
        if (Test-CompleteFile $candidate $Dependency.Size $Dependency.Sha256) { $source=$candidate;break }
    }
    if ($null -eq $source) {
        Assert-NoReparse $complete.Cache
        New-Item -ItemType Directory -Path $complete.Cache -Force | Out-Null
        $archive=Join-Path $complete.Cache $Dependency.Archive
        if (-not (Test-CompleteFile $archive $Dependency.ArchiveSize $Dependency.ArchiveSha256)) {
            $part=$archive+'.'+[guid]::NewGuid().ToString('N')+'.part'
            Write-Host ('Downloading '+$Dependency.Name+' from '+$Dependency.Url)
            try {
                if ($null -eq $Download) { Save-CompleteDownload $Dependency.Url $part $Dependency.ArchiveSize }
                else { & $Download $Dependency.Url $part $Dependency.ArchiveSize | Out-Null }
                if (-not (Test-CompleteFile $part $Dependency.ArchiveSize $Dependency.ArchiveSha256)) { throw ('Downloaded archive SHA-256/size mismatch: '+$Dependency.Archive) }
                Move-Item -LiteralPath $part -Destination $archive -Force
            } finally { if (Test-Path -LiteralPath $part -PathType Leaf) { Remove-Item -LiteralPath $part -Force } }
        }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        $part=$cacheFile+'.'+[guid]::NewGuid().ToString('N')+'.part'
        try {
            $entries=@($zip.Entries | Where-Object { $_.Name -ieq $Dependency.Entry })
            if ($entries.Count -ne 1 -or $entries[0].Length -ne $Dependency.Size) { throw ('Unexpected dependency ZIP member or size: '+$Dependency.Name) }
            # Only one explicitly named member is streamed. Archive paths are
            # never used as destinations; no bundled program/script is run.
            $inputStream=$entries[0].Open();$outputStream=[IO.File]::Create($part)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose();$inputStream.Dispose() }
            if (-not (Test-CompleteFile $part $Dependency.Size $Dependency.Sha256)) { throw ('Extracted dependency SHA-256/size mismatch: '+$Dependency.Name) }
            Assert-PeX64 $part
            Move-Item -LiteralPath $part -Destination $cacheFile -Force
            $source=$cacheFile
        } finally { $zip.Dispose();if (Test-Path -LiteralPath $part -PathType Leaf) { Remove-Item -LiteralPath $part -Force } }
    }
    $destination=Join-Path $Stage $Dependency.Name
    Copy-Verified $source $destination
    if (-not (Test-CompleteFile $destination $Dependency.Size $Dependency.Sha256)) { throw ('Staged dependency does not match: '+$Dependency.Name) }
    Assert-PeX64 $destination
    Write-Host ('Verified '+$Dependency.Name+'; source: '+$source)
    return $destination
}
function Set-CompleteIniValue([string]$Text,[string]$Section,[string]$Key,[string]$Value) {
    # Reject ambiguity before mutation. If already correct, preserve all bytes.
    if ((Read-IniValue $Text $Section $Key) -ieq $Value) { return $Text }
    $sectionMatches=[regex]::Matches($Text,'(?im)^\s*\['+[regex]::Escape($Section)+'\]\s*(?:[;#][^\r\n]*)?\r?$')
    if ($sectionMatches.Count -gt 1) { throw ('Ambiguous duplicate INI section: '+$Section) }
    $newline="`r`n";if ($Text.Contains("`n") -and -not $Text.Contains("`r`n")) { $newline="`n" }
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [regex]::Split($Text,'\r?\n')) { $lines.Add($line) }
    $start=-1;$end=$lines.Count
    for ($i=0;$i -lt $lines.Count;$i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]') {
            if ($start -ge 0) { $end=$i;break }
            if ($matches[1] -ieq $Section) { $start=$i }
        }
    }
    if ($start -lt 0) { $lines.Add('['+$Section+']');$lines.Add($Key+'='+$Value) }
    else {
        $found=$false
        for ($i=$start+1;$i -lt $end;$i++) {
            if ($lines[$i] -match ('^(\s*'+[regex]::Escape($Key)+'\s*=\s*)([^;#]*)(.*)$')) {
                $lines[$i]=$matches[1]+$Value+$matches[3];$found=$true;break
            }
        }
        if (-not $found) { $lines.Insert($end,$Key+'='+$Value) }
    }
    return ($lines -join $newline)
}
function Get-CompleteIniText([string]$Text,[string]$Kind) {
    if ($Kind -ceq 'NR') {
        foreach ($pair in @(@('Enabled','1'),@('PreUpscale','1'),@('Async','0'))) { $Text=Set-CompleteIniValue $Text 'DlssNrOnAmd' $pair[0] $pair[1] }
    } else {
        foreach ($entry in @(@('Upscalers','Dx12Upscaler','ffx'),@('FrameGen','FGInput','dlssg'),@('FrameGen','FGOutput','xefg'),@('Inputs','EnableFfxInputs','false'),@('Inputs','EnableDlssInputs','true'),@('Plugins','LoadAsiPlugins','true'),@('XeFG','InterpolationCount','3'))) {
            $Text=Set-CompleteIniValue $Text $entry[0] $entry[1] $entry[2]
        }
        $Text=Set-CompleteRatioTwo $Text
        $pluginPath=Read-IniValue $Text 'Plugins' 'Path'
        if ($pluginPath -and $pluginPath -notin @('auto','plugins','.\plugins','./plugins')) { throw 'A custom ASI plugin path needs review. No existing files were changed.' }
        if ((Read-IniValue $Text 'DlssNr' 'Enabled') -in @('true','1')) { $Text=Set-CompleteIniValue $Text 'DlssNr' 'Enabled' 'false' }
    }
    return $Text
}
function Set-CompleteRatioTwo([string]$Text) {
    # The user explicitly requested Override all = 2.0. Keep every other
    # quality/sharpness setting, including the stored per-preset ratios.
    foreach ($entry in @(@('UpscaleRatio','UpscaleRatioOverrideEnabled','true'),@('UpscaleRatio','UpscaleRatioOverrideValue','2.0'),@('QualityOverrides','QualityRatioOverrideEnabled','false'))) {
        $Text=Set-CompleteIniValue $Text $entry[0] $entry[1] $entry[2]
    }
    return $Text
}
function Read-CompleteState($Paths) {
    $complete=Get-CompletePaths $Paths
    if (-not (Test-Path -LiteralPath $complete.State)) { return $null }
    Assert-NoReparse $complete.State
    $state=Read-Json $complete.State
    if ((Get-Value $state 'SchemaVersion') -ne 1 -or (Get-Value $state 'Name') -cne 'MatheusNR030Complete' -or
        -not (Same-Path ([string](Get-Value $state 'Root')) $Paths.Root)) { throw 'Invalid complete-install ownership record.' }
    $allowed=@(Get-CompleteBaseTargets $Paths);$seen=@{}
    foreach ($entry in @(Get-Value $state 'Files')) {
        $path=[string](Get-Value $entry 'Path');Assert-CompleteTarget $path $allowed
        if ($seen.ContainsKey((Full-Path $path))) { throw 'Duplicate complete-install ownership destination.' }
        $seen[(Full-Path $path)]=$true
        if ((Get-Value $entry 'Existed') -isnot [bool] -or (Get-Value $entry 'InstalledExists') -isnot [bool]) { throw 'Invalid complete-install ownership flags.' }
        if ($entry.InstalledExists -and [string](Get-Value $entry 'InstalledHash') -notmatch '^[0-9a-f]{64}$') { throw 'Invalid complete-install installed hash.' }
        $generated=Get-Value $entry 'GeneratedCache'
        if ($null -ne $generated -and ($generated -isnot [bool] -or ($generated -and ($entry.InstalledExists -or [IO.Path]::GetFileName($path) -cne 'dlssnr_on_amd_weights.bin')))) { throw 'Invalid generated-cache ownership record.' }
        if ($entry.Existed) {
            $backup=[string](Get-Value $entry 'Backup');Assert-NoReparse $backup
            $prefix=(Full-Path $complete.Backup)+[IO.Path]::DirectorySeparatorChar
            if (-not (Full-Path $backup).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
                [string](Get-Value $entry 'BeforeHash') -notmatch '^[0-9a-f]{64}$' -or
                -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $entry.BeforeHash) { throw 'Complete-install original backup is missing or changed.' }
        }
    }
    return $state
}
function Test-CompleteInstalledRecord($Entry) {
    if (Test-Path -LiteralPath $Entry.Path -PathType Leaf) { return ($Entry.InstalledExists -and (Get-Hash $Entry.Path) -ceq $Entry.InstalledHash) }
    return (-not $Entry.InstalledExists -and -not (Test-Path -LiteralPath $Entry.Path))
}
function New-CompleteBackup($Paths,[string]$Label) {
    $complete=Get-CompletePaths $Paths;Assert-NoReparse $complete.Backup
    $folder=Join-Path $complete.Backup ($Label+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return $folder
}
function New-CompleteSnapshots([string[]]$Destinations,[string]$Folder) {
    $records=New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @($Destinations | Select-Object -Unique)) {
        Assert-NoReparse $path
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('File destination is a directory: '+$path) }
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $backup=Join-Path $Folder ('before-'+$records.Count+'.bin');$hash=$null
        if ($exists) { Copy-Verified $path $backup;$hash=Get-Hash $backup }
        $records.Add([pscustomobject]@{Path=(Full-Path $path);Existed=[bool]$exists;Backup=$backup;BeforeHash=$hash})
    }
    return @($records.ToArray())
}
function Restore-CompleteSnapshots($Records) {
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $ordered=@($Records)
    for ($i=$ordered.Count-1;$i -ge 0;$i--) {
        $record=$ordered[$i]
        try {
            Assert-NoReparse $record.Path
            if ($record.Existed) {
                if ((Get-Hash $record.Backup) -cne $record.BeforeHash) { throw 'Transaction backup changed.' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $record.Path) -Force | Out-Null
                Copy-Verified $record.Backup $record.Path
            } elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) { Remove-Item -LiteralPath $record.Path -Force }
        } catch { $errors.Add($record.Path+': '+$_.Exception.Message) }
    }
    if ($errors.Count) { throw ('Rollback requires the saved backup: '+($errors -join '; ')) }
}
function Add-CompleteCopy($Operations,[string]$Source,[string]$Path) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Hash $Path) -ceq (Get-Hash $Source)) { return }
    $Operations.Add([pscustomobject]@{Action='Copy';Source=$Source;Path=$Path;InstalledExists=$true;InstalledHash=(Get-Hash $Source)})
}
function Get-CompleteAddonIni($Paths) {
    $text=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'payload/MatheusNR030.ini'))
    foreach ($folder in @($Paths.OldPlugins,$Paths.Plugins)) {
        $path=Join-Path $folder 'MatheusNR030.ini'
        if (Test-Path -LiteralPath $path -PathType Leaf) { $text=[IO.File]::ReadAllText($path);break }
    }
    # Add newly introduced default keys without resetting existing tuning.
    $defaults=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'payload/MatheusNR030.ini'))
    $section=''
    foreach ($line in [regex]::Split($defaults,'\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]') { $section=$matches[1];continue }
        if ($section -and $line -match '^\s*([^;#=]+?)\s*=\s*([^;#]*)') {
            $key=$matches[1].Trim();$value=$matches[2].Trim()
            if ($null -eq (Read-IniValue $text $section $key)) { $text=Set-CompleteIniValue $text $section $key $value }
        }
    }
    return (Set-CompleteIniValue $text 'MatheusNR030' 'Enabled' '1')
}
function Install-Complete($Paths,[scriptblock]$Download=$null,[scriptblock]$BeforeAddonOperation=$null,[scriptblock]$HipProbe=$null) {
    # The scriptblock parameters are test seams on this dot-sourced function;
    # none can be supplied to the production command-line entry point.
    $null=Get-VerifiedManifest;Assert-Stopped
    Assert-NoReparse $Paths.Root;Assert-NoReparse $Paths.Bin
    if (-not (Test-Path -LiteralPath $Paths.Bin -PathType Container)) { throw ('The existing ARK OptiScaler mod folder is missing: '+$Paths.Bin) }
    $oldAddon=Read-AddonState $Paths;Assert-OwnedFiles $Paths $oldAddon -AllowModifiedIni
    $prior=Read-CompleteState $Paths
    if ($null -eq $HipProbe) { $hip=Get-CompleteHipPath $Paths } else { $hip=& $HipProbe $Paths }
    if ([string]::IsNullOrWhiteSpace([string]$hip)) { throw 'AMD HIP 7 runtime was not found.' }
    Write-Host ('AMD HIP runtime: '+$hip)
    # Conflicting legacy metadata is not rewritten or silently adopted.
    if (Test-Path -LiteralPath $Paths.BaseState) {
        Assert-NoReparse $Paths.BaseState;$legacy=Read-Json $Paths.BaseState
        if ((Get-Value $legacy 'Version') -ne 2 -or -not (Same-Path ([string](Get-Value $legacy 'PluginFolder')) $Paths.Plugins)) { throw 'The legacy base record conflicts with the fixed ARK install path.' }
    }
    $complete=Get-CompletePaths $Paths;Assert-NoReparse $complete.Cache
    $stage=Join-Path $complete.Cache ('stage-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $stagedAddonIni=Join-Path $stage 'installed-addon.ini'
        Write-Text $stagedAddonIni (Get-CompleteAddonIni $Paths)
        $operations=New-Object 'System.Collections.Generic.List[object]';$replaceExistingRuntime=$false
        foreach ($dependency in $script:CompleteDependencies) {
            $source=Get-CompleteResource $Paths $dependency $stage $Download
            foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
                $path=Join-Path $folder $dependency.Name
                if ((Same-Path $folder $Paths.OldPlugins) -and -not (Test-Path -LiteralPath $path)) { continue }
                Assert-CompleteTarget $path @(Get-CompleteBaseTargets $Paths)
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-CompleteFile $path $dependency.Size $dependency.Sha256)) { $replaceExistingRuntime=$true }
                Add-CompleteCopy $operations $source $path
            }
        }
        foreach ($kind in @('Opti','NR')) {
            $name='OptiScaler.ini';$folders=@($Paths.Bin,$Paths.OldBin)
            if ($kind -ceq 'NR') { $name='dlssnr_on_amd.ini';$folders=@($Paths.Plugins,$Paths.OldPlugins) }
            $fallback='';$shadow=Join-Path $folders[1] $name
            if (Test-Path -LiteralPath $shadow -PathType Leaf) { Assert-NoReparse $shadow;$fallback=[IO.File]::ReadAllText($shadow) }
            foreach ($folder in $folders) {
                $path=Join-Path $folder $name
                if ((Same-Path $folder $folders[1]) -and -not (Test-Path -LiteralPath $path)) { continue }
                Assert-CompleteTarget $path @(Get-CompleteBaseTargets $Paths)
                $text=$fallback
                if (Test-Path -LiteralPath $path -PathType Leaf) { $text=[IO.File]::ReadAllText($path) }
                $patched=Get-CompleteIniText $text $kind
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and $text -ceq $patched) { continue }
                $source=Join-Path $stage ('ini-'+$operations.Count+'.ini');Write-Text $source $patched
                Add-CompleteCopy $operations $source $path
            }
        }
        # An incompatible model/runtime can make its generated weights stale.
        # Keep all caches on an unchanged valid base; retire exact cache files
        # only when replacing incompatible runtime bytes, with reversible backup.
        if ($replaceExistingRuntime) {
            foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
                $weights=Join-Path $folder 'dlssnr_on_amd_weights.bin'
                if (Test-Path -LiteralPath $weights -PathType Leaf) { Assert-NoReparse $weights;$operations.Add([pscustomobject]@{Action='Delete';Source=$null;Path=$weights;InstalledExists=$false;InstalledHash=$null;GeneratedCache=$true}) }
            }
        }
        # All payloads and required downloads have been verified before the
        # first MO2 mutation. Snapshot add-on files AND its state for outer undo.
        Assert-Stopped
        $folder=New-CompleteBackup $Paths 'install'
        $destinations=@($operations.ToArray() | ForEach-Object { $_.Path })+@(Get-OwnedPaths $Paths)+@($Paths.State,$complete.State)
        $snapshots=@(New-CompleteSnapshots $destinations $folder)
        $records=New-Object 'System.Collections.Generic.List[object]'
        if ($null -ne $prior) { foreach ($entry in @($prior.Files)) { $records.Add($entry) } }
        foreach ($op in @($operations.ToArray())) {
            $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $op.Path })[0]
            $old=@($records.ToArray() | Where-Object { Same-Path $_.Path $op.Path })
            if ($old.Count) {
                $null=$records.Remove($old[0])
                # Preserve first-install originals only while those exact
                # installed bytes remain. Later user edits get their own backup.
                if (Test-CompleteInstalledRecord $old[0]) { $snapshot=$old[0] }
            }
            $records.Add([pscustomobject]@{Path=$op.Path;Existed=[bool]$snapshot.Existed;Backup=$snapshot.Backup;BeforeHash=$snapshot.BeforeHash;InstalledExists=[bool]$op.InstalledExists;InstalledHash=$op.InstalledHash;GeneratedCache=([bool](Get-Value $op 'GeneratedCache'))})
        }
        $newState=[pscustomobject]@{SchemaVersion=1;Name='MatheusNR030Complete';Root=$Paths.Root;CreatedUtc=[DateTime]::UtcNow.ToString('o');Files=@($records.ToArray());OwnsGpuDriver=$false;OwnsOptiScalerBinary=$false;OwnsXeFgBinary=$false;RuntimeVerified=$false}
        $prepared=Join-Path $folder 'prepared-complete-state.json';Write-Json $prepared $newState
        $journal=Join-Path $folder 'transaction.json'
        Write-Json $journal ([pscustomobject]@{Status='prepared';Files=$snapshots})
        try {
            foreach ($op in @($operations.ToArray())) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $op.Path) -Force | Out-Null
                if ($op.Action -ceq 'Copy') { Copy-Verified $op.Source $op.Path }
                else { Remove-Item -LiteralPath $op.Path -Force }
            }
            $null=Assert-Base $Paths
            if ($null -ne $oldAddon) {
                # Existing Setup accepts one owned INI hash across ARK/overwrite.
                # Normalize only these backed-up owned INIs before its strict
                # update, then retain the user's effective tuning afterwards.
                foreach ($location in @($Paths.Plugins,$Paths.OldPlugins)) {
                    $ini=Join-Path $location 'MatheusNR030.ini'
                    if (Test-Path -LiteralPath $ini -PathType Leaf) { Copy-Verified $stagedAddonIni $ini }
                }
                @($oldAddon.Files | Where-Object { $_.Name -ceq 'MatheusNR030.ini' })[0].InstalledHash=Get-Hash $stagedAddonIni
                Write-Json $Paths.State $oldAddon
            }
            Install-Addon $Paths $BeforeAddonOperation
            Copy-Verified $stagedAddonIni (Join-Path $Paths.Plugins 'MatheusNR030.ini')
            $installedAddon=Read-AddonState $Paths
            @($installedAddon.Files | Where-Object { $_.Name -ceq 'MatheusNR030.ini' })[0].InstalledHash=Get-Hash $stagedAddonIni
            Write-Json $Paths.State $installedAddon
            Assert-OwnedFiles $Paths $installedAddon
            Copy-Verified $prepared $complete.State
            $null=Read-CompleteState $Paths
            Write-Json $journal ([pscustomobject]@{Status='completed';Files=$snapshots})
        } catch {
            $failure=$_
            try { Restore-CompleteSnapshots $snapshots }
            catch {
                Write-Json $journal ([pscustomobject]@{Status='rollback-needs-review';Error=$failure.Exception.Message;RollbackError=$_.Exception.Message;Files=$snapshots})
                throw ('Complete install failed and rollback needs review. Keep backup '+$folder+': '+$_.Exception.Message)
            }
            Write-Json $journal ([pscustomobject]@{Status='rolled-back';Error=$failure.Exception.Message;Files=$snapshots})
            throw $failure
        }
        Write-Host 'Complete NR/model/add-on installation finished. Existing OptiScaler and XeFG binaries were preserved.'
        Write-Host 'OptiScaler configuration: Override all = 2.0; per-preset ratio override disabled. Confirm the actual input/output resolution in game.'
        Write-Host ('Undo backup: '+$folder)
        Write-Host 'Installation does not verify gameplay performance. Run 03_CHECK_ADDON.cmd after a new game session.'
    } finally { if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
function Disable-CompleteNr($Paths,[scriptblock]$BeforeOperation=$null,[switch]$ApplyRatioTwo) {
    Assert-Stopped
    if ($ApplyRatioTwo) {
        $requiredIni=Join-Path $Paths.Bin 'OptiScaler.ini'
        Assert-NoReparse $Paths.Bin;Assert-NoReparse $requiredIni
        if (-not (Test-Path -LiteralPath $Paths.Bin -PathType Container) -or -not (Test-Path -LiteralPath $requiredIni -PathType Leaf)) {
            throw ('Required existing ARK OptiScaler.ini is missing: '+$requiredIni+'. Recovery did not change game files.')
        }
    }
    $prior=Read-CompleteState $Paths;$addon=Read-AddonState $Paths
    if ($null -ne $addon) { Assert-OwnedFiles $Paths $addon -AllowModifiedIni }
    $complete=Get-CompletePaths $Paths;Assert-NoReparse $complete.Cache
    $stage=Join-Path $complete.Cache ('disable-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $operations=New-Object 'System.Collections.Generic.List[object]'
        foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
            foreach ($item in @(@('dlssnr_on_amd.ini','dlssnr_on_amd.asi','DlssNrOnAmd'),@('MatheusNR030.ini','MatheusNR030.asi','MatheusNR030'))) {
                $path=Join-Path $folder $item[0]
                if (-not (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath (Join-Path $folder $item[1]) -PathType Leaf)) { continue }
                Assert-CompleteTarget $path (@(Get-CompleteBaseTargets $Paths)+@(Get-OwnedPaths $Paths))
                $text='';if (Test-Path -LiteralPath $path -PathType Leaf) { $text=[IO.File]::ReadAllText($path) }
                $patched=Set-CompleteIniValue $text $item[2] 'Enabled' '0'
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and $patched -ceq $text) { continue }
                $source=Join-Path $stage ('disabled-'+$operations.Count+'.ini');Write-Text $source $patched
                Add-CompleteCopy $operations $source $path
            }
        }
        if ($ApplyRatioTwo) {
            $foundOpti=$false
            foreach ($location in @($Paths.Bin,$Paths.OldBin)) {
                $ini=Join-Path $location 'OptiScaler.ini'
                Assert-CompleteTarget $ini @(Get-CompleteBaseTargets $Paths)
                if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { continue }
                $foundOpti=$true
                $text=[IO.File]::ReadAllText($ini);$patched=Set-CompleteRatioTwo $text
                if ($patched -ceq $text) { continue }
                $source=Join-Path $stage ('ratio-two-'+$operations.Count+'.ini');Write-Text $source $patched
                Add-CompleteCopy $operations $source $ini
            }
            if (-not $foundOpti) { throw 'No existing ARK/overwrite OptiScaler.ini was found. Recovery did not change game files.' }
        }
        $folder=New-CompleteBackup $Paths 'disable-nr'
        $destinations=@($operations.ToArray() | ForEach-Object { $_.Path })+@($complete.State)
        if ($null -ne $addon) { $destinations += $Paths.State }
        $snapshots=@(New-CompleteSnapshots $destinations $folder)
        $records=New-Object 'System.Collections.Generic.List[object]'
        if ($null -ne $prior) { foreach ($entry in @($prior.Files)) { $records.Add($entry) } }
        foreach ($op in @($operations.ToArray() | Where-Object { [IO.Path]::GetFileName($_.Path) -cin @('dlssnr_on_amd.ini','OptiScaler.ini') })) {
            $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $op.Path })[0]
            $old=@($records.ToArray() | Where-Object { Same-Path $_.Path $op.Path })
            if ($old.Count) { $null=$records.Remove($old[0]);if (Test-CompleteInstalledRecord $old[0]) { $snapshot=$old[0] } }
            $records.Add([pscustomobject]@{Path=$op.Path;Existed=[bool]$snapshot.Existed;Backup=$snapshot.Backup;BeforeHash=$snapshot.BeforeHash;InstalledExists=$true;InstalledHash=$op.InstalledHash})
        }
        $newState=[pscustomobject]@{SchemaVersion=1;Name='MatheusNR030Complete';Root=$Paths.Root;CreatedUtc=[DateTime]::UtcNow.ToString('o');Files=@($records.ToArray());OwnsGpuDriver=$false;OwnsOptiScalerBinary=$false;OwnsXeFgBinary=$false;RuntimeVerified=$false}
        $journal=Join-Path $folder 'transaction.json';Write-Json $journal ([pscustomobject]@{Status='prepared';Files=$snapshots})
        try {
            $index=0
            foreach ($op in @($operations.ToArray())) {
                if ($null -ne $BeforeOperation) { & $BeforeOperation $index }
                New-Item -ItemType Directory -Path (Split-Path -Parent $op.Path) -Force | Out-Null
                Copy-Verified $op.Source $op.Path;$index++
            }
            if ($null -ne $addon) {
                $ini=Join-Path $Paths.Plugins 'MatheusNR030.ini'
                if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { $ini=Join-Path $Paths.OldPlugins 'MatheusNR030.ini' }
                if (Test-Path -LiteralPath $ini -PathType Leaf) { @($addon.Files | Where-Object { $_.Name -ceq 'MatheusNR030.ini' })[0].InstalledHash=Get-Hash $ini }
                Write-Json $Paths.State $addon
            }
            Write-Json $complete.State $newState
            $null=Read-CompleteState $Paths
            Write-Json $journal ([pscustomobject]@{Status='completed';Files=$snapshots})
        } catch {
            $failure=$_
            try { Restore-CompleteSnapshots $snapshots }
            catch { throw ('Disable NR rollback needs review. Keep backup '+$folder+': '+$_.Exception.Message) }
            Write-Json $journal ([pscustomobject]@{Status='rolled-back';Error=$failure.Exception.Message;Files=$snapshots})
            throw $failure
        }
        Write-Host 'Base NR and the Matheus add-on are disabled for the next game launch. Engine DLLs were preserved.'
        if ($ApplyRatioTwo) {
            Write-Host 'Configured OptiScaler Override all = 2.0 and per-preset override = false. XeFG settings and DLLs were preserved.'
            foreach ($location in @($Paths.Bin,$Paths.OldBin)) {
                $ini=Join-Path $location 'OptiScaler.ini'
                if (Test-Path -LiteralPath $ini -PathType Leaf) { Write-Host ('OptiScaler ratio 2.0 configured in: '+$ini) }
            }
            Write-Host 'Configuration changes are complete. Actual game resolution, image quality and frame-rate recovery are not verified by this script.'
        } else { Write-Host 'FSR/XeFG settings were preserved.' }
        Write-Host ('Configuration backup: '+$folder)
    } finally { if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
function Recover-CompletePerformance($Paths,[scriptblock]$BeforeOperation=$null) {
    Disable-CompleteNr $Paths $BeforeOperation -ApplyRatioTwo
}
function Restore-Complete($Paths,[scriptblock]$BeforeAddonOperation=$null) {
    Assert-Stopped
    $state=Read-CompleteState $Paths
    if ($null -eq $state) { throw 'No complete-install record exists. Nothing was restored.' }
    foreach ($entry in @($state.Files)) {
        if (Test-CompleteInstalledRecord $entry) { continue }
        # Recreating this exact generated cache is expected after gameplay.
        # The current cache is backed up in the restore transaction below,
        # then restored with its matching prior runtime/model. Ordinary edited
        # binaries and configuration files retain the strict conflict gate.
        if ((Get-Value $entry 'GeneratedCache') -eq $true -and -not $entry.InstalledExists -and
            [IO.Path]::GetFileName($entry.Path) -ceq 'dlssnr_on_amd_weights.bin' -and
            (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { continue }
        throw ('Restore conflict: a file changed since complete installation: '+$entry.Path)
    }
    $addon=Read-AddonState $Paths;Assert-OwnedFiles $Paths $addon -AllowModifiedIni
    $complete=Get-CompletePaths $Paths;$folder=New-CompleteBackup $Paths 'restore'
    $destinations=@($state.Files | ForEach-Object { $_.Path })+@(Get-OwnedPaths $Paths)+@($Paths.State,$complete.State)
    $snapshots=@(New-CompleteSnapshots $destinations $folder)
    $journal=Join-Path $folder 'transaction.json'
    Write-Json $journal ([pscustomobject]@{Status='prepared';Files=$snapshots})
    try {
        if ($null -ne $addon) { Remove-Addon $Paths $BeforeAddonOperation }
        Restore-CompleteSnapshots @($state.Files)
        Remove-Item -LiteralPath $complete.State -Force
        Write-Json $journal ([pscustomobject]@{Status='completed';Files=$snapshots})
    } catch {
        $failure=$_
        try { Restore-CompleteSnapshots $snapshots }
        catch { throw ('Restore rollback needs review. Keep backup '+$folder+': '+$_.Exception.Message) }
        Write-Json $journal ([pscustomobject]@{Status='rolled-back';Error=$failure.Exception.Message;Files=$snapshots})
        throw $failure
    }
    Write-Host 'Complete-install changes and the add-on were removed. Original recorded files were restored.'
}
function Check-Complete($Paths) {
    $report=Check-Addon $Paths
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('COMPLETE DEPENDENCY CHECK')
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        $ini=Join-Path $folder 'OptiScaler.ini'
        if ((Same-Path $folder $Paths.OldBin) -and -not (Test-Path -LiteralPath $ini)) { continue }
        try {
            Assert-NoReparse $ini
            if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { throw 'OptiScaler.ini is missing.' }
            $text=[IO.File]::ReadAllText($ini)
            $all=Read-IniValue $text 'UpscaleRatio' 'UpscaleRatioOverrideEnabled'
            $ratio=Read-IniValue $text 'UpscaleRatio' 'UpscaleRatioOverrideValue'
            $perPreset=Read-IniValue $text 'QualityOverrides' 'QualityRatioOverrideEnabled'
            # OptiScaler can serialize 2.0 as 2.000000. Compare the invariant
            # numeric value. Global override must remain explicitly enabled.
            # The documented per-preset default is false; keep its raw value
            # separate from this configuration interpretation, not runtime proof.
            $perPresetEffective='unknown';$perPresetSource='unrecognized'
            if ($null -eq $perPreset) { $perPresetEffective='false';$perPresetSource='default_missing' }
            elseif ($perPreset -ieq 'auto') { $perPresetEffective='false';$perPresetSource='default_auto' }
            elseif ($perPreset -ieq 'false') { $perPresetEffective='false';$perPresetSource='explicit' }
            elseif ($perPreset -ieq 'true') { $perPresetEffective='true';$perPresetSource='explicit' }
            $numericRatio=0.0
            $ratioParsed=[double]::TryParse($ratio,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$numericRatio)
            $matchesRequested=($all -ieq 'true' -and $ratioParsed -and $numericRatio -eq 2.0 -and $perPresetEffective -ceq 'false')
            $lines.Add('OptiScaler configured ratio: '+$ini+'; OverrideAll='+$all+'; Ratio='+$ratio+'; PerPresetOverride='+$perPreset+'; ExpectedRatio=2.0; MatchesRequested='+$matchesRequested+'; GameRuntimeVerified=false; PerPresetEffective='+$perPresetEffective+'; PerPresetSource='+$perPresetSource)
        } catch { $lines.Add('OptiScaler configured ratio: '+$ini+'; ExpectedRatio=2.0; NOT CONFIRMED - '+$_.Exception.Message) }
    }
    $lines.Add('The ratio check reads configuration only. Confirm actual input/output resolution in the new game session.')
    foreach ($dependency in $script:CompleteDependencies) {
        foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
            $path=Join-Path $folder $dependency.Name
            if ((Same-Path $folder $Paths.OldPlugins) -and -not (Test-Path -LiteralPath $path)) { continue }
            $status='MISSING';$actual=''
            if (Test-Path -LiteralPath $path -PathType Leaf) { $status='MISMATCH';$actual=Get-Hash $path;if (Test-CompleteFile $path $dependency.Size $dependency.Sha256) { $status='PASS' } }
            $lines.Add($dependency.Name+': '+$status+'; path='+$path+'; actual_sha256='+$actual+'; expected_sha256='+$dependency.Sha256)
        }
    }
    try { $hip=Get-CompleteHipPath $Paths;$lines.Add('AMD HIP runtime file: '+$hip) } catch { $lines.Add('AMD HIP: '+$_.Exception.Message) }
    try { $state=Read-CompleteState $Paths;$lines.Add('Complete-install record present: '+($null -ne $state)) } catch { $lines.Add('Complete-install record: '+$_.Exception.Message) }
    foreach ($line in $lines) { Write-Host $line }
    return ($report+"`r`n"+($lines -join "`r`n"))
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $completeRequestedRoot
        switch ($completeRequestedAction) {
            'Install' { Install-Complete $paths }
            'Remove' { Remove-Addon $paths }
            'RestoreComplete' { Restore-Complete $paths }
            'DisableNr' { Disable-CompleteNr $paths }
            'RecoverPerformance' { Recover-CompletePerformance $paths }
            'Check' {
                $report=Check-Complete $paths
                $results=Join-Path $script:PackageRoot 'Results';Assert-NoReparse $results
                New-Item -ItemType Directory -Path $results -Force | Out-Null
                Write-Text (Join-Path $results 'MATHEUS_CHECK.txt') $report
            }
        }
        exit 0
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
