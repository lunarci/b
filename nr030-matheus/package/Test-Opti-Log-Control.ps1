#requires -Version 5.1
[CmdletBinding()]
param([string]$SimpleIniHeader)
. (Join-Path $PSScriptRoot 'Opti-Log-Control.ps1') -Action Status
if ([string]::IsNullOrWhiteSpace($SimpleIniHeader) -or -not (Test-Path -LiteralPath $SimpleIniHeader -PathType Leaf)) { throw 'Pass -SimpleIniHeader with the pinned OptiScaler SimpleIni dependency to run the parser contract test.' }
if ((Get-Hash $SimpleIniHeader) -cne '969e5b019ba5dfd9f40e9a618f18669c761da20a25026ef0531e4edb769bd86e') { throw 'SimpleIni header hash does not match pinned commit 6048871ea9ee0ec24be5bd099d161a10567d7dc2.' }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('MatheusOptiLogTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
$script:OptiParserCompatible=$false
$script:OptiTestRunning=$false
function Get-Process { param([string[]]$Name,[object]$ErrorAction) if ($script:OptiTestRunning) { [pscustomobject]@{ProcessName='Cyberpunk2077'} } }
function Assert-LogTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('ASSERTION: '+$Message) } }
function Assert-LogThrows([scriptblock]$Code,[string]$Pattern) {
    $failure=$null;try { & $Code | Out-Null } catch { $failure=$_ }
    Assert-LogTest ($null -ne $failure) ('Expected failure: '+$Pattern)
    Assert-LogTest ($failure.Exception.Message -match $Pattern) ('Unexpected failure: '+$failure.Exception.Message)
}
function New-LogFixture([string]$Name) {
    $paths=Get-Paths (Join-Path $testRoot $Name)
    foreach ($bin in @($paths.Bin,$paths.OldBin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
    $text="[Log]`r`nLogToFile=auto`r`nLogLevel=auto`r`nLogFileName=C:\previous\debug.log`r`nSingleFile=auto`r`n[UpscaleRatio]`r`nUpscaleRatioOverrideValue=2.000000`r`n[XeFG]`r`nInterpolationCount=4`r`n[FrameGen]`r`nEnabled=true`r`n"
    [IO.File]::WriteAllText((Join-Path $paths.Bin 'OptiScaler.ini'),$text,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $paths.OldBin 'OptiScaler.ini'),$text.Replace('LogToFile=auto','LogToFile=false').Replace('LogLevel=auto','LogLevel=2').Replace('C:\previous\debug.log','C:\shadow\previous.log'),[Text.Encoding]::UTF8)
    $script:OptiTestRunning=$false
    return $paths
}
function Save-LogHashes($Paths) { $h=@{};foreach ($p in @(Get-OptiLogTargets $Paths)) { $h[$p]=Get-Hash $p };return $h }
function Assert-LogHashes($Hashes) { foreach ($p in $Hashes.Keys) { Assert-LogTest ((Get-Hash $p) -ceq $Hashes[$p]) ('File bytes changed: '+$p) } }
function Run-LogCase([string]$Name,[scriptblock]$Code) {
    try { $f=New-LogFixture $Name;& $Code $f;$results.Add([pscustomobject]@{Name=$Name;Status='PASS';Error=$null});Write-Host ('PASS '+$Name) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) }
    finally { $script:OptiTestRunning=$false }
}
try {
    Run-LogCase 'independent-baselines-idempotence-restore-preserves-other-edits' {
        param($p)
        $before=@{};foreach ($ini in @(Get-OptiLogTargets $p)) { $before[$ini]=Get-OptiLogSettings $ini }
        Invoke-OptiLogControl $p Enable
        $control=Get-OptiLogPaths $p;$stateHash=Get-Hash $control.State
        Invoke-OptiLogControl $p Enable
        Assert-LogTest ((Get-Hash $control.State) -ceq $stateHash) 'Repeated enable replaced original baseline.'
        foreach ($ini in @(Get-OptiLogTargets $p)) {
            $actual=Get-OptiLogSettings $ini;Assert-OptiLogOwned $p @($actual)
            $expected=$before[$ini].Text
            foreach ($k in $script:OptiLogKeys) { $expected=Set-CompleteIniValue $expected 'Log' $k (Get-OptiLogExpected $p)[$k] }
            Assert-LogTest ($actual.Text -ceq $expected) 'Changes extended beyond the three logging keys.'
            $bytes=[IO.File]::ReadAllBytes($ini);Assert-LogTest ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'OptiScaler SimpleIni-compatible UTF-8 BOM missing.'
            [IO.File]::WriteAllText($ini,$actual.Text.Replace('InterpolationCount=4','InterpolationCount=3'),[Text.Encoding]::UTF8)
        }
        Invoke-OptiLogControl $p Restore
        foreach ($ini in @(Get-OptiLogTargets $p)) {
            $after=Get-OptiLogSettings $ini
            foreach ($k in $script:OptiLogKeys) { Assert-LogTest ($after.Values[$k] -ceq $before[$ini].Values[$k]) 'Independent original logging value not restored.' }
            Assert-LogTest ((Read-IniValue $after.Text 'XeFG' 'InterpolationCount') -ceq '3') 'Later non-logging edit was lost.'
        }
        Assert-LogTest (-not (Test-Path -LiteralPath $control.State)) 'Active record remained after restore.'
    }
    Run-LogCase 'second-ini-invalid-blocks-all-writes' {
        param($p)
        $ini=Join-Path $p.OldBin 'OptiScaler.ini'
        [IO.File]::WriteAllText($ini,([IO.File]::ReadAllText($ini)).Replace('LogLevel=2',"LogLevel=2`r`nLogLevel=1"),[Text.Encoding]::UTF8)
        $before=Save-LogHashes $p
        Assert-LogThrows { Invoke-OptiLogControl $p Enable } 'Ambiguous duplicate INI key'
        Assert-LogHashes $before
        Assert-LogTest (-not (Test-Path -LiteralPath (Get-OptiLogPaths $p).Folder)) 'Invalid second INI created a backup transaction.'
    }
    Run-LogCase 'partial-write-failure-rolls-back-exact-bytes' {
        param($p)
        $before=Save-LogHashes $p
        Assert-LogThrows { Invoke-OptiLogControl $p Enable {param($i) if ($i -eq 1) { throw 'injected second operation failure' }} } 'injected second operation failure'
        Assert-LogHashes $before
        Assert-LogTest (-not (Test-Path -LiteralPath (Get-OptiLogPaths $p).State)) 'Failed enable left an active record.'
        Invoke-OptiLogControl $p Enable
        $enabled=Save-LogHashes $p;$stateHash=Get-Hash (Get-OptiLogPaths $p).State
        Assert-LogThrows { Invoke-OptiLogControl $p Restore {param($i) if ($i -eq 1) { throw 'injected restore failure' }} } 'injected restore failure'
        Assert-LogHashes $enabled
        Assert-LogTest ((Get-Hash (Get-OptiLogPaths $p).State) -ceq $stateHash) 'Failed restore changed original active backup.'
    }
    Run-LogCase 'missing-overwrite-is-not-created-and-inventory-change-blocked' {
        param($p)
        $shadow=Join-Path $p.OldBin 'OptiScaler.ini';$shadowText=[IO.File]::ReadAllText($shadow);Remove-Item -LiteralPath $shadow
        Invoke-OptiLogControl $p Enable
        Assert-LogTest (-not (Test-Path -LiteralPath $shadow)) 'Missing overwrite INI was created.'
        [IO.File]::WriteAllText($shadow,$shadowText,[Text.Encoding]::UTF8)
        $before=Save-LogHashes $p
        Assert-LogThrows { Invoke-OptiLogControl $p Restore } 'inventory changed'
        Assert-LogHashes $before
    }
    Run-LogCase 'logging-conflict-blocks-restore-and-retains-backup' {
        param($p)
        Invoke-OptiLogControl $p Enable;$control=Get-OptiLogPaths $p;$stateHash=Get-Hash $control.State
        $ini=Join-Path $p.OldBin 'OptiScaler.ini';[IO.File]::WriteAllText($ini,([IO.File]::ReadAllText($ini)).Replace('LogLevel=1','LogLevel=2'),[Text.Encoding]::UTF8)
        $before=Save-LogHashes $p
        Assert-LogThrows { Invoke-OptiLogControl $p Restore } 'Logging setting changed'
        Assert-LogHashes $before;Assert-LogTest ((Get-Hash $control.State) -ceq $stateHash) 'Conflict changed original record.'
    }
    Run-LogCase 'game-start-and-concurrent-ini-edit-block-before-write' {
        param($p)
        $before=Save-LogHashes $p
        Assert-LogThrows { Invoke-OptiLogControl $p Enable {param($i) $script:OptiTestRunning=$true} } 'Close Cyberpunk'
        $script:OptiTestRunning=$false;Assert-LogHashes $before
        $script:OptiTestRacePath=Join-Path $p.OldBin 'OptiScaler.ini'
        Assert-LogThrows { Invoke-OptiLogControl $p Enable {param($i) if ($i -eq 0) { [IO.File]::AppendAllText($script:OptiTestRacePath,"`r`n; concurrent edit",[Text.Encoding]::UTF8) }} } 'File changed during logging preparation'
        Assert-LogTest ((Get-Hash (Join-Path $p.Bin 'OptiScaler.ini')) -ceq $before[(Join-Path $p.Bin 'OptiScaler.ini')]) 'Primary INI was written before second INI race detection.'
        Assert-LogTest ([IO.File]::ReadAllText($script:OptiTestRacePath).Contains('; concurrent edit')) 'Concurrent edit was overwritten.'
    }
    Run-LogCase 'backup-hash-and-target-root-binding' {
        param($p)
        Invoke-OptiLogControl $p Enable;$control=Get-OptiLogPaths $p;$state=Read-Json $control.State
        $before=Save-LogHashes $p
        $state.Root=Join-Path $p.Root 'another-root';Write-Json $control.State $state
        Assert-LogThrows { Invoke-OptiLogControl $p Restore } 'Invalid OptiScaler logging record'
        $state.Root=$p.Root;Write-Json $control.State $state
        [IO.File]::AppendAllText($state.Files[0].Backup,'tampered')
        Assert-LogThrows { Invoke-OptiLogControl $p Restore } 'Original logging backup is missing or changed'
        Assert-LogHashes $before
    }
    Run-LogCase 'actual-simpleini-parser-reads-utf8-output-and-rejects-utf16-control' {
        param($p)
        $parserDir=Join-Path $p.Root 'parser-test';New-Item -ItemType Directory -Path $parserDir | Out-Null
        Copy-Item -LiteralPath $SimpleIniHeader -Destination (Join-Path $parserDir 'SimpleIni.h')
        $source=Join-Path $parserDir 'parser.cpp';$exe=Join-Path $parserDir 'parser-check.exe'
        [IO.File]::WriteAllText($source,@'
#define SI_NO_CONVERSION
#include "SimpleIni.h"
#include <cstring>
#include <cstdlib>
int main(int argc,char** argv) {
 if(argc!=5) return 9;
 CSimpleIniA ini;
 if(ini.LoadFile(argv[1])!=SI_OK) return 2;
 if(std::strcmp(ini.GetValue("Log","LogToFile","MISSING"),argv[2])) return 3;
 if(std::strcmp(ini.GetValue("Log","LogLevel","MISSING"),argv[3])) return 4;
 if(std::strcmp(ini.GetValue("Log","LogFileName","MISSING"),argv[4])) return 5;
 if(std::strcmp(ini.GetValue("FrameGen","Enabled","MISSING"),"true")) return 6;
 if(std::strcmp(ini.GetValue("XeFG","InterpolationCount","MISSING"),"4")) return 7;
 if(std::strtod(ini.GetValue("UpscaleRatio","UpscaleRatioOverrideValue","0"),nullptr)!=2.0) return 8;
 return 0;
}
'@,(New-Object Text.UTF8Encoding($false)))
        Push-Location $parserDir
        try {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { & cl.exe /nologo /EHsc /std:c++17 $source ('/Fe:'+ $exe) | Out-Host }
            else { & g++ -std=c++17 $source -o $exe | Out-Host }
            Assert-LogTest ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $exe)) 'Actual SimpleIni parser failed to compile.'
        } finally { Pop-Location }
        Invoke-OptiLogControl $p Enable
        foreach ($ini in @(Get-OptiLogTargets $p)) {
            & $exe $ini 'true' '1' (Get-OptiLogPaths $p).Log
            Assert-LogTest ($LASTEXITCODE -eq 0) 'SimpleIni did not read all three logging keys and preserved FG keys.'
        }
        $bad=Join-Path $parserDir 'negative-utf16.ini'
        [IO.File]::WriteAllText($bad,[IO.File]::ReadAllText((Join-Path $p.Bin 'OptiScaler.ini')),[Text.Encoding]::Unicode)
        & $exe $bad 'true' '1' (Get-OptiLogPaths $p).Log
        Assert-LogTest ($LASTEXITCODE -ne 0) 'UTF-16 negative control did not expose the parser mismatch.'
        Invoke-OptiLogControl $p Restore
        foreach ($ini in @(Get-OptiLogTargets $p)) {
            $setting=Get-OptiLogSettings $ini
            & $exe $ini $setting.Values.LogToFile $setting.Values.LogLevel $setting.Values.LogFileName
            Assert-LogTest ($LASTEXITCODE -eq 0) 'SimpleIni failed to read restored logging keys.'
        }
        $script:OptiParserCompatible=$true
        Write-Host 'ParserCompatible=true; pinned CSimpleIniA loaded enabled and restored INIs; UTF-16 negative control rejected.'
    }
    $failed=@($results.ToArray() | Where-Object { $_.Status -cne 'PASS' })
    Write-Host ('OptiScaler logging tests: '+($results.Count-$failed.Count)+'/'+$results.Count+' passed.')
    if ($failed.Count) { exit 1 }
} finally {
    $out=Join-Path $PSScriptRoot 'test-results';New-Item -ItemType Directory -Path $out -Force | Out-Null
    $failedCount=@($results.ToArray() | Where-Object { $_.Status -cne 'PASS' }).Count
    Write-Json (Join-Path $out 'opti-log-control-tests.json') ([pscustomobject]@{
        Suite='opti-log-control';PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        WindowsPowerShell51=($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        Passed=($results.Count-$failedCount);Failed=$failedCount;Tests=@($results.ToArray());ParserCompatible=$script:OptiParserCompatible
        SimpleIniCommit='6048871ea9ee0ec24be5bd099d161a10567d7dc2';SimpleIniSha256='969e5b019ba5dfd9f40e9a618f18669c761da20a25026ef0531e4edb769bd86e';GameRuntimeVerified=$false
    })
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
