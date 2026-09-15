#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageZip,
    [string]$OutputPath
)
# Windows PowerShell 5.1 does not populate PSScriptRoot during default binding.
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath=Join-Path $PSScriptRoot 'test-results/xefg-guard-package-tests.json'
}
$testZip=[IO.Path]::GetFullPath($PackageZip)
$testOutput=[IO.Path]::GetFullPath($OutputPath)
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('XeFGGuardPackageTests-'+[guid]::NewGuid().ToString('N'))
$extractRoot=Join-Path $fixtureRoot 'extracted'
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($testZip,$extractRoot)
$guardExtractedPackageRoot=Join-Path $extractRoot 'Matheus_NR030_XeFGBarrierGuard'
. (Join-Path $guardExtractedPackageRoot 'Original-Color-Control.ps1') -Action Status
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$productionBaseline=$script:OriginalColorBaselineHash
$productionPrevious=$script:OriginalColorPreviousDiagnosticHash
$productionPredication=$script:OriginalColorPredicationHash
$productionNr=$script:ExpectedNrHash
$archiveHash=Get-Hash $testZip
$builtPayloadHash=Get-Hash (Join-Path $guardExtractedPackageRoot 'payload/MatheusNR030.asi')
$results=New-Object 'System.Collections.Generic.List[object]'

