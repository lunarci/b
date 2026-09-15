#requires -Version 5.1
[CmdletBinding()]
param()
$motionTestRoot=$PSScriptRoot
. (Join-Path $motionTestRoot 'Motion-Tuning.ps1') -Action Collect
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$motionProductionHash=$script:Motion024Hash
$motionProductionPackage=$script:PackageRoot
$motionOriginalCheck=${function:Check-Complete}
$motionFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('MatheusNR030-MotionTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $motionFixtureRoot | Out-Null
$motionResults=New-Object 'System.Collections.Generic.List[object]'
$script:MotionRunningProcess=''
$script:MotionProcessCalls=0
$script:MotionStartOnSecondCheck=$false
$script:MotionNetworkCalls=0

# Process/network substitutes are confined to this test script. The production
# command line cannot supply process, hash, ownership or download overrides.
function Get-Process {
    param([string[]]$Name,[object]$ErrorAction)
    $script:MotionProcessCalls++
    if ($script:MotionStartOnSecondCheck -and $script:MotionProcessCalls -ge 2) {
        return [pscustomobject]@{ProcessName='Cyberpunk2077'}
    }
    if ($script:MotionRunningProcess -and $Name -contains $script:MotionRunningProcess) {
        return [pscustomobject]@{ProcessName=$script:MotionRunningProcess}
    }
}
function Invoke-WebRequest { $script:MotionNetworkCalls++;throw 'Unexpected network request from configuration companion.' }
function Invoke-RestMethod { $script:MotionNetworkCalls++;throw 'Unexpected network request from configuration companion.' }
function Assert-MotionTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('ASSERTION: '+$Message) }
}
function Assert-MotionThrows([scriptblock]$Code,[string]$Pattern) {
    $failure=$null
    try { & $Code | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure) { throw ('Expected failure: '+$Pattern) }
    if ($failure.Exception.Message -notmatch $Pattern) { throw ('Unexpected failure: '+$failure.Exception.Message+'; expected '+$Pattern) }
}
function New-MotionFixture([string]$Name) {
    $root=Join-Path $motionFixtureRoot $Name
    $package=Join-Path $root 'package'
    $paths=Get-Paths (Join-Path $root 'MO2')
    foreach ($folder in @($package,$paths.Plugins,$paths.OldPlugins,$paths.Backup,(Split-Path -Parent $paths.BaseState),(Get-CompletePaths $paths).Backup)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $motionTestRoot 'protected-files.json') -Destination (Join-Path $package 'protected-files.json')
    $script:PackageRoot=$package
    foreach ($location in @(@($paths.Plugins,'ARK'),@($paths.OldPlugins,'overwrite'))) {
        Write-Text (Join-Path $location[0] 'MatheusNR030.asi') 'SYNTHETIC EXACT 024 ASI TEST FIXTURE'
        $ini="; "+$location[1]+" independent tuning`r`n[MatheusNR030]`r`nEnabled=1`r`nScalePercent=85`r`nColourPreservationPercent=100`r`nDepthProtection=1`r`nLumaStabilityPercent=100`r`nEffectPercent=50 ; strength`r`n[Unrelated]`r`nLocation="+$location[1]+"`r`n"
        Write-Text (Join-Path $location[0] 'MatheusNR030.ini') $ini
        Write-Text (Join-Path $location[0] 'dlssnr_on_amd.asi') 'SYNTHETIC BASE ASI DO NOT CHANGE'
        Write-Text (Join-Path $location[0] 'dlssnr_on_amd.ini') "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nAsync=0`r`n"
        Write-Text (Join-Path $location[0] 'nvngx_dlssnr.dll') 'SYNTHETIC MODEL DO NOT CHANGE'
    }
    foreach ($bin in @($paths.Bin,$paths.OldBin)) {
        Write-Text (Join-Path $bin 'OptiScaler.ini') "[UpscaleRatio]`r`nUpscaleRatioOverrideValue=2.0`r`n[XeFG]`r`nInterpolationCount=3`r`n"
        Write-Text (Join-Path $bin 'libxell.dll') 'SYNTHETIC FRAME GENERATION DO NOT CHANGE'
    }
    $script:Motion024Hash=Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.asi')
    $state=[pscustomobject]@{
        SchemaVersion=1;AddonName='MatheusNR030';PluginFolder=$paths.Plugins
        Files=@(
            [pscustomobject]@{Name='MatheusNR030.asi';InstalledHash=$script:Motion024Hash},
            [pscustomobject]@{Name='MatheusNR030.ini';InstalledHash=(Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.ini'))}
        )
    }
    Write-Json $paths.State $state
    Write-Text $paths.BaseState '{"fixture":"legacy metadata must remain untouched"}'
    Write-Text (Get-CompletePaths $paths).State '{"fixture":"complete metadata must remain untouched"}'
    $script:MotionRunningProcess='';$script:MotionStartOnSecondCheck=$false;$script:MotionProcessCalls=0;$script:MotionNetworkCalls=0
    return [pscustomobject]@{Paths=$paths;Root=$root;Package=$package}
}
function Get-MotionSnapshot($Paths) {
    $snapshot=@{}
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse -Force)) { $snapshot[$file.FullName]=Get-Hash $file.FullName }
        }
    }
    foreach ($path in @($Paths.State,$Paths.BaseState,(Get-CompletePaths $Paths).State)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $snapshot[$path]=Get-Hash $path }
    }
    return $snapshot
}
function Assert-MotionSnapshot($Paths,$Before,[string[]]$Except=@()) {
    $after=Get-MotionSnapshot $Paths
    Assert-MotionTest ($after.Count -eq $Before.Count) 'Game file inventory changed.'
    foreach ($path in $Before.Keys) {
        if ($Except -contains $path) { continue }
        Assert-MotionTest ($after.ContainsKey($path) -and $after[$path] -ceq $Before[$path]) ('Unrelated file changed: '+$path)
    }
}
function Get-MotionIniPaths($Paths) {
    return @((Join-Path $Paths.Plugins 'MatheusNR030.ini'),(Join-Path $Paths.OldPlugins 'MatheusNR030.ini'))
}
function Read-MotionZipText($Archive,[string]$EntryName) {
    $entry=$Archive.GetEntry($EntryName)
    Assert-MotionTest ($null -ne $entry) ('Missing evidence entry: '+$EntryName)
    $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose();$stream.Dispose() }
}
function Run-MotionCase([string]$Name,[scriptblock]$Code) {
    try {
        $fixture=New-MotionFixture $Name
        & $Code $fixture
        $motionResults.Add([pscustomobject]@{Name=$Name;Status='PASS';Error=$null})
        Write-Host ('PASS '+$Name)
    } catch {
        $motionResults.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message})
        Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)
    } finally {
        $script:MotionRunningProcess='';$script:MotionStartOnSecondCheck=$false
        Set-Item -Path Function:Check-Complete -Value $motionOriginalCheck
    }
}

