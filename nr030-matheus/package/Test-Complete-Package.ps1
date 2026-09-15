#requires -Version 5.1
[CmdletBinding()]
param()
$componentRoot=$PSScriptRoot
. (Join-Path $componentRoot 'Complete-Setup.ps1') -Action Check
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$productionHash=$script:ExpectedNrHash
$productionPackage=$script:PackageRoot
$productionDependencies=$script:CompleteDependencies
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('MatheusNR030-CompleteTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-CompleteTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('ASSERTION: '+$Message) } }
function Assert-CompleteThrows([scriptblock]$Code,[string]$Pattern) {
    $failure=$null;try { & $Code | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure) { throw ('Expected failure: '+$Pattern) }
    if ($failure.Exception.Message -notmatch $Pattern) { throw ('Unexpected failure: '+$failure.Exception.Message+'; expected '+$Pattern) }
}
function Write-CompleteFakePe([string]$Path,[byte]$Marker) {
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[20]=$Marker;$bytes[60]=0x80
    $bytes[128]=0x50;$bytes[129]=0x45;$bytes[132]=0x64;$bytes[133]=0x86;$bytes[151]=0x20
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function New-CompleteFixture([string]$Name) {
    $root=Join-Path $fixtureRoot $Name;$package=Join-Path $root 'package'
    $payload=Join-Path $package 'payload';$paths=Get-Paths (Join-Path $root 'MO2');$archives=Join-Path $root 'archives'
    foreach ($folder in @($payload,$paths.Plugins,$archives)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $componentRoot 'protected-files.json') -Destination (Join-Path $package 'protected-files.json')
    $script:PackageRoot=$package
    Write-CompleteFakePe (Join-Path $paths.Plugins 'dlssnr_on_amd.asi') 1
    Write-CompleteFakePe (Join-Path $paths.Plugins 'nvngx_dlssnr.dll') 2
    Write-CompleteFakePe (Join-Path $paths.Bin 'amdhip64_7.dll') 3
    Write-CompleteFakePe (Join-Path $paths.Bin 'dxgi.dll') 4
    Write-CompleteFakePe (Join-Path $paths.Bin 'libxell.dll') 5
    Write-Text (Join-Path $paths.Plugins 'dlssnr_on_amd.ini') "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`nTone=0.42`r`n"
    Write-Text (Join-Path $paths.Bin 'OptiScaler.ini') @"
[Upscalers]
Dx12Upscaler=ffx
[FrameGen]
FGInput=dlssg
FGOutput=xefg
[Inputs]
EnableDlssInputs=true
EnableFfxInputs=false
[Plugins]
LoadAsiPlugins=true
Path=plugins
[XeFG]
InterpolationCount=3
[UpscaleRatio]
UpscaleRatioOverrideEnabled=true
UpscaleRatioOverrideValue=2.0
[QualityOverrides]
QualityRatioOverrideEnabled=false
QualityRatioOverrideValue=1.7
[Sharpness]
Value=0.37
[Libraries]
XeFGPath=C:\existing\alternative\provider
"@
    $script:ExpectedNrHash=Get-Hash (Join-Path $paths.Plugins 'dlssnr_on_amd.asi')
    Write-CompleteFakePe (Join-Path $payload 'MatheusNR030.asi') 6
    Write-Text (Join-Path $payload 'MatheusNR030.ini') "[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nDiagnostics=1`r`nLumaStabilityPercent=100`r`n"
    $files=@()
    foreach ($name in $script:AddonNames) {
        $path=Join-Path $payload $name;$files += [pscustomobject]@{name=$name;sha256=(Get-Hash $path);size=(Get-Item -LiteralPath $path).Length}
    }
    Write-Json (Join-Path $package 'package-manifest.json') ([pscustomobject]@{
        schema_version=1;addon_name='MatheusNR030';addon_version='synthetic-complete-test';base_nr_sha256=$script:ExpectedNrHash
        source_commit=('a'*40);build_run_id='1234567890';build_verified=$true;abi_verified=$true
        build_evidence='https://github.com/lunarci/b/actions/runs/1234567890';abi_evidence='synthetic fixtures only'
        game_runtime_verified=$false;runtime_log_schema='matheusnr030-events-v1';files=$files
    })
    $dependencies=@();$sources=@{}
    foreach ($definition in @(@('dlssnr_on_amd.asi','version-original.dll','nr.zip'),@('nvngx_dlssnr.dll','nvngx_dlssnr.dll','model.zip'))) {
        $source=Join-Path $paths.Plugins $definition[0];$archive=Join-Path $archives $definition[2]
        $zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
        try { $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$source,('nested/'+$definition[1])) } finally { $zip.Dispose() }
        $url='https://fixture.invalid/'+$definition[2];$sources[$url]=$archive
        $dependencies += [pscustomobject]@{Name=$definition[0];Entry=$definition[1];Size=(Get-Item -LiteralPath $source).Length;Sha256=(Get-Hash $source);Archive=$definition[2];ArchiveSize=(Get-Item -LiteralPath $archive).Length;ArchiveSha256=(Get-Hash $archive);Url=$url}
    }
    # Only this dot-sourced fixture scope changes pinning. The production CLI
    # has no hash/URL/HIP/download callback arguments.
    $script:CompleteDependencies=$dependencies
    $counter=[pscustomobject]@{Count=0}
    $download={param($Url,$Destination,$MaximumBytes) $counter.Count++;Copy-Item -LiteralPath $sources[$Url] -Destination $Destination}.GetNewClosure()
    return [pscustomobject]@{Root=$root;Paths=$paths;Package=$package;Download=$download;Counter=$counter;Sources=$sources}
}
function Get-CompleteGameSnapshot($Paths) {
    $snapshot=@{}
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        if (Test-Path -LiteralPath $folder -PathType Container) { foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse -Force)) { $snapshot[$file.FullName]=Get-Hash $file.FullName } }
    }
    foreach ($path in @($Paths.State,$Paths.BaseState,(Get-CompletePaths $Paths).State)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $snapshot[$path]=Get-Hash $path }
    }
    return $snapshot
}
function Assert-CompleteSnapshot($Paths,$Before) {
    $after=Get-CompleteGameSnapshot $Paths
    Assert-CompleteTest ($after.Count -eq $Before.Count) 'Game file inventory changed.'
    foreach ($path in $Before.Keys) { Assert-CompleteTest ($after.ContainsKey($path) -and $after[$path] -ceq $Before[$path]) ('Game file changed: '+$path) }
}
function Remove-CompleteFixtureDependencies($Fixture) {
    foreach ($dependency in $script:CompleteDependencies) { Remove-Item -LiteralPath (Join-Path $Fixture.Paths.Plugins $dependency.Name) }
}
function Run-CompleteCase([string]$Name,[scriptblock]$Code) {
    try {
        $fixture=New-CompleteFixture $Name
        & $Code $fixture
        $results.Add([pscustomobject]@{Test=$Name;Status='PASS'});Write-Host ('PASS '+$Name)
    } catch {
        $results.Add([pscustomobject]@{Test=$Name;Status='FAIL';Error=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage})
        Write-Host ('FAIL '+$Name+': '+$_.Exception.Message);Write-Host $_.ScriptStackTrace
    } finally { $script:ExpectedNrHash=$productionHash;$script:PackageRoot=$productionPackage;$script:CompleteDependencies=$productionDependencies }
}

