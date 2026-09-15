#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Effect25','Effect50','Effect0','Collect')][string]$Action='Collect',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2'
)
$motionAction=$Action
$motionRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Complete-Setup.ps1') -Action Check
$script:Motion024Hash='8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d'

function Set-MotionEffect($Paths,[ValidateSet(0,25,50)][int]$Percent,[scriptblock]$BeforeOperation=$null) {
    Assert-Stopped
    $state=Read-AddonState $Paths
    Assert-OwnedFiles $Paths $state -AllowModifiedIni
    $primary=Join-Path $Paths.Plugins 'MatheusNR030.asi'
    if (-not (Test-Path -LiteralPath $primary -PathType Leaf)) { throw 'Installed 0.2.4 add-on is missing. This tool changes existing settings only.' }
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach ($folder in @($Paths.Plugins,$Paths.OldPlugins)) {
        $asi=Join-Path $folder 'MatheusNR030.asi'
        Assert-NoReparse $asi
        if ((Test-Path -LiteralPath $asi) -and (Get-Hash $asi) -cne $script:Motion024Hash) {
            throw ('This control requires the exact 0.2.4 ASI; no settings changed: '+$asi)
        }
        $ini=Join-Path $folder 'MatheusNR030.ini'
        Assert-NoReparse $ini
        if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
            if (Same-Path $folder $Paths.Plugins) { throw ('Installed add-on INI is missing: '+$ini) }
            continue
        }
        $text=[IO.File]::ReadAllText($ini)
        # Parse every file before any mutation; preserve all other settings.
        $previous=Read-IniValue $text 'MatheusNR030' 'EffectPercent'
        $patched=Set-CompleteIniValue $text 'MatheusNR030' 'EffectPercent' ([string]$Percent)
        $items.Add([pscustomobject]@{Path=$ini;Text=$patched;Before=$previous})
    }
    $before=Get-ProtectedSnapshot $Paths
    $folder=New-BackupFolder $Paths ('effect-'+$Percent)
    $operations=New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $items) {
        $source=Join-Path $folder ('setting-'+$operations.Count+'.ini')
        Write-Text $source $item.Text
        $operations.Add([pscustomobject]@{Path=$item.Path;Action='Copy';Source=$source})
    }
    Assert-Stopped
    Invoke-OwnTransaction $Paths @($operations.ToArray()) $folder $before $BeforeOperation
    foreach ($item in $items) { Write-Host ('EffectPercent '+$item.Before+' -> '+$Percent+': '+$item.Path) }
    Write-Host ('Settings backup: '+$folder)
    Write-Host 'Configuration written. Restart the game to apply. This does not verify visual quality or reduce NR inference cost.'
    if ($Percent -eq 0) { Write-Host 'Effect 0 hides the NR correction while NR processing remains enabled. Use optional\SET_EFFECT_50.cmd to restore the previous strength of 50.' }
}