try {
    Run-MotionCase 'effect25-keeps-two-independent-inis-and-state-base-binaries' {
        param($f)
        $before=Get-MotionSnapshot $f.Paths;$iniPaths=Get-MotionIniPaths $f.Paths
        $texts=@{};foreach ($ini in $iniPaths) { $texts[$ini]=[IO.File]::ReadAllText($ini) }
        Set-MotionEffect $f.Paths 25
        Assert-MotionSnapshot $f.Paths $before $iniPaths
        foreach ($ini in $iniPaths) {
            $actual=[IO.File]::ReadAllText($ini)
            Assert-MotionTest ($actual -ceq $texts[$ini].Replace('EffectPercent=50 ','EffectPercent=25')) 'INI modification was not confined to the existing strength value.'
            Assert-MotionTest ((Read-IniValue $actual 'MatheusNR030' 'EffectPercent') -ceq '25') 'Effect 25 was not applied in both locations.'
        }
        $journals=@(Get-ChildItem -LiteralPath $f.Paths.Backup -Recurse -File -Filter 'transaction.json')
        Assert-MotionTest ($journals.Count -eq 1) 'Expected one transaction journal.'
        $journal=Read-Json $journals[0].FullName
        Assert-MotionTest ($journal.Status -ceq 'completed' -and @($journal.Files).Count -eq 2) 'Both INIs must be individually backed up.'
        foreach ($record in @($journal.Files)) { Assert-MotionTest ((Get-Hash $record.Backup) -ceq $before[$record.Path]) 'Original exact INI backup changed.' }
    }
    Run-MotionCase 'duplicate-key-in-second-ini-blocks-every-write' {
        param($f)
        $shadow=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini'
        Write-Text $shadow ([IO.File]::ReadAllText($shadow).Replace('EffectPercent=50 ; strength',"EffectPercent=50`r`nEffectPercent=25"))
        $before=Get-MotionSnapshot $f.Paths
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'Ambiguous duplicate INI key'
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest (@(Get-ChildItem -LiteralPath $f.Paths.Backup -Directory).Count -eq 0) 'Invalid second INI created a transaction.'
    }
    Run-MotionCase 'second-write-failure-restores-both-original-inis' {
        param($f)
        $before=Get-MotionSnapshot $f.Paths
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 {param($Index) if ($Index -eq 1) { throw 'injected second write failure' }} } 'injected second write failure'
        Assert-MotionSnapshot $f.Paths $before
        $journalFile=@(Get-ChildItem -LiteralPath $f.Paths.Backup -Recurse -File -Filter 'transaction.json')[0]
        Assert-MotionTest ((Read-Json $journalFile.FullName).Status -ceq 'rolled-back') 'Failed transaction was not marked rolled back.'
    }
    Run-MotionCase 'missing-overwrite-ini-is-not-created' {
        param($f)
        $shadow=Join-Path $f.Paths.OldPlugins 'MatheusNR030.ini';Remove-Item -LiteralPath $shadow
        $before=Get-MotionSnapshot $f.Paths
        Set-MotionEffect $f.Paths 25
        Assert-MotionSnapshot $f.Paths $before @((Join-Path $f.Paths.Plugins 'MatheusNR030.ini'))
        Assert-MotionTest (-not (Test-Path -LiteralPath $shadow)) 'Absent overwrite INI was created.'
    }
    Run-MotionCase 'modified-primary-asi-blocks-before-settings' {
        param($f)
        Write-Text (Join-Path $f.Paths.Plugins 'MatheusNR030.asi') 'MODIFIED EXECUTABLE'
        $before=Get-MotionSnapshot $f.Paths
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'Modified add-on file|exact 0.2.4 ASI'
        Assert-MotionSnapshot $f.Paths $before
    }
    Run-MotionCase 'modified-overwrite-asi-blocks-before-settings' {
        param($f)
        Write-Text (Join-Path $f.Paths.OldPlugins 'MatheusNR030.asi') 'MODIFIED SHADOW EXECUTABLE'
        $before=Get-MotionSnapshot $f.Paths
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'Modified add-on file|exact 0.2.4 ASI'
        Assert-MotionSnapshot $f.Paths $before
    }
    Run-MotionCase 'owned-other-version-still-fails-exact024-gate' {
        param($f)
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) { Write-Text (Join-Path $folder 'MatheusNR030.asi') 'OWNED BUT WRONG VERSION' }
        $state=Read-Json $f.Paths.State
        @($state.Files | Where-Object { $_.Name -ceq 'MatheusNR030.asi' })[0].InstalledHash=Get-Hash (Join-Path $f.Paths.Plugins 'MatheusNR030.asi')
        Write-Json $f.Paths.State $state
        $before=Get-MotionSnapshot $f.Paths
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'exact 0.2.4 ASI'
        Assert-MotionSnapshot $f.Paths $before
    }
    Run-MotionCase 'game-and-mo2-running-block-settings-and-collector' {
        param($f)
        $before=Get-MotionSnapshot $f.Paths
        foreach ($process in @('Cyberpunk2077','ModOrganizer')) {
            $script:MotionRunningProcess=$process
            Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'Close Cyberpunk 2077 and Mod Organizer'
            Assert-MotionThrows { Collect-MotionEvidence $f.Paths } 'Close Cyberpunk 2077 and Mod Organizer'
        }
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest (-not (Test-Path -LiteralPath (Join-Path $f.Package 'Results'))) 'Blocked collector created output.'
    }
    Run-MotionCase 'game-starting-after-stage-blocks-before-write' {
        param($f)
        $before=Get-MotionSnapshot $f.Paths;$script:MotionStartOnSecondCheck=$true
        Assert-MotionThrows { Set-MotionEffect $f.Paths 25 } 'Close Cyberpunk 2077 and Mod Organizer'
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest ($script:MotionProcessCalls -eq 2) 'Expected a second process check before changing settings.'
    }
    Run-MotionCase 'effect0-and-effect50-preserve-nr-enabled-and-other-tuning' {
        param($f)
        $before=Get-MotionSnapshot $f.Paths;$iniPaths=Get-MotionIniPaths $f.Paths
        foreach ($value in @(0,50)) {
            Set-MotionEffect $f.Paths $value
            foreach ($ini in $iniPaths) {
                $text=[IO.File]::ReadAllText($ini)
                Assert-MotionTest ((Read-IniValue $text 'MatheusNR030' 'EffectPercent') -ceq [string]$value) 'Requested comparison strength was not written.'
                foreach ($entry in @(@('Enabled','1'),@('ScalePercent','85'),@('ColourPreservationPercent','100'),@('DepthProtection','1'),@('LumaStabilityPercent','100'))) {
                    Assert-MotionTest ((Read-IniValue $text 'MatheusNR030' $entry[0]) -ceq $entry[1]) ('Unrelated add-on setting changed: '+$entry[0])
                }
            }
            Assert-MotionSnapshot $f.Paths $before $iniPaths
        }
    }
    Run-MotionCase 'collector-keeps-full-log-headers-and-local-readonly-subset' {
        param($f)
        $full="UNFILTERED HEADER retained`r`nunknown_config_field=must remain`r`n"+('sample body line'+"`r`n")*100+"UNFILTERED TAIL retained`r`n"
        foreach ($folder in @($f.Paths.Plugins,$f.Paths.OldPlugins)) {
            Write-Text (Join-Path $folder 'dlssnr_on_amd.log') $full
            Write-Text (Join-Path $folder 'MatheusNR030.log') ("event=session_start old_header=retained`r`n"+$full)
            Write-Text (Join-Path $folder 'private-unrelated.txt') 'DO NOT COLLECT'
        }
        Write-Text (Join-Path $f.Paths.Bin 'OptiScaler.log') $full
        $before=Get-MotionSnapshot $f.Paths
        Set-Item -Path Function:Check-Complete -Value {param($Paths) return 'SYNTHETIC LOCAL SUMMARY: gameplay unverified'}
        $zipPath=Collect-MotionEvidence $f.Paths
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest ($script:MotionNetworkCalls -eq 0) 'Collector attempted network access.'
        Assert-MotionTest (Test-Path -LiteralPath $zipPath -PathType Leaf) 'Local ZIP missing.'
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $allowed=@('inventory.json','MATHEUS_CHECK.txt','COLLECTION_NOTES.txt')
            foreach ($side in @('ark','overwrite')) {
                foreach ($name in @('OptiScaler.ini','OptiScaler.log','dlssnr_on_amd.ini','dlssnr_on_amd.log','MatheusNR030.ini','MatheusNR030.log')) { $allowed += ($side+'/'+$name) }
            }
            foreach ($entry in $zip.Entries) { Assert-MotionTest ($allowed -contains $entry.FullName.Replace('\','/')) ('Unexpected collection entry: '+$entry.FullName) }
            foreach ($side in @('ark','overwrite')) {
                $entry=$zip.GetEntry($side+'/dlssnr_on_amd.log')
                Assert-MotionTest ($null -ne $entry) 'Missing full base log.'
                $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
                try { $actual=$reader.ReadToEnd() } finally { $reader.Dispose();$stream.Dispose() }
                Assert-MotionTest ($actual -ceq $full) 'Collector truncated or filtered the log header/body/tail.'
            }
        } finally { $zip.Dispose() }
        $remaining=@(Get-ChildItem -LiteralPath (Join-Path $f.Package 'Results') -Directory)
        Assert-MotionTest ($remaining.Count -eq 0) 'Collector left temporary uncompressed evidence folders.'
    }
    Run-MotionCase 'collector-includes-configured-absolute-logs-and-original-provenance' {
        param($f)
        $sources=@{};$contents=@{};$timestamps=@{};$hashes=@{}
        foreach ($location in @(@('ark',$f.Paths.Bin),@('overwrite',$f.Paths.OldBin))) {
            $side=$location[0]
            $source=Join-Path $f.Paths.Root ('OptiScaler-'+$side+'-debug.log')
            $full="CURRENT SESSION HEADER "+$side+"`r`n"+('unfiltered configured log line'+"`r`n")*200+"FINAL SESSION TAIL "+$side+"`r`n"
            Write-Text $source $full
            (Get-Item -LiteralPath $source).LastWriteTimeUtc=[DateTime]::Parse('2026-09-15T13:02:00Z').ToUniversalTime()
            $sources[$side]=$source;$contents[$side]=$full
            $timestamps[$side]=(Get-Item -LiteralPath $source).LastWriteTimeUtc.ToString('o')
            $hashes[$side]=Get-Hash $source
            $ini=Join-Path $location[1] 'OptiScaler.ini'
            Write-Text $ini ([IO.File]::ReadAllText($ini)+"`r`n[Log]`r`nLogFileName="+$source+"`r`n")
            Write-Text (Join-Path $location[1] 'OptiScaler.log') ('OLDER DEFAULT LOG '+$side)
        }
        $before=Get-MotionSnapshot $f.Paths
        Set-Item -Path Function:Check-Complete -Value {param($Paths) return 'SYNTHETIC LOCAL SUMMARY: gameplay unverified'}
        $zipPath=Collect-MotionEvidence $f.Paths
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest ($script:MotionNetworkCalls -eq 0) 'Configured log collection attempted network access.'
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $inventory=@((Read-MotionZipText $zip 'inventory.json') | ConvertFrom-Json)
            foreach ($side in @('ark','overwrite')) {
                $entryName='configured-'+$side+'/OptiScaler-configured.log'
                Assert-MotionTest ((Read-MotionZipText $zip $entryName) -ceq $contents[$side]) 'Configured log header/body/tail was not copied whole.'
                Assert-MotionTest ((Read-MotionZipText $zip ($side+'/OptiScaler.log')) -ceq ('OLDER DEFAULT LOG '+$side)) 'The default log was replaced or lost when collecting a configured path.'
                $record=@($inventory | Where-Object { $_.Entry -ceq $entryName })
                Assert-MotionTest ($record.Count -eq 1) 'Configured log requires exactly one inventory record.'
                Assert-MotionTest ($record[0].Source -ceq $sources[$side]) 'Inventory lost the actual configured source path.'
                Assert-MotionTest ($record[0].Sha256 -ceq $hashes[$side]) 'Configured log bytes differ from the recorded source hash.'
                # PS7 deserializes ISO timestamps as DateTime; Windows PS5.1
                # leaves them as strings. Compare their UTC instant in both.
                $recordUtc=([DateTime]$record[0].ModifiedUtc).ToUniversalTime().ToString('o')
                Assert-MotionTest ($recordUtc -ceq $timestamps[$side]) 'Inventory lost the original log timestamp needed to identify stale sessions.'
                Assert-MotionTest ((Get-Hash $sources[$side]) -ceq $hashes[$side]) 'Collector changed the configured source log.'
            }
        } finally { $zip.Dispose() }
    }
    Run-MotionCase 'collector-excludes-outside-root-configured-log-and-explains-omission' {
        param($f)
        # A sibling beginning with MO2 also detects an unsafe string-prefix
        # containment check: it is outside MO2 despite sharing its name prefix.
        $outside=Join-Path $f.Root 'MO2-external-private.log'
        $private='UNRELATED OUTSIDE LOG CONTENT MUST NEVER BE COLLECTED'
        Write-Text $outside $private
        $outsideHash=Get-Hash $outside
        $ini=Join-Path $f.Paths.Bin 'OptiScaler.ini'
        Write-Text $ini ([IO.File]::ReadAllText($ini)+"`r`n[Log]`r`nLogFileName="+$outside+"`r`n")
        Write-Text (Join-Path $f.Paths.Bin 'OptiScaler.log') 'LOCAL DEFAULT LOG REMAINS AVAILABLE'
        $before=Get-MotionSnapshot $f.Paths
        Set-Item -Path Function:Check-Complete -Value {param($Paths) return 'SYNTHETIC LOCAL SUMMARY: gameplay unverified'}
        $zipPath=Collect-MotionEvidence $f.Paths
        Assert-MotionSnapshot $f.Paths $before
        Assert-MotionTest ((Get-Hash $outside) -ceq $outsideHash) 'Excluded outside log was modified.'
        Assert-MotionTest ($script:MotionNetworkCalls -eq 0) 'Outside path triggered network access.'
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            Assert-MotionTest ($null -eq $zip.GetEntry('configured-ark/OptiScaler-configured.log')) 'Outside-root configured log was collected.'
            Assert-MotionTest ((Read-MotionZipText $zip 'ark/OptiScaler.log') -ceq 'LOCAL DEFAULT LOG REMAINS AVAILABLE') 'Outside path prevented collection of valid local evidence.'
            $notes=Read-MotionZipText $zip 'COLLECTION_NOTES.txt'
            Assert-MotionTest ($notes -match 'CONFIGURED_LOG_OUTSIDE_ROOT') 'Omitted configured log was not explicitly explained.'
            Assert-MotionTest ($notes.Contains($outside)) 'Omission note lost the configured path needed to locate the missing runtime log.'
            $inventory=@((Read-MotionZipText $zip 'inventory.json') | ConvertFrom-Json)
            Assert-MotionTest (@($inventory | Where-Object { $_.Source -ceq $outside }).Count -eq 0) 'Outside file was reported as a collected source.'
            foreach ($entry in $zip.Entries) {
                Assert-MotionTest (-not (Read-MotionZipText $zip $entry.FullName).Contains($private)) 'Outside log content leaked into the evidence ZIP.'
            }
        } finally { $zip.Dispose() }
    }
} finally {
    $script:Motion024Hash=$motionProductionHash;$script:PackageRoot=$motionProductionPackage
    Set-Item -Path Function:Check-Complete -Value $motionOriginalCheck
    $out=Join-Path $motionTestRoot 'test-results';New-Item -ItemType Directory -Path $out -Force | Out-Null
    $failed=@($motionResults.ToArray() | Where-Object { $_.Status -ceq 'FAIL' }).Count
    $report=[pscustomobject]@{
        Suite='motion-configuration-companion';PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        WindowsPowerShell51=($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        Passed=($motionResults.Count-$failed);Failed=$failed;Tests=@($motionResults.ToArray());GameRuntimeVerified=$false
    }
    Write-Json (Join-Path $out 'motion-tuning-tests.json') $report
    Remove-Item -LiteralPath $motionFixtureRoot -Recurse -Force
}
if ($failed) { throw ($failed.ToString()+' motion tuning tests failed.') }
Write-Host ($motionResults.Count.ToString()+' motion tuning tests passed.')