function Assert-GuardPackage([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('ASSERTION: '+$Message) }
}
function Write-GuardFixturePe([string]$Path,[byte]$Marker) {
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[60]=64;$bytes[64]=0x50;$bytes[65]=0x45
    $bytes[68]=0x64;$bytes[69]=0x86;$bytes[87]=0x20;$bytes[100]=$Marker
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function Get-GuardFixtureSnapshot($Paths) {
    $snapshot=@{}
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse)) { $snapshot[$file.FullName]=Get-Hash $file.FullName }
        }
    }
    if (Test-Path -LiteralPath $Paths.State -PathType Leaf) { $snapshot[$Paths.State]=Get-Hash $Paths.State }
    return $snapshot
}
function Assert-GuardFixtureSnapshot($Paths,$Before,[switch]$AllowAddonReplacement) {
    $after=Get-GuardFixtureSnapshot $Paths
    Assert-GuardPackage ($after.Count -eq $Before.Count) 'Installation changed the game file inventory.'
    foreach ($path in $Before.Keys) {
        if ($AllowAddonReplacement -and ($path -ceq $Paths.State -or [IO.Path]::GetFileName($path) -ceq 'MatheusNR030.asi')) { continue }
        Assert-GuardPackage ($after.ContainsKey($path) -and $after[$path] -ceq $Before[$path]) ('Unrelated INI/binary or original state changed: '+$path)
    }
}
function New-GuardStagePackage([string]$Root,[string]$NrHash,[string]$PayloadSource) {
    $null=New-Item -ItemType Directory -Path (Join-Path $Root 'payload') -Force
    Copy-Item -LiteralPath (Join-Path $guardExtractedPackageRoot 'protected-files.json') -Destination $Root
    Copy-Item -LiteralPath (Join-Path $guardExtractedPackageRoot 'payload/MatheusNR030.ini') -Destination (Join-Path $Root 'payload/MatheusNR030.ini')
    Copy-Item -LiteralPath $PayloadSource -Destination (Join-Path $Root 'payload/MatheusNR030.asi')
    $manifest=Read-Json (Join-Path $guardExtractedPackageRoot 'package-manifest.json')
    # Only temporary fixtures replace the base pin. The distributed ZIP and
    # production constants are never edited, and no payload code is executed.
    $manifest.base_nr_sha256=$NrHash
    foreach ($entry in $manifest.files) {
        $path=Join-Path $Root ('payload/'+$entry.name)
        $entry.sha256=Get-Hash $path;$entry.size=(Get-Item -LiteralPath $path).Length
    }
    Write-Json (Join-Path $Root 'package-manifest.json') $manifest
}
function New-GuardFixture([string]$Name,[bool]$WithOverwrite) {
    $root=Join-Path $fixtureRoot $Name;$paths=Get-Paths (Join-Path $root 'MO2')
    $folders=@($paths.Bin)
    if ($WithOverwrite) { $folders += $paths.OldBin }
    foreach ($bin in $folders) {
        $plugins=Join-Path $bin 'plugins';$null=New-Item -ItemType Directory -Path $plugins -Force
        Write-GuardFixturePe (Join-Path $plugins 'MatheusNR030.asi') 1
        Write-GuardFixturePe (Join-Path $plugins 'dlssnr_on_amd.asi') 2
        Write-Text (Join-Path $plugins 'MatheusNR030.ini') "; synthetic current settings`r`n[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nEffectPercent=0`r`nColourPreservationPercent=100`r`nDepthProtection=1`r`nDiagnostics=1`r`nLumaStabilityPercent=100`r`n"
        [IO.File]::WriteAllText((Join-Path $plugins 'dlssnr_on_amd.ini'),"`r`n[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`nSkinStructure=0`n",[Text.Encoding]::Unicode)
        Write-Text (Join-Path $bin 'OptiScaler.ini') "[Upscalers]`r`nDx12Upscaler = ffx`r`n[FrameGen]`r`nEnabled = true`r`nFGInput = DLSSG`r`nFGOutput = XeFG`r`n[XeFG]`r`nInterpolationCount = 4`r`n[UpscaleRatio]`r`nUpscaleRatioOverrideEnabled = true`r`nUpscaleRatioOverrideValue = 2.000000`r`n[QualityOverrides]`r`nQualityRatioOverrideEnabled = auto`r`n[Log]`r`nLogToFile = true`r`nLogLevel = 1`r`n"
        foreach ($name in @('dxgi.dll','libxell.dll','libxess_fg.dll','OptiScaler_DLSS5.ini')) { Write-Text (Join-Path $bin $name) ('UNRELATED SYNTHETIC FILE '+$name) }
        foreach ($name in @('nvngx_dlssnr.dll','dlssnr_on_amd_weights.bin')) { Write-Text (Join-Path $plugins $name) ('EXISTING SYNTHETIC NR FILE '+$name) }
    }
    $script:OriginalColorBaselineHash=Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.asi')
    $script:ExpectedNrHash=Get-Hash (Join-Path $paths.Plugins 'dlssnr_on_amd.asi')
    $null=New-Item -ItemType Directory -Path $paths.Backup -Force
    Write-Json $paths.State ([pscustomobject]@{SchemaVersion=1;AddonName='MatheusNR030';PluginFolder=$paths.Plugins;AddonVersion='synthetic-baseline';Files=@([pscustomobject]@{Name='MatheusNR030.asi';InstalledHash=$script:OriginalColorBaselineHash},[pscustomobject]@{Name='MatheusNR030.ini';InstalledHash=(Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.ini'))});RuntimeVerified=$false})
    $predicationPayload=Join-Path $root 'previous-predication.asi';Write-GuardFixturePe $predicationPayload 4
    $script:OriginalColorPredicationHash=Get-Hash $predicationPayload
    $predicationPackage=Join-Path $root 'predication-package'
    New-GuardStagePackage $predicationPackage $script:ExpectedNrHash $predicationPayload
    $guardPackage=Join-Path $root 'guard-package'
    New-GuardStagePackage $guardPackage $script:ExpectedNrHash (Join-Path $guardExtractedPackageRoot 'payload/MatheusNR030.asi')
    return [pscustomobject]@{Paths=$paths;PredicationPackage=$predicationPackage;GuardPackage=$guardPackage;Original=(Get-GuardFixtureSnapshot $paths)}
}
function Run-GuardPackageCase([string]$Name,[scriptblock]$Body) {
    try { & $Body;$results.Add([pscustomobject]@{Name=$Name;Status='PASS'});Write-Host ('PASS '+$Name) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) }
    finally {
        $script:OriginalColorBaselineHash=$productionBaseline;$script:OriginalColorPreviousDiagnosticHash=$productionPrevious
        $script:OriginalColorPredicationHash=$productionPredication;$script:ExpectedNrHash=$productionNr;$script:PackageRoot=$guardExtractedPackageRoot
    }
}
try {
    Run-GuardPackageCase 'packaged-entry-points-preserve-settings-and-recognize-exact-predication-source' {
        $apply=[IO.File]::ReadAllText((Join-Path $guardExtractedPackageRoot '01_APPLY_FIX.cmd'))
        $restore=[IO.File]::ReadAllText((Join-Path $guardExtractedPackageRoot '02_RESTORE_PREVIOUS.cmd'))
        $collect=[IO.File]::ReadAllText((Join-Path $guardExtractedPackageRoot '03_COLLECT_LOGS.cmd'))
        Assert-GuardPackage ($apply -match 'Original-Color-Control\.ps1' -and $apply -match '-Action\s+Apply\s+-PreserveEffect' -and $apply -notmatch 'Complete-Setup|RecoverPerformance|DisableNr') 'Apply wrapper does not use only the preserving add-on installer.'
        Assert-GuardPackage ($restore -match 'Original-Color-Control\.ps1' -and $restore -match '-Action\s+Restore') 'Restore wrapper does not use the verified original backup chain.'
        Assert-GuardPackage ($collect -match 'Collect-Opti-RuntimeEvidence\.ps1' -and $collect -notmatch '-Action\s+(Enable|Disable)|Complete-Setup') 'Collect wrapper changes settings or uses the wrong evidence collector.'
        Assert-GuardPackage ($productionPredication -ceq '9da458986e1a7f0a9a45f979b08b04017ef2f1f2b6c384926b89ecc05d27638b') 'The exact delivered PredicationFix SHA is not pinned.'
        Assert-GuardPackage (Test-OriginalColorKnownSource $productionPredication) 'The currently installed PredicationFix is rejected as an upgrade source.'
        Assert-GuardPackage (-not (Test-OriginalColorKnownSource ('f'*64))) 'An arbitrary prior ASI is accepted.'
        $null=Get-VerifiedManifest
    }
    foreach ($withOverwrite in @($false,$true)) {
        $caseName=if ($withOverwrite) { 'owned-predication-upgrade-overwrite-preserves-all-settings-and-original-chain' } else { 'owned-predication-upgrade-primary-preserves-all-settings-and-original-chain' }
        Run-GuardPackageCase $caseName {
            $f=New-GuardFixture $caseName $withOverwrite
            $script:PackageRoot=$f.PredicationPackage
            # Cover both historic Effect ownership and the later preserving-only chain.
            if ($withOverwrite) { Invoke-OriginalColorControl $f.Paths Apply }
            else { Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect }
            $priorState=Read-AddonState $f.Paths;$priorTrial=Read-OriginalColorTrial $f.Paths $priorState
            Assert-GuardPackage ($priorTrial.TargetHash -ceq $script:OriginalColorPredicationHash) 'Fixture is not an owned active predication trial.'
            $before=Get-GuardFixtureSnapshot $f.Paths
            $script:PackageRoot=$f.GuardPackage
            Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
            Assert-GuardFixtureSnapshot $f.Paths $before -AllowAddonReplacement
            $state=Read-AddonState $f.Paths;$trial=Read-OriginalColorTrial $f.Paths $state
            Assert-GuardPackage ($trial.TargetHash -ceq $builtPayloadHash) 'Built guard ASI was not installed.'
            Assert-GuardPackage ($trial.BackupFolder -ceq $priorTrial.BackupFolder -and $trial.OriginalStateHash -ceq $priorTrial.OriginalStateHash) 'Upgrade replaced the original backup chain.'
            if ($withOverwrite) {
                Assert-GuardPackage ((Get-OriginalColorJsonHash $trial.EffectFiles) -ceq (Get-OriginalColorJsonHash $priorTrial.EffectFiles)) 'Upgrade changed historical Effect restore ownership.'
            } else { Assert-GuardPackage ($null -eq $trial.PSObject.Properties['EffectFiles']) 'Preserving installation fabricated Effect ownership.' }
            $installed=Get-GuardFixtureSnapshot $f.Paths
            Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
            Assert-GuardFixtureSnapshot $f.Paths $installed
            Invoke-OriginalColorControl $f.Paths Restore
            Assert-GuardFixtureSnapshot $f.Paths $f.Original
            if (-not $withOverwrite) { Assert-GuardPackage (-not (Test-Path -LiteralPath $f.Paths.OldBin)) 'Installer created an absent overwrite copy.' }
        }
    }
    Run-GuardPackageCase 'changed-predication-binary-blocks-upgrade-without-game-writes' {
        $f=New-GuardFixture 'changed-input' $true
        $script:PackageRoot=$f.PredicationPackage;Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect
        Write-GuardFixturePe (Join-Path $f.Paths.OldPlugins 'MatheusNR030.asi') 99
        $before=Get-GuardFixtureSnapshot $f.Paths;$script:PackageRoot=$f.GuardPackage
        $failure=$null;try { Invoke-OriginalColorControl $f.Paths Apply -PreserveEffect } catch { $failure=$_ }
        Assert-GuardPackage ($null -ne $failure -and $failure.Exception.Message -match 'Modified add-on file') 'Changed installed ASI was not rejected.'
        Assert-GuardFixtureSnapshot $f.Paths $before
    }
    Assert-GuardPackage ((Get-Hash $testZip) -ceq $archiveHash) 'Distributed package ZIP was modified by the tests.'
} finally {
    $failed=@($results.ToArray() | Where-Object { $_.Status -ceq 'FAIL' }).Count
    $report=[pscustomobject]@{Suite='xefg-guard-package-integration';PowerShellVersion=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51=($env:OS -ceq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Passed=($results.Count-$failed);Failed=$failed;Tests=@($results.ToArray());PackageSha256=$archiveHash;BuiltPayloadSha256=$builtPayloadHash;SyntheticBaseFixture=$true;PayloadExecuted=$false;GameRuntimeVerified=$false}
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $testOutput) -Force
    Write-Json $testOutput $report
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
if ($failed) { throw ($failed.ToString()+' XeFG guard package tests failed.') }
Write-Host ($results.Count.ToString()+' XeFG guard package tests passed.')