try {
    Assert-CompleteTest ($productionDependencies.Count -eq 2 -and $productionDependencies[0].Sha256 -ceq $productionHash) 'Production dependency pins changed unexpectedly.'
    Run-CompleteCase 'verified-existing-base-reused-without-network' {
        param($f)
        $before=Get-ProtectedSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Valid installed files triggered a download.'
        Assert-SnapshotUnchanged $f.Paths $before
        Assert-CompleteTest (-not (Test-Path -LiteralPath $f.Paths.BaseState)) 'Legacy base metadata was fabricated.'
        Assert-CompleteTest ((Read-CompleteState $f.Paths).Files.Count -eq 0) 'Unchanged base files were adopted.'
    }
    Run-CompleteCase 'absent-nr-model-and-inis-downloaded-before-install' {
        param($f)
        Remove-CompleteFixtureDependencies $f
        Remove-Item -LiteralPath (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.ini')
        Remove-Item -LiteralPath (Join-Path $f.Paths.Bin 'OptiScaler.ini')
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ($f.Counter.Count -eq 2) 'Missing dependencies were not downloaded exactly once.'
        $null=Assert-Base $f.Paths
        Assert-CompleteTest ((Read-CompleteState $f.Paths).Files.Count -eq 4) 'Created dependency/INI files not tracked.'
        Assert-CompleteTest (-not (Test-Path -LiteralPath $f.Paths.BaseState)) 'Legacy JSON was synthesized.'
    }
    Run-CompleteCase 'verified-overwrite-base-reused-and-shadow-preserved' {
        param($f)
        New-Item -ItemType Directory -Path $f.Paths.OldPlugins -Force | Out-Null
        foreach ($dep in $script:CompleteDependencies) { Move-Item -LiteralPath (Join-Path $f.Paths.Plugins $dep.Name) -Destination (Join-Path $f.Paths.OldPlugins $dep.Name) }
        $oldNr=Get-Hash (Join-Path $f.Paths.OldPlugins 'dlssnr_on_amd.asi')
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Valid overwrite files caused network downloads.'
        Assert-CompleteTest ((Get-Hash (Join-Path $f.Paths.OldPlugins 'dlssnr_on_amd.asi')) -ceq $oldNr) 'Valid overwrite base was altered.'
        $null=Assert-Base $f.Paths
    }
    Run-CompleteCase 'verified-local-input-reused-without-network' {
        param($f)
        $input=Join-Path $f.Package 'input';New-Item -ItemType Directory -Path $input | Out-Null
        foreach ($dep in $script:CompleteDependencies) { Move-Item -LiteralPath (Join-Path $f.Paths.Plugins $dep.Name) -Destination (Join-Path $input $dep.Name) }
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Local verified inputs caused network downloads.'
    }
    Run-CompleteCase 'corrupt-download-blocked-before-game-writes' {
        param($f)
        Remove-CompleteFixtureDependencies $f;$before=Get-CompleteGameSnapshot $f.Paths
        $bad={param($Url,$Destination,$MaximumBytes) [IO.File]::WriteAllText($Destination,'CORRUPT')}
        Assert-CompleteThrows { Install-Complete $f.Paths $bad } 'archive SHA-256/size mismatch'
        Assert-CompleteSnapshot $f.Paths $before
        Assert-CompleteTest (-not (Test-Path -LiteralPath (Get-CompletePaths $f.Paths).Backup)) 'Corrupt download created game backup/state.'
        Assert-CompleteTest (@(Get-ChildItem -LiteralPath (Get-CompletePaths $f.Paths).Cache -Filter '*.part' -Recurse).Count -eq 0) 'Download .part was left behind.'
    }
    Run-CompleteCase 'second-download-failure-leaves-base-unchanged' {
        param($f)
        Remove-CompleteFixtureDependencies $f;$before=Get-CompleteGameSnapshot $f.Paths
        $source=$f.Sources[$script:CompleteDependencies[0].Url]
        $partial={param($Url,$Destination,$MaximumBytes) if ($Url.EndsWith('/model.zip')) { throw 'simulated second download failure' };Copy-Item -LiteralPath $source -Destination $Destination}.GetNewClosure()
        Assert-CompleteThrows { Install-Complete $f.Paths $partial } 'second download failure'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'corrupt-extracted-payload-blocked-before-game-writes' {
        param($f)
        Remove-CompleteFixtureDependencies $f
        $dep=$script:CompleteDependencies[0];$archive=$f.Sources[$dep.Url]
        Remove-Item -LiteralPath $archive
        $wrong=Join-Path $f.Root 'wrong.dll';Write-CompleteFakePe $wrong 99
        $zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
        try { $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$wrong,$dep.Entry) } finally { $zip.Dispose() }
        $dep.ArchiveSha256=Get-Hash $archive;$dep.ArchiveSize=(Get-Item -LiteralPath $archive).Length
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download } 'Extracted dependency SHA-256/size mismatch'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'failed-addon-step-rolls-back-new-base-and-state' {
        param($f)
        Remove-CompleteFixtureDependencies $f
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5'))
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download {param($Index) if ($Index -eq 1) { throw 'simulated add-on failure' }} } 'simulated add-on failure'
        Assert-CompleteSnapshot $f.Paths $before
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($ini)) 'UpscaleRatio' 'UpscaleRatioOverrideValue') -ceq '1.5') 'Failed installation did not restore the previous 1.5 ratio.'
        Assert-CompleteTest (-not (Test-Path -LiteralPath $f.Paths.State)) 'Failed install left add-on state.'
        Assert-CompleteTest (-not (Test-Path -LiteralPath (Get-CompletePaths $f.Paths).State)) 'Failed install left complete state.'
    }
    Run-CompleteCase 'idempotent-reinstall-retains-original-backups' {
        param($f)
        Remove-CompleteFixtureDependencies $f;$before=Get-CompleteGameSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        $original=@((Read-CompleteState $f.Paths).Files)
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ($f.Counter.Count -eq 2) 'Reinstall downloaded valid installed dependencies.'
        $again=@((Read-CompleteState $f.Paths).Files)
        Assert-CompleteTest ($again.Count -eq $original.Count) 'Reinstall duplicated ownership records.'
        foreach ($entry in $original) { $match=@($again | Where-Object { Same-Path $_.Path $entry.Path })[0];Assert-CompleteTest ($match.Backup -ceq $entry.Backup) 'Original restoration point lost.' }
        Restore-Complete $f.Paths
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'requested-ratio-two-replaces-one-point-five-preserving-other-settings' {
        param($f)
        $path=Join-Path $f.Paths.Bin 'OptiScaler.ini';$text=[IO.File]::ReadAllText($path)
        $text=$text.Replace('Dx12Upscaler=ffx','Dx12Upscaler=dlss').Replace('InterpolationCount=3','InterpolationCount=1')
        $text=$text.Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5').Replace('UpscaleRatioOverrideEnabled=true','UpscaleRatioOverrideEnabled=false').Replace('QualityRatioOverrideEnabled=false','QualityRatioOverrideEnabled=true')
        Write-Text $path $text;$originalHash=Get-Hash $path
        Install-Complete $f.Paths $f.Download
        $updated=[IO.File]::ReadAllText($path)
        Assert-CompleteTest ((Read-IniValue $updated 'UpscaleRatio' 'UpscaleRatioOverrideValue') -ceq '2.0') 'Requested 2.0 ratio was not applied.'
        Assert-CompleteTest ((Read-IniValue $updated 'UpscaleRatio' 'UpscaleRatioOverrideEnabled') -ceq 'true') 'Override all was not enabled.'
        Assert-CompleteTest ((Read-IniValue $updated 'QualityOverrides' 'QualityRatioOverrideEnabled') -ceq 'false') 'Per-preset override was not disabled.'
        Assert-CompleteTest ((Read-IniValue $updated 'QualityOverrides' 'QualityRatioOverrideValue') -ceq '1.7') 'Stored per-preset numeric ratio was changed.'
        Assert-CompleteTest ((Read-IniValue $updated 'Sharpness' 'Value') -ceq '0.37') 'Sharpness changed.'
        Assert-CompleteTest ((Read-IniValue $updated 'Libraries' 'XeFGPath') -ceq 'C:\existing\alternative\provider') 'Alternate XeFG path changed.'
        Restore-Complete $f.Paths
        Assert-CompleteTest ((Get-Hash $path) -ceq $originalHash) 'INI did not restore byte-for-byte.'
    }
    Run-CompleteCase 'requested-ratio-two-updates-both-ark-and-overwrite-ini' {
        param($f)
        New-Item -ItemType Directory -Path $f.Paths.OldBin -Force | Out-Null
        $primary=Join-Path $f.Paths.Bin 'OptiScaler.ini';$shadow=Join-Path $f.Paths.OldBin 'OptiScaler.ini'
        $text=[IO.File]::ReadAllText($primary).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5')
        Write-Text $primary $text
        Write-Text $shadow ($text.Replace('Value=0.37','Value=0.42').Replace('QualityRatioOverrideEnabled=false','QualityRatioOverrideEnabled=true'))
        $before=Get-CompleteGameSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        foreach ($path in @($primary,$shadow)) {
            $updated=[IO.File]::ReadAllText($path)
            Assert-CompleteTest ((Read-IniValue $updated 'UpscaleRatio' 'UpscaleRatioOverrideValue') -ceq '2.0') 'A shadowing ratio remains at 1.5.'
            Assert-CompleteTest ((Read-IniValue $updated 'XeFG' 'InterpolationCount') -ceq '3') 'XeFG 4X changed.'
        }
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($shadow)) 'Sharpness' 'Value') -ceq '0.42') 'Overwrite-specific unrelated setting was reset.'
        Restore-Complete $f.Paths
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'ratio-check-reports-configured-expectation-without-runtime-claim' {
        param($f)
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5'))
        $before=Get-CompleteGameSnapshot $f.Paths
        $report=Check-Complete $f.Paths
        Assert-CompleteTest ($report.Contains('Ratio=1.5; PerPresetOverride=false; ExpectedRatio=2.0; MatchesRequested=False; GameRuntimeVerified=false')) 'Check did not distinguish configured ratio from the requested value.'
        Assert-CompleteTest ($report.Contains('The ratio check reads configuration only.')) 'Check overstates configuration as runtime proof.'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'changed-runtime-and-old-weights-backed-up-and-restored' {
        param($f)
        Write-CompleteFakePe (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi') 99
        Write-Text (Join-Path $f.Paths.Plugins 'dlssnr_on_amd_weights.bin') 'PREVIOUS GENERATED CACHE'
        $before=Get-CompleteGameSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest (-not (Test-Path -LiteralPath (Join-Path $f.Paths.Plugins 'dlssnr_on_amd_weights.bin'))) 'Incompatible runtime weights were retained.'
        Restore-Complete $f.Paths
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'unchanged-valid-base-keeps-weights-byte-for-byte' {
        param($f)
        $path=Join-Path $f.Paths.Plugins 'dlssnr_on_amd_weights.bin';Write-Text $path 'VALID EXISTING CACHE';$hash=Get-Hash $path
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ((Get-Hash $path) -ceq $hash) 'Unchanged valid base lost weights.'
    }
    Run-CompleteCase 'regenerated-weights-are-backed-up-and-do-not-block-restore' {
        param($f)
        Write-CompleteFakePe (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi') 99
        $weights=Join-Path $f.Paths.Plugins 'dlssnr_on_amd_weights.bin'
        Write-Text $weights 'OLD MODEL GENERATED CACHE'
        $before=Get-CompleteGameSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        Write-Text $weights 'NEW MODEL REGENERATED CACHE AFTER GAMEPLAY'
        $generatedHash=Get-Hash $weights
        Restore-Complete $f.Paths
        Assert-CompleteSnapshot $f.Paths $before
        $saved=@(Get-ChildItem -LiteralPath (Get-CompletePaths $f.Paths).Backup -Directory -Filter 'restore-*' | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter 'before-*.bin' } | Where-Object { (Get-Hash $_.FullName) -ceq $generatedHash })
        Assert-CompleteTest ($saved.Count -eq 1) 'The newer generated cache was not backed up before restoring the prior cache.'
    }
    Run-CompleteCase 'restore-conflict-blocks-all-writes' {
        param($f)
        Remove-CompleteFixtureDependencies $f;Install-Complete $f.Paths $f.Download
        Write-Text (Join-Path $f.Paths.Plugins 'nvngx_dlssnr.dll') 'USER REPLACED MODEL'
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Restore-Complete $f.Paths } 'Restore conflict'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'unowned-addon-executable-blocked-before-download' {
        param($f)
        Remove-CompleteFixtureDependencies $f;Write-CompleteFakePe (Join-Path $f.Paths.Plugins 'MatheusNR030.asi') 7
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download } 'Unowned add-on-named file'
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Ownership failure triggered a download.'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'owned-addon-upgrade-preserves-tuned-ini-and-state' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'
        Write-Text $ini "[MatheusNR030]`r`nEnabled=1`r`nScalePercent=75`r`nDiagnostics=0`r`nUserComment=keep`r`n"
        Install-Complete $f.Paths $f.Download
        $text=[IO.File]::ReadAllText($ini)
        Assert-CompleteTest ((Read-IniValue $text 'MatheusNR030' 'ScalePercent') -ceq '75') 'Tuned scale reset.'
        Assert-CompleteTest ((Read-IniValue $text 'MatheusNR030' 'Diagnostics') -ceq '0') 'Tuned diagnostics reset.'
        Assert-CompleteTest ((Read-IniValue $text 'MatheusNR030' 'UserComment') -ceq 'keep') 'Unrelated user key lost.'
        Assert-CompleteTest ((Read-IniValue $text 'MatheusNR030' 'LumaStabilityPercent') -ceq '100') 'New stability default was not merged into existing tuning.'
        Write-Text $ini (Set-CompleteIniValue $text 'MatheusNR030' 'LumaStabilityPercent' '35')
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($ini)) 'MatheusNR030' 'LumaStabilityPercent') -ceq '35') 'Existing stability tuning was reset.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths)
        Remove-Addon $f.Paths
    }
    Run-CompleteCase 'failed-upgrade-restores-old-addon-and-ownership' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Plugins 'MatheusNR030.ini';Write-Text $ini "[MatheusNR030]`r`nEnabled=0`r`nScalePercent=75`r`n"
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download {param($Index) if ($Index -eq 1) { throw 'upgrade transaction failure' }} } 'upgrade transaction failure'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'default-remove-leaves-installed-base-in-place' {
        param($f)
        Remove-CompleteFixtureDependencies $f;Install-Complete $f.Paths $f.Download
        $before=Get-ProtectedSnapshot $f.Paths
        Remove-Addon $f.Paths
        Assert-SnapshotUnchanged $f.Paths $before
        Assert-CompleteTest ($null -ne (Read-CompleteState $f.Paths)) 'Default remove discarded base ownership.'
    }
    Run-CompleteCase 'missing-hip-stops-before-network-or-game-write' {
        param($f)
        Remove-CompleteFixtureDependencies $f;$before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download $null {param($Paths) throw 'AMD HIP 7 runtime missing fixture'} } 'AMD HIP 7 runtime'
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Missing HIP triggered network writes.'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'http-dependency-source-is-rejected' {
        param($f)
        Assert-CompleteThrows { Save-CompleteDownload 'http://fixture.invalid/nr.zip' (Join-Path $f.Root 'must-not-exist.part') 1000 } 'require HTTPS'
        Assert-CompleteTest (-not (Test-Path -LiteralPath (Join-Path $f.Root 'must-not-exist.part'))) 'HTTP request wrote a file.'
    }
    Run-CompleteCase 'duplicate-required-ini-key-stops-before-game-write' {
        param($f)
        $path=Join-Path $f.Paths.Plugins 'dlssnr_on_amd.ini';Write-Text $path "[DlssNrOnAmd]`nEnabled=1`nEnabled=0`nPreUpscale=1`nAsync=0`n"
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Install-Complete $f.Paths $f.Download } 'Ambiguous duplicate INI key'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'disable-nr-preserves-fsr-xefg-and-reinstall-reenables' {
        param($f)
        Install-Complete $f.Paths $f.Download
        $opti=Join-Path $f.Paths.Bin 'OptiScaler.ini';$optiHash=Get-Hash $opti
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($opti)) 'UpscaleRatio' 'UpscaleRatioOverrideValue') -ceq '2.0') 'Install did not configure ratio 2.0.'
        $nr=Join-Path $f.Paths.Plugins 'dlssnr_on_amd.ini';$addon=Join-Path $f.Paths.Plugins 'MatheusNR030.ini'
        $nrBinaryHash=Get-Hash (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi')
        Disable-CompleteNr $f.Paths
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($nr)) 'DlssNrOnAmd' 'Enabled') -ceq '0') 'Base NR was not disabled.'
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($addon)) 'MatheusNR030' 'Enabled') -ceq '0') 'Add-on was not disabled.'
        Assert-CompleteTest ((Get-Hash $opti) -ceq $optiHash) 'Disable changed FSR/XeFG settings.'
        Assert-CompleteTest ((Get-Hash (Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi')) -ceq $nrBinaryHash) 'Disable changed engine bytes.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths)
        Disable-CompleteNr $f.Paths
        Install-Complete $f.Paths $f.Download
        Assert-CompleteTest ((Get-Hash $opti) -ceq $optiHash) 'Disable/reinstall changed the selected 2.0 ratio or unrelated OptiScaler settings.'
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($nr)) 'DlssNrOnAmd' 'Enabled') -ceq '1') 'Install did not re-enable NR.'
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($addon)) 'MatheusNR030' 'Enabled') -ceq '1') 'Install did not re-enable add-on.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths)
    }
    Run-CompleteCase 'disable-nr-failure-restores-all-ini-and-state-bytes' {
        param($f)
        Install-Complete $f.Paths $f.Download;$before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Disable-CompleteNr $f.Paths {param($Index) if ($Index -eq 1) { throw 'disable transaction failure' }} } 'disable transaction failure'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'disabled-install-can-restore-complete-originals' {
        param($f)
        Remove-CompleteFixtureDependencies $f;$before=Get-CompleteGameSnapshot $f.Paths
        Install-Complete $f.Paths $f.Download
        Disable-CompleteNr $f.Paths
        Restore-Complete $f.Paths
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'standalone-recovery-configures-two-and-disables-both-nr-layers' {
        param($f)
        Install-Addon $f.Paths
        New-Item -ItemType Directory -Path $f.Paths.OldPlugins -Force | Out-Null
        foreach ($name in @('dlssnr_on_amd.ini','MatheusNR030.ini')) { Copy-Item -LiteralPath (Join-Path $f.Paths.Plugins $name) -Destination (Join-Path $f.Paths.OldPlugins $name) }
        $primary=Join-Path $f.Paths.Bin 'OptiScaler.ini';$shadow=Join-Path $f.Paths.OldBin 'OptiScaler.ini'
        $text=[IO.File]::ReadAllText($primary).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5').Replace('UpscaleRatioOverrideEnabled=true','UpscaleRatioOverrideEnabled=false').Replace('QualityRatioOverrideEnabled=false','QualityRatioOverrideEnabled=true')
        Write-Text $primary $text;Write-Text $shadow ($text.Replace('Value=0.37','Value=0.42'))
        # The standalone recovery ZIP contains scripts only. No ASI payload,
        # manifest, package policy, or HIP check/download is needed to recover.
        Remove-Item -LiteralPath (Join-Path $f.Package 'payload') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $f.Package 'package-manifest.json')
        Remove-Item -LiteralPath (Join-Path $f.Package 'protected-files.json')
        Remove-Item -LiteralPath (Join-Path $f.Paths.Bin 'amdhip64_7.dll')
        $binaryHashes=@{}
        foreach ($path in @((Join-Path $f.Paths.Bin 'dxgi.dll'),(Join-Path $f.Paths.Bin 'libxell.dll'),(Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi'),(Join-Path $f.Paths.Plugins 'nvngx_dlssnr.dll'),(Join-Path $f.Paths.Plugins 'MatheusNR030.asi'))) { $binaryHashes[$path]=Get-Hash $path }
        # Preserve the original information records; Out-String can wrap them
        # to the console width in Windows PowerShell 5.1, including file paths.
        $messages=(@(Recover-CompletePerformance $f.Paths 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        foreach ($path in @($primary,$shadow)) {
            $updated=[IO.File]::ReadAllText($path)
            Assert-CompleteTest ((Read-IniValue $updated 'UpscaleRatio' 'UpscaleRatioOverrideEnabled') -ceq 'true') 'Recovery did not enable Override all.'
            Assert-CompleteTest ((Read-IniValue $updated 'UpscaleRatio' 'UpscaleRatioOverrideValue') -ceq '2.0') 'Recovery did not apply 2.0 to each OptiScaler INI.'
            Assert-CompleteTest ((Read-IniValue $updated 'QualityOverrides' 'QualityRatioOverrideEnabled') -ceq 'false') 'Recovery left per-preset override enabled.'
            Assert-CompleteTest ((Read-IniValue $updated 'QualityOverrides' 'QualityRatioOverrideValue') -ceq '1.7') 'Recovery modified stored per-preset values.'
            Assert-CompleteTest ((Read-IniValue $updated 'XeFG' 'InterpolationCount') -ceq '3') 'Recovery changed XeFG 4X.'
            Assert-CompleteTest ((Read-IniValue $updated 'Libraries' 'XeFGPath') -ceq 'C:\existing\alternative\provider') 'Recovery changed the XeFG DLL path.'
        }
        Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText($shadow)) 'Sharpness' 'Value') -ceq '0.42') 'Recovery reset overwrite-specific sharpness.'
        foreach ($location in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText((Join-Path $location 'dlssnr_on_amd.ini'))) 'DlssNrOnAmd' 'Enabled') -ceq '0') 'Base NR remains enabled.'
            Assert-CompleteTest ((Read-IniValue ([IO.File]::ReadAllText((Join-Path $location 'MatheusNR030.ini'))) 'MatheusNR030' 'Enabled') -ceq '0') 'The add-on remains enabled.'
        }
        foreach ($path in $binaryHashes.Keys) { Assert-CompleteTest ((Get-Hash $path) -ceq $binaryHashes[$path]) 'Recovery modified an engine DLL/ASI.' }
        Assert-CompleteTest ($f.Counter.Count -eq 0) 'Standalone recovery downloaded something.'
        Assert-CompleteTest ($messages.Contains('Actual game resolution, image quality and frame-rate recovery are not verified by this script.')) 'Recovery output overstates configuration changes as game proof.'
        Assert-CompleteTest ($messages.Contains('OptiScaler ratio 2.0 configured in: '+$primary) -and $messages.Contains('OptiScaler ratio 2.0 configured in: '+$shadow)) 'Recovery output omitted actual OptiScaler INI paths.'
        Assert-OwnedFiles $f.Paths (Read-AddonState $f.Paths)
    }
    Run-CompleteCase 'recovery-failure-rolls-back-ratio-enabled-flags-and-state' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5'))
        New-Item -ItemType Directory -Path $f.Paths.OldBin -Force | Out-Null
        Copy-Item -LiteralPath $ini -Destination (Join-Path $f.Paths.OldBin 'OptiScaler.ini')
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Recover-CompletePerformance $f.Paths {param($Index) if ($Index -eq 3) { throw 'recovery transaction failure after first ratio edit' }} } 'recovery transaction failure'
        Assert-CompleteSnapshot $f.Paths $before
    }
    Run-CompleteCase 'original-disable-action-keeps-existing-one-point-five-ratio' {
        param($f)
        Install-Addon $f.Paths
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini).Replace('UpscaleRatioOverrideValue=2.0','UpscaleRatioOverrideValue=1.5'))
        $hash=Get-Hash $ini
        Disable-CompleteNr $f.Paths
        Assert-CompleteTest ((Get-Hash $ini) -ceq $hash) 'Original DisableNr unexpectedly changes the ratio.'
    }
    Run-CompleteCase 'recovery-missing-primary-opti-ini-stops-before-changes' {
        param($f)
        Install-Addon $f.Paths
        Remove-Item -LiteralPath (Join-Path $f.Paths.Bin 'OptiScaler.ini')
        $before=Get-CompleteGameSnapshot $f.Paths
        Assert-CompleteThrows { Recover-CompletePerformance $f.Paths } 'Required existing ARK OptiScaler.ini is missing'
        Assert-CompleteSnapshot $f.Paths $before
        Assert-CompleteTest (-not (Test-Path -LiteralPath (Get-CompletePaths $f.Paths).Backup)) 'Missing primary INI created a recovery transaction.'
    }
} finally {
    $script:ExpectedNrHash=$productionHash;$script:PackageRoot=$productionPackage;$script:CompleteDependencies=$productionDependencies
    $out=Join-Path $componentRoot 'test-results';New-Item -ItemType Directory -Path $out -Force | Out-Null
    $failed=@($results.ToArray() | Where-Object { $_.Status -ceq 'FAIL' }).Count
    $report=[pscustomobject]@{
        Suite='complete-package-installer';PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        WindowsPowerShell51=($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        Passed=($results.Count-$failed);Failed=$failed;Tests=@($results.ToArray());GameRuntimeVerified=$false
    }
    Write-Json (Join-Path $out 'complete-installer-tests.json') $report
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
if ($failed) { throw ($failed.ToString()+' complete-installer tests failed.') }
Write-Host ($results.Count.ToString()+' complete-installer tests passed.')
