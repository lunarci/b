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
        }
        if ($inventory.Count -eq 0) { throw 'No relevant logs or INIs were found under the selected MO2 root.' }
        Write-Json (Join-Path $stage 'inventory.json') @($inventory.ToArray())
        $report=Check-Complete $Paths 6>$null
        Write-Text (Join-Path $stage 'MATHEUS_CHECK.txt') $report
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=Join-Path $results ($name+'.zip')
        [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
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
