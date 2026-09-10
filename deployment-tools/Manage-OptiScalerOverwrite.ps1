[CmdletBinding()]
param(
    [ValidateSet('Check','Apply','Restore')][string]$Action = 'Check',
    [string]$OverwritePath,
    [string]$BuildManifestPath,
    [string]$BackupBase,
    [string]$BackupManifestPath,
    [switch]$Headless,
    [switch]$LoadFunctionsOnly
)

# Windows PowerShell 5.1. No game folder, mod source, INI, or Root Builder state is written.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-Within([string]$Path, [string]$Root) {
    $prefix = (Get-FullPath $Root) + [IO.Path]::DirectorySeparatorChar
    return (Get-FullPath $Path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparse([string]$Path) {
    $current = Get-FullPath $Path
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points or symbolic links are not supported: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-OverwriteSelection([string]$Path) {
    $full = Get-FullPath $Path
    Assert-NoReparse $full
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Overwrite folder not found: $full" }
    $leaf = [IO.Path]::GetFileName($full)
    $layouts = @('Root/bin/x64', 'bin/x64')
    $root = $full
    if ($leaf -ieq 'x64') {
        $bin = [IO.Path]::GetDirectoryName($full)
        if ([IO.Path]::GetFileName($bin) -ine 'bin') { throw 'Select overwrite, overwrite/Root/bin/x64, or overwrite/bin/x64.' }
        $root = [IO.Path]::GetDirectoryName($bin)
        if ([IO.Path]::GetFileName($root) -ieq 'Root') {
            $root = [IO.Path]::GetDirectoryName($root)
            $layouts = @('Root/bin/x64')
        } else { $layouts = @('bin/x64') }
    }
    if ([IO.Path]::GetFileName($root) -ine 'overwrite') { throw 'The selected folder must be an MO2 folder named overwrite, or its supported bin/x64 subfolder.' }
    if ([string]::IsNullOrEmpty([IO.Path]::GetDirectoryName($root))) { throw 'A filesystem root cannot be selected.' }
    return [pscustomobject]@{ Root = $root; Layouts = $layouts }
}

function Convert-SafeRelative([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'The manifest contains an empty path.' }
    $p = $Path.Replace('\','/')
    if ($p.StartsWith('/') -or $p -match '^[A-Za-z]:' -or $p.Contains(':')) { throw "Rooted paths are not allowed: $Path" }
    foreach ($part in $p.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..' -or
            $part -match '[<>"|?*]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '[\x00-\x1f]') { throw "Unsafe relative path: $Path" }
    }
    return $p
}

function Join-Safe([string]$Root, [string]$Relative) {
    $relativePath = Convert-SafeRelative $Relative
    $path = Get-FullPath ([IO.Path]::Combine($Root, $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-Within $path $Root)) { throw "Path escapes the selected folder: $Relative" }
    Assert-NoReparse $path
    return $path
}

function Get-PayloadSelection([string]$ManifestPath) {
    Assert-NoReparse $ManifestPath
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.PSObject.Properties['files']) { throw 'The build manifest has no files object.' }
    $result = @()
    $seen = @{}
    foreach ($property in $manifest.files.PSObject.Properties) {
        $relative = Convert-SafeRelative $property.Name
        if ($seen.ContainsKey($relative)) { throw "Duplicate manifest path: $relative" }
        $seen[$relative] = $true
        if ($relative -notmatch '^Root/bin/x64/(.+)$') { continue }
        $tail = $Matches[1]
        $leaf = ($tail.Split('/'))[-1]
        $eligible = ($tail -ieq 'dxgi.dll') -or
            ($tail -match '^OptiScaler/.+\.dll$' -and $leaf -notmatch '^(version|winmm|dxgi|ReShade.*)\.dll$')
        if (-not $eligible) { continue }
        if ([string]$property.Value -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA256 in build manifest: $relative" }
        $result += [pscustomobject]@{ Relative = $relative; Tail = $tail; Sha256 = ([string]$property.Value).ToLowerInvariant() }
    }
    if ($result.Count -eq 0) { throw 'The build manifest contains no eligible OptiScaler DLLs.' }
    return $result
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-OptiScalerIdentity([string]$Path, [string]$KnownHash) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $description = ([string]$info.ProductName) + ' ' + ([string]$info.FileDescription)
    if ($description -match 'ReShade') { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 128 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { return $false }
    $pe = [BitConverter]::ToInt32($bytes, 60)
    if ($pe -lt 64 -or $pe -gt $bytes.Length - 24 -or
        [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664 -or
        ([BitConverter]::ToUInt16($bytes, $pe + 22) -band 0x2000) -eq 0) { return $false }
    if ($description -match 'OptiScaler') { return $true }
    if ((Get-Sha256 $Path) -eq $KnownHash) { return $true }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    # The product's own version banner is stronger than a generic import/reference string.
    return $ascii.Contains('OptiScaler v') -and -not $ascii.Contains('ReShade by crosire')
}

function Save-BackupManifest([string]$Path, $Manifest) {
    Assert-NoReparse $Path
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $bytes = $encoding.GetBytes(($Manifest | ConvertTo-Json -Depth 12))
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Get-BackupBase([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable; supply BackupBase.' }
        $Path = Join-Path $env:LOCALAPPDATA 'OptiScalerHUDResource/Backups'
    }
    $full = Get-FullPath $Path
    Assert-NoReparse $full
    return $full
}

function Restore-FileAtomic([string]$BackupPath, [string]$TargetPath, [string]$ExpectedHash) {
    Assert-NoReparse $TargetPath
    if (Test-Path -LiteralPath $TargetPath) { throw "Restore target already exists: $TargetPath" }
    $parent = [IO.Path]::GetDirectoryName($TargetPath)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    # Same-directory temporary file makes the final no-clobber rename atomic even
    # when the external backup lives on another volume.
    $temp = Join-Path $parent ('.optiscaler-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($BackupPath, $temp, $false)
        if ((Get-Sha256 $temp) -ne $ExpectedHash) { throw "Restore staging hash mismatch: $TargetPath" }
        Assert-NoReparse $TargetPath
        [IO.File]::Move($temp, $TargetPath)
    } finally {
        if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
    }
}

function Invoke-OverwriteOperation {
    [CmdletBinding()]
    param(
        [ValidateSet('Check','Apply','Restore')][string]$Action = 'Check',
        [string]$OverwritePath, [string]$BuildManifestPath, [string]$BackupBase,
        [string]$BackupManifestPath,
        # Injection points are available only to dot-sourced, isolated fixture tests.
        [scriptblock]$IdentityVerifier = { param($p,$h) Test-OptiScalerIdentity $p $h },
        [scriptblock]$GameRunningCheck = { [bool](Get-Process -Name Cyberpunk2077 -ErrorAction SilentlyContinue) }
    )
    if ($Action -ne 'Check' -and (& $GameRunningCheck)) { throw 'Close Cyberpunk 2077 and run Root Builder Clear before using Apply or Restore.' }
    if ($Action -eq 'Restore') {
        $backupRoot = Get-BackupBase $BackupBase
        $manifestPath = Get-FullPath $BackupManifestPath
        if (-not (Test-Within $manifestPath $backupRoot) -or [IO.Path]::GetFileName($manifestPath) -ine 'manifest.json') { throw 'Select a manifest.json from the external backup folder.' }
        Assert-NoReparse $manifestPath
        $runDir = [IO.Path]::GetDirectoryName($manifestPath)
        $guidValue = [guid]::Empty
        if (-not [guid]::TryParse([IO.Path]::GetFileName($runDir), [ref]$guidValue) -or
            (Get-FullPath ([IO.Path]::GetDirectoryName($runDir))) -ine $backupRoot) { throw 'Invalid backup transaction folder.' }
        $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($record.Schema -ne 1) { throw 'Unsupported backup manifest.' }
        $selection = Get-OverwriteSelection ([string]$record.OverwriteRoot)
        if (Test-Within $runDir $selection.Root) { throw 'Backups must be outside Overwrite.' }
        $entries = @($record.Files | Where-Object { $_.Status -in @('RemovalPending','Removed') })
        $seen = @{}
        foreach ($entry in $entries) {
            $rel = Convert-SafeRelative ([string]$entry.RelativePath)
            if ($rel -notmatch '^(Root/)?bin/x64/(dxgi\.dll|OptiScaler/.+\.dll)$' -or
                ($rel -match '/OptiScaler/(.*/)?(version|winmm|dxgi|ReShade.*)\.dll$')) { throw "Non-eligible restore path: $rel" }
            if ($seen.ContainsKey($rel)) { throw "Duplicate restore path: $rel" }; $seen[$rel] = $true
            $sourcePath = Join-Safe $selection.Root $rel
            if ($sourcePath -ine (Get-FullPath ([string]$entry.SourcePath))) { throw 'The recorded source path does not match Overwrite.' }
            $backupPath = Join-Safe $runDir ('files/' + $rel)
            if ($entry.OldSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
                -not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
                (Get-Sha256 $backupPath) -ne $entry.OldSha256) { throw "Backup verification failed: $rel" }
            if ((Test-Path -LiteralPath $sourcePath) -and
                (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or (Get-Sha256 $sourcePath) -ne $entry.OldSha256)) {
                throw "Restore would overwrite a changed file: $sourcePath"
            }
        }
        $restored = @()
        try {
            foreach ($entry in $entries) {
                $target = Join-Safe $selection.Root $entry.RelativePath
                if (-not (Test-Path -LiteralPath $target)) {
                    $backupPath = Join-Safe $runDir ('files/' + $entry.RelativePath)
                    Restore-FileAtomic $backupPath $target $entry.OldSha256
                    $restored += $entry
                    if ((Get-Sha256 $target) -ne $entry.OldSha256) { throw "Restored hash mismatch: $target" }
                }
            }
            foreach ($entry in $entries) { $entry.Status = 'Restored' }
            $record.State = 'Restored'
            Save-BackupManifest $manifestPath $record
        } catch {
            $errorText = $_.Exception.Message
            $rollbackErrors = @()
            foreach ($entry in $restored) {
                try {
                    $target = Join-Safe $selection.Root $entry.RelativePath
                    if ((Get-Sha256 $target) -ne $entry.OldSha256) { throw 'Newly restored file changed; preserved it.' }
                    [IO.File]::Delete($target)
                } catch { $rollbackErrors += $_.Exception.Message }
            }
            throw "Restore failed: $errorText. Backups remain at $runDir. Rollback errors: $($rollbackErrors -join '; ')"
        }
        return [pscustomobject]@{ Action='Restore'; Count=$entries.Count; Files=$entries; BackupManifestPath=$manifestPath }
    }

    $selection = Get-OverwriteSelection $OverwritePath
    $payload = @(Get-PayloadSelection $BuildManifestPath)
    $candidates = @()
    foreach ($layout in $selection.Layouts) {
        foreach ($item in $payload) {
            $relative = $layout + '/' + $item.Tail
            $path = Join-Safe $selection.Root $relative
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "A file path is a directory: $path" }
            $hash = Get-Sha256 $path
            if ($item.Tail -ieq 'dxgi.dll' -and -not (& $IdentityVerifier $path $item.Sha256)) {
                throw "dxgi.dll could not be identified as OptiScaler. No files were changed: $path"
            }
            $candidates += [pscustomobject]@{ SourcePath=$path; RelativePath=$relative; OldSha256=$hash; Status='Pending' }
        }
    }
    if ($Action -eq 'Check' -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ Action=$Action; Count=$candidates.Count; Files=$candidates; BackupManifestPath=$null }
    }
    $backupRoot = Get-BackupBase $BackupBase
    if ($backupRoot -ieq $selection.Root -or (Test-Within $backupRoot $selection.Root) -or (Test-Within $selection.Root $backupRoot)) {
        throw 'The backup folder must be separate from the selected Overwrite tree.'
    }
    $runDir = Join-Path $backupRoot ([guid]::NewGuid().ToString())
    Assert-NoReparse $runDir
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    $manifestPath = Join-Path $runDir 'manifest.json'
    $record = [pscustomobject]@{
        Schema=1; State='Preparing'; CreatedUtc=[DateTime]::UtcNow.ToString('o');
        OverwriteRoot=$selection.Root; BuildManifestSha256=(Get-Sha256 $BuildManifestPath);
        RootBuilderClearPerformedByTool=$false; Files=$candidates
    }
    Save-BackupManifest $manifestPath $record
    $removed = @()
    try {
        # Phase one: all backups must be verified before the first source deletion.
        foreach ($entry in $candidates) {
            Assert-NoReparse $entry.SourcePath
            if ((Get-Sha256 $entry.SourcePath) -ne $entry.OldSha256) { throw "Source changed: $($entry.SourcePath)" }
            $destination = Join-Safe $runDir ('files/' + $entry.RelativePath)
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.File]::Copy($entry.SourcePath, $destination, $false)
            if ((Get-Sha256 $destination) -ne $entry.OldSha256) { throw "Backup hash mismatch: $($entry.SourcePath)" }
            $entry.Status = 'BackedUp'
        }
        $record.State = 'BackedUp'; Save-BackupManifest $manifestPath $record
        foreach ($entry in $candidates) {
            Assert-NoReparse $entry.SourcePath
            if ((Get-Sha256 $entry.SourcePath) -ne $entry.OldSha256) { throw "Source changed before removal: $($entry.SourcePath)" }
            $entry.Status = 'RemovalPending'
            Save-BackupManifest $manifestPath $record
            $removed += $entry
            [IO.File]::Delete($entry.SourcePath)
            $entry.Status = 'Removed'
            Save-BackupManifest $manifestPath $record
        }
        $record.State = 'Applied'; Save-BackupManifest $manifestPath $record
    } catch {
        $errorText = $_.Exception.Message
        $rollbackErrors = @()
        foreach ($entry in $removed) {
            try {
                $target = Join-Safe $selection.Root $entry.RelativePath
                if (Test-Path -LiteralPath $target) {
                    if ((Get-Sha256 $target) -ne $entry.OldSha256) { throw 'Source changed; preserved it.' }
                } else {
                    $saved = Join-Safe $runDir ('files/' + $entry.RelativePath)
                    if ((Get-Sha256 $saved) -ne $entry.OldSha256) { throw 'Backup changed; cannot restore.' }
                    Restore-FileAtomic $saved $target $entry.OldSha256
                    if ((Get-Sha256 $target) -ne $entry.OldSha256) { throw 'Rollback hash mismatch.' }
                }
                $entry.Status = 'RolledBack'
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        $record.State = $(if ($rollbackErrors.Count) { 'RollbackFailed' } else { 'RolledBack' })
        try { Save-BackupManifest $manifestPath $record } catch { $rollbackErrors += $_.Exception.Message }
        throw "Apply failed: $errorText. Backup manifest: $manifestPath. Rollback errors: $($rollbackErrors -join '; ')"
    }
    return [pscustomobject]@{ Action='Apply'; Count=$candidates.Count; Files=$candidates; BackupManifestPath=$manifestPath }
}

if ($LoadFunctionsOnly) { return }

try {
    if ([string]::IsNullOrWhiteSpace($BuildManifestPath)) { $BuildManifestPath = Join-Path $PSScriptRoot '../_PackageDocs/BUILD.json' }
    if ($Action -eq 'Restore') {
        if ([string]::IsNullOrWhiteSpace($BackupManifestPath)) {
            if ($Headless) { throw 'Restore requires BackupManifestPath in headless mode.' }
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Title = 'Select the exact OptiScaler Overwrite backup manifest to restore'
            $dialog.Filter = 'Backup manifest (manifest.json)|manifest.json'
            $dialog.InitialDirectory = Get-BackupBase $BackupBase
            if ($dialog.ShowDialog() -ne 'OK') { exit 0 }
            $BackupManifestPath = $dialog.FileName
        }
    } elseif ([string]::IsNullOrWhiteSpace($OverwritePath)) {
        $defaultOverwrite = 'C:\CYBERPUNK_ARK_PACK_MO2\overwrite'
        if (Test-Path -LiteralPath $defaultOverwrite -PathType Container) { $OverwritePath = $defaultOverwrite }
        elseif ($Headless) { throw 'Supply OverwritePath in headless mode.' }
        else {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Select your MO2 overwrite folder. Close the game and run Root Builder Clear first.'
            if ($dialog.ShowDialog() -ne 'OK') { exit 0 }
            $OverwritePath = $dialog.SelectedPath
        }
    }
    $result = Invoke-OverwriteOperation -Action $Action -OverwritePath $OverwritePath -BuildManifestPath $BuildManifestPath -BackupBase $BackupBase -BackupManifestPath $BackupManifestPath
    Write-Output ("{0}: {1} matching file(s)." -f $result.Action,$result.Count)
    foreach ($file in $result.Files) { Write-Output $file.SourcePath }
    if ($result.BackupManifestPath) { Write-Output ("Backup manifest: " + $result.BackupManifestPath) }
    Write-Output 'This tool does not run Root Builder Clear. INI files and CET bindings are unchanged.'
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