function Collect-MotionEvidence($Paths) {
    Assert-Stopped
    $results=Join-Path $script:PackageRoot 'Results'
    Assert-NoReparse $results
    New-Item -ItemType Directory -Path $results -Force | Out-Null
    $name='MOTION_EVIDENCE-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $stage=Join-Path $results $name
    New-Item -ItemType Directory -Path $stage | Out-Null
    $inventory=New-Object 'System.Collections.Generic.List[object]'
    $notes=New-Object 'System.Collections.Generic.List[string]'
    $notes.Add('Collection UTC: '+[DateTime]::UtcNow.ToString('o'))
    $notes.Add('File timestamps and INI settings do not prove that a log belongs to the latest game session. Default logs are retained separately from configured logs.')
    try {
        foreach ($location in @(@('ark',$Paths.Bin,$Paths.Plugins),@('overwrite',$Paths.OldBin,$Paths.OldPlugins))) {
            $dest=Join-Path $stage $location[0]
            New-Item -ItemType Directory -Path $dest | Out-Null
            foreach ($entry in @(
                @($location[1],'OptiScaler.ini'),@($location[1],'OptiScaler.log'),
                @($location[2],'dlssnr_on_amd.ini'),@($location[2],'dlssnr_on_amd.log'),
                @($location[2],'MatheusNR030.ini'),@($location[2],'MatheusNR030.log'))) {
                $path=Join-Path $entry[0] $entry[1]
                Assert-NoReparse $path
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                if ((Get-Item -LiteralPath $path).Length -gt 256MB) { throw ('Log exceeds 256 MiB; no incomplete evidence ZIP will be presented: '+$path) }
                $copy=Join-Path $dest $entry[1]
                Copy-Verified $path $copy
                $inventory.Add([pscustomobject]@{Source=$path;Entry=($location[0]+'/'+$entry[1]);Size=(Get-Item -LiteralPath $copy).Length;Sha256=(Get-Hash $copy);ModifiedUtc=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o')})
            }
            $optiIni=Join-Path $location[1] 'OptiScaler.ini'
            if (-not (Test-Path -LiteralPath $optiIni -PathType Leaf)) { continue }
            try {
                $optiText=[IO.File]::ReadAllText($optiIni)
                $configured=Read-IniValue $optiText 'Log' 'LogFileName'
                $logToFile=Read-IniValue $optiText 'Log' 'LogToFile'
                $logLevel=Read-IniValue $optiText 'Log' 'LogLevel'
                $singleFile=Read-IniValue $optiText 'Log' 'SingleFile'
                $notes.Add($location[0]+': LogToFile='+$logToFile+'; LogLevel='+$logLevel+'; SingleFile='+$singleFile+'; LogFileName='+$configured)
                if ($singleFile -ieq 'false') { $notes.Add('CONFIGURED_LOG_SESSION_SUFFIX_NOT_COLLECTED '+$location[0]+': SingleFile=false may create suffixed session logs; this collector only copies the exact configured filename.') }
            } catch {
                $notes.Add('CONFIGURED_LOG_INI_PARSE_ERROR '+$optiIni+': '+$_.Exception.Message)
                continue
            }
            if ([string]::IsNullOrWhiteSpace($configured) -or $configured -ieq 'auto') { continue }
            if (-not [IO.Path]::IsPathRooted($configured)) {
                $notes.Add('CONFIGURED_LOG_RELATIVE_PATH_UNRESOLVED '+$configured)
                continue
            }
            $configured=Full-Path $configured
            $rootPrefix=(Full-Path $Paths.Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if (-not $configured.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                $notes.Add('CONFIGURED_LOG_OUTSIDE_ROOT '+$configured)
                continue
            }
            if ([IO.Path]::GetExtension($configured) -ine '.log') {
                $notes.Add('CONFIGURED_LOG_INVALID_EXTENSION '+$configured)
                continue
            }
            Assert-NoReparse $configured
            if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
                $notes.Add('CONFIGURED_LOG_MISSING '+$configured)
                continue
            }
            if ((Get-Item -LiteralPath $configured).Length -gt 256MB) { throw ('Log exceeds 256 MiB; no incomplete evidence ZIP will be presented: '+$configured) }
            $configuredLabel='configured-'+$location[0]
            $configuredDest=Join-Path $stage $configuredLabel
            New-Item -ItemType Directory -Path $configuredDest | Out-Null
            $copy=Join-Path $configuredDest 'OptiScaler-configured.log'
            Copy-Verified $configured $copy
            $inventory.Add([pscustomobject]@{Source=$configured;Entry=($configuredLabel+'/OptiScaler-configured.log');Size=(Get-Item -LiteralPath $copy).Length;Sha256=(Get-Hash $copy);ModifiedUtc=(Get-Item -LiteralPath $configured).LastWriteTimeUtc.ToString('o')})
        }
        if ($inventory.Count -eq 0) { throw 'No relevant logs or INIs were found under the selected MO2 root.' }
        Write-Text (Join-Path $stage 'COLLECTION_NOTES.txt') ($notes -join "`r`n")
        Write-Json (Join-Path $stage 'inventory.json') @($inventory.ToArray())
        $report=Check-Complete $Paths 6>$null
        Write-Text (Join-Path $stage 'MATHEUS_CHECK.txt') $report
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=Join-Path $results ($name+'.zip')
        # .NET Framework may use backslashes for CreateFromDirectory entries.
        # Use portable ZIP names that match inventory.json on every runtime.
        $archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $stage -File -Recurse)) {
                $entryName=$file.FullName.Substring($stage.Length+1).Replace('\','/')
                $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$entryName,[IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
        Write-Host ('Full logs and INIs saved: '+$zip)
        Write-Host 'This ZIP stays on your PC. It is not uploaded automatically.'
        return $zip
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $motionRoot
        switch ($motionAction) {
            'Effect25' { Set-MotionEffect $paths 25 }
            'Effect50' { Set-MotionEffect $paths 50 }
            'Effect0' { Set-MotionEffect $paths 0 }
            'Collect' { $null=Collect-MotionEvidence $paths }
        }
        exit 0
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
