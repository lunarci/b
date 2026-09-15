#requires -Version 5.1
[CmdletBinding()]
param()
$skinTestComponentRoot=$PSScriptRoot
. (Join-Path $skinTestComponentRoot 'Skin-Control.ps1') -Action CheckSkin
$originalNrHash=$script:SkinNrHash;$originalAddonHash=$script:SkinAddonHash
$originalStopped=(Get-Item Function:\Assert-Stopped).ScriptBlock
$script:SkinTestRunning=$false
function Assert-Stopped { if ($script:SkinTestRunning) { throw 'Close Cyberpunk 2077 and Mod Organizer before changing files.' } }
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('MatheusNR030-SkinTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
$nativeWindows=($env:OS -ceq 'Windows_NT');$script:SkinNativeApiVerified=$false
if ($nativeWindows) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class SkinControlNativeIni {
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, EntryPoint="GetPrivateProfileStringA")]
    public static extern uint ReadString(string section, string key, string fallback, StringBuilder value, uint capacity, string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, EntryPoint="GetPrivateProfileIntA")]
    public static extern uint ReadInt(string section, string key, int fallback, string path);
}
'@
}
function Assert-SkinTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('ASSERTION: '+$Message) } }
function Assert-SkinThrows([scriptblock]$Code,[string]$Pattern) {
    $failure=$null;try { & $Code | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch $Pattern) { throw ('Expected '+$Pattern+'; observed '+[string]$failure) }
}
function New-SkinFixture([string]$Name) {
    $paths=Get-Paths (Join-Path $fixtureRoot $Name)
    foreach ($folder in @($paths.Plugins,$paths.OldPlugins)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Text (Join-Path $folder 'dlssnr_on_amd.asi') 'SYNTHETIC C7 FIXTURE ONLY'
        Write-Text (Join-Path $folder 'MatheusNR030.asi') 'SYNTHETIC ADDON FIXTURE ONLY'
        Write-Text (Join-Path $folder 'nvngx_dlssnr.dll') 'SYNTHETIC MODEL PRESERVE'
        Write-Text (Join-Path $folder 'MatheusNR030.ini') "[MatheusNR030]`r`nScalePercent=85`r`nEffectPercent=50`r`nLumaStabilityPercent=100`r`n"
    }
    # Hash substitution is confined to this synthetic test process; production
    # exposes neither a command-line nor an environment-variable override.
    $script:SkinNrHash=Get-Hash (Join-Path $paths.Plugins 'dlssnr_on_amd.asi')
    $script:SkinAddonHash=Get-Hash (Join-Path $paths.Plugins 'MatheusNR030.asi')
    $primary=Join-Path $paths.Plugins 'dlssnr_on_amd.ini';$secondary=Join-Path $paths.OldPlugins 'dlssnr_on_amd.ini'
    Write-Text $primary "[DlssNrOnAmd]`r`nEnabled=1`r`nPreUpscale=1`r`nLocalStructure=70`r`n; skin key originally absent`r`n[Other]`r`nSkinStructure=44`r`n"
    Write-Text $secondary "[DlssNrOnAmd]`nEnabled=1`nSkinStructure = 63 ; preserve original formatting`nUseAutoMask=1`nPreHistory=0`nTemporal=1`nLocalStructure=81`n"
    Write-Text (Join-Path $paths.Bin 'OptiScaler.ini') "[UpscaleRatio]`r`nUpscaleRatioOverrideValue=2.000000`r`n[XeFG]`r`nInterpolationCount=3`r`n"
    [pscustomobject]@{Paths=$paths;Primary=$primary;Secondary=$secondary}
}
function Get-SkinSnapshot($Paths) {
    $map=@{}
    foreach ($folder in @($Paths.Bin,$Paths.OldBin)) {
        if (Test-Path -LiteralPath $folder) { foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse)) { $map[$file.FullName]=Get-Hash $file.FullName } }
    }
    foreach ($state in @((Get-CompletePaths $Paths).State,(Get-SkinPaths $Paths).State)) { $map[$state]=$null;if (Test-Path -LiteralPath $state -PathType Leaf) { $map[$state]=Get-Hash $state } }
    return $map
}
function Assert-SkinSnapshot($Paths,$Before) {
    $after=Get-SkinSnapshot $Paths
    Assert-SkinTest ($after.Count -eq $Before.Count) 'File inventory changed unexpectedly.'
    foreach ($path in $Before.Keys) { Assert-SkinTest ($after.ContainsKey($path) -and $after[$path] -ceq $Before[$path]) ('Unexpected mutation: '+$path) }
}
function Add-SkinCompleteRecord($Fixture) {
    $complete=Get-CompletePaths $Fixture.Paths;$folder=New-CompleteBackup $Fixture.Paths 'fixture-original'
    $records=@()
    foreach ($path in @($Fixture.Primary,$Fixture.Secondary)) {
        $backup=Join-Path $folder ('original-'+$records.Count+'.ini')
        Write-Text $backup ("[DlssNrOnAmd]`nSkinStructure="+($records.Count+11)+"`n")
        $records += [pscustomobject]@{Path=$path;Existed=$true;Backup=$backup;BeforeHash=(Get-Hash $backup);InstalledExists=$true;InstalledHash=(Get-Hash $path);GeneratedCache=$false}
    }
    Write-Json $complete.State ([pscustomobject]@{SchemaVersion=1;Name='MatheusNR030Complete';Root=$Fixture.Paths.Root;CreatedUtc='2026-01-01T00:00:00Z';Files=$records;OwnsGpuDriver=$false;OwnsOptiScalerBinary=$false;OwnsXeFgBinary=$false;RuntimeVerified=$false})
}
function Run-SkinCase([string]$Name,[scriptblock]$Body) {
    $script:SkinTestRunning=$false
    try { $fixture=New-SkinFixture $Name;& $Body $fixture;$results.Add([pscustomobject]@{Name=$Name;Status='PASS'});Write-Host ('PASS '+$Name) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) }
}
try {
    Run-SkinCase 'skin-zero-patches-both-independent-inis-and-restores-exact-bytes' {
        param($f)
        $before=Get-SkinSnapshot $f.Paths
        Invoke-SkinControl $f.Paths ApplySkin0
        foreach ($path in @($f.Primary,$f.Secondary)) { Assert-SkinTest ((Get-SkinSettings $path).Skin.Value -eq 0) 'Skin structure was not zero.' }
        if ($nativeWindows) {
            foreach ($pair in @(@($f.Primary,'70'),@($f.Secondary,'81'))) {
                foreach ($key in @('SkinStructure','LocalStructure')) {
                    $buffer=New-Object Text.StringBuilder 256
                    $null=[SkinControlNativeIni]::ReadString('DlssNrOnAmd',$key,'__MISSING__',$buffer,256,$pair[0])
                    $expected='0';if ($key -ceq 'LocalStructure') { $expected=$pair[1] }
                    # Win32 may retain an inline comment. C7 converts the
                    # leading numeric value, so allow only that exact value
                    # plus whitespace/a preserved comment; never a fallback.
                    $pattern='^'+[regex]::Escape($expected)+'\s*(?:[;#].*)?$'
                    Assert-SkinTest ($buffer.ToString() -cmatch $pattern) ('Native GetPrivateProfileStringA did not read '+$key+'='+$expected+' from the patched INI; got '+$buffer.ToString())
                }
                Assert-SkinTest ([SkinControlNativeIni]::ReadInt('DlssNrOnAmd','Enabled',12345,$pair[0]) -eq 1) 'Native GetPrivateProfileIntA lost Enabled after the patch.'
            }
            $script:SkinNativeApiVerified=$true
        }
        foreach ($path in $before.Keys) { if ($path -notin @($f.Primary,$f.Secondary,(Get-CompletePaths $f.Paths).State,(Get-SkinPaths $f.Paths).State)) { Assert-SkinTest ((Get-Hash $path) -ceq $before[$path]) ('An unrelated file changed: '+$path) } }
        $primary=[IO.File]::ReadAllText($f.Primary);$secondary=[IO.File]::ReadAllText($f.Secondary)
        Assert-SkinTest ((Read-IniValue $primary 'Other' 'SkinStructure') -ceq '44') 'Other-section skin key changed.'
        Assert-SkinTest ((Read-IniValue $primary 'DlssNrOnAmd' 'LocalStructure') -ceq '70' -and (Read-IniValue $secondary 'DlssNrOnAmd' 'LocalStructure') -ceq '81') 'Local structure changed.'
        Assert-SkinTest (-not (Get-SkinSettings $f.Primary).AutoMask.Present -and -not (Get-SkinSettings $f.Primary).PreHistory.Present -and -not (Get-SkinSettings $f.Primary).Temporal.Present) 'Missing defaults were written unnecessarily.'
        Invoke-SkinControl $f.Paths RestoreSkin
        Assert-SkinTest ((Get-Hash $f.Primary) -ceq $before[$f.Primary] -and (Get-Hash $f.Secondary) -ceq $before[$f.Secondary]) 'Original INI bytes were not restored.'
        Assert-SkinTest (-not (Test-Path -LiteralPath (Get-SkinPaths $f.Paths).State)) 'Active skin record remained after restore.'
        foreach ($entry in @((Read-CompleteState $f.Paths).Files)) { Assert-SkinTest (Test-CompleteInstalledRecord $entry) 'Complete ownership is inconsistent after skin restore.' }
    }
    Run-SkinCase 'skin-apply-is-idempotent-and-preserves-first-backup' {
        param($f)
        $original=Get-Hash $f.Primary;Invoke-SkinControl $f.Paths ApplySkin0
        $before=Get-SkinSnapshot $f.Paths;Invoke-SkinControl $f.Paths ApplySkin0;Assert-SkinSnapshot $f.Paths $before
        Invoke-SkinControl $f.Paths RestoreSkin;Assert-SkinTest ((Get-Hash $f.Primary) -ceq $original) 'Reapply lost the original baseline.'
    }
    Run-SkinCase 'skin-control-preserves-complete-original-backups-and-updates-installed-hashes' {
        param($f)
        Add-SkinCompleteRecord $f;$prior=Read-CompleteState $f.Paths
        Invoke-SkinControl $f.Paths ApplySkin0
        $current=Read-CompleteState $f.Paths
        foreach ($entry in $current.Files) {
            $old=@($prior.Files | Where-Object { Same-Path $_.Path $entry.Path })[0]
            Assert-SkinTest ($entry.Backup -ceq $old.Backup -and $entry.BeforeHash -ceq $old.BeforeHash -and (Get-Hash $entry.Backup) -ceq $old.BeforeHash) 'Complete original backup changed.'
            Assert-SkinTest (Test-CompleteInstalledRecord $entry) 'InstalledHash not updated for a touched NR INI.'
        }
        Invoke-SkinControl $f.Paths RestoreSkin
        $current=Read-CompleteState $f.Paths
        foreach ($entry in $current.Files) { Assert-SkinTest (Test-CompleteInstalledRecord $entry) 'Restored hash not reflected in complete state.' }
        Restore-CompleteSnapshots @($current.Files)
        foreach ($entry in $current.Files) { Assert-SkinTest ((Get-Hash $entry.Path) -ceq $entry.BeforeHash) 'Complete original restoration no longer works.' }
    }
    Run-SkinCase 'skin-control-does-not-create-missing-overwrite-ini' {
        param($f)
        Remove-Item -LiteralPath $f.Secondary
        Invoke-SkinControl $f.Paths ApplySkin0
        Assert-SkinTest (-not (Test-Path -LiteralPath $f.Secondary)) 'Missing overwrite INI was created.'
        Invoke-SkinControl $f.Paths RestoreSkin
        Assert-SkinTest (-not (Test-Path -LiteralPath $f.Secondary)) 'Restore created an overwrite INI.'
    }
    Run-SkinCase 'skin-mask-disabled-or-unrecognized-stops-before-any-change' {
        param($f)
        $original=[IO.File]::ReadAllText($f.Secondary)
        foreach ($value in @('0','2','auto','1.0')) {
            Write-Text $f.Secondary ($original.Replace('UseAutoMask=1',('UseAutoMask='+$value)))
            $before=Get-SkinSnapshot $f.Paths
            Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'UseAutoMask|Unrecognized integer'
            Assert-SkinSnapshot $f.Paths $before
            Assert-SkinTest (-not (Test-Path -LiteralPath (Get-SkinPaths $f.Paths).Folder)) 'Invalid mask created skin backup state.'
        }
    }
    Run-SkinCase 'skin-duplicate-key-or-section-blocks-all-targets' {
        param($f)
        $original=[IO.File]::ReadAllText($f.Secondary)
        foreach ($extra in @("SkinStructure=77`n","[DlssNrOnAmd]`nOther=1`n")) {
            Write-Text $f.Secondary ($original+$extra);$before=Get-SkinSnapshot $f.Paths
            Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'duplicate|Exactly one'
            Assert-SkinSnapshot $f.Paths $before
        }
    }
    Run-SkinCase 'skin-pinned-binary-gates-check-primary-and-overwrite' {
        param($f)
        foreach ($path in @((Join-Path $f.Paths.Plugins 'dlssnr_on_amd.asi'),(Join-Path $f.Paths.Plugins 'MatheusNR030.asi'),(Join-Path $f.Paths.OldPlugins 'dlssnr_on_amd.asi'),(Join-Path $f.Paths.OldPlugins 'MatheusNR030.asi'))) {
            $original=[IO.File]::ReadAllBytes($path);Write-Text $path 'DIFFERENT BINARY'
            $before=Get-SkinSnapshot $f.Paths;Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'Hash mismatch';Assert-SkinSnapshot $f.Paths $before
            [IO.File]::WriteAllBytes($path,$original)
        }
    }
    Run-SkinCase 'skin-complete-runtime-ini-edits-become-current-restoration-baseline' {
        param($f)
        Add-SkinCompleteRecord $f;$prior=Read-CompleteState $f.Paths
        Write-Text $f.Secondary ([IO.File]::ReadAllText($f.Secondary)+"; later edit`n")
        $before=Get-Hash $f.Secondary
        Invoke-SkinControl $f.Paths ApplySkin0
        $current=Read-CompleteState $f.Paths;$changed=@($current.Files | Where-Object { Same-Path $_.Path $f.Secondary })[0]
        Assert-SkinTest ($changed.BeforeHash -ceq $before -and (Test-CompleteInstalledRecord $changed)) 'Edited current INI was not adopted as the restoration baseline.'
        foreach ($old in $prior.Files) { Assert-SkinTest ((Get-Hash $old.Backup) -ceq $old.BeforeHash) 'Previous original backup was modified.' }
        Invoke-SkinControl $f.Paths RestoreSkin
        Assert-SkinTest ((Get-Hash $f.Secondary) -ceq $before) 'Skin restore lost earlier runtime/user edits.'
    }
    Run-SkinCase 'skin-restore-and-reapply-preserve-later-user-edits-by-blocking' {
        param($f)
        Invoke-SkinControl $f.Paths ApplySkin0
        Write-Text $f.Secondary ([IO.File]::ReadAllText($f.Secondary)+"; later edit`n")
        $before=Get-SkinSnapshot $f.Paths
        foreach ($mode in @('RestoreSkin','ApplySkin0')) { Assert-SkinThrows { Invoke-SkinControl $f.Paths $mode } 'INI changed after skin control';Assert-SkinSnapshot $f.Paths $before }
    }
    Run-SkinCase 'skin-apply-failure-rolls-back-inis-and-both-records' {
        param($f)
        Add-SkinCompleteRecord $f
        foreach ($failureIndex in @(0,1,2,3)) {
            $before=Get-SkinSnapshot $f.Paths
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected skin apply failure' } }.GetNewClosure()
            Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 $inject } 'injected skin apply failure'
            Assert-SkinSnapshot $f.Paths $before
        }
    }
    Run-SkinCase 'skin-restore-failure-rolls-back-inis-and-both-records' {
        param($f)
        Add-SkinCompleteRecord $f;Invoke-SkinControl $f.Paths ApplySkin0
        foreach ($failureIndex in @(0,1,2,3)) {
            $before=Get-SkinSnapshot $f.Paths
            $inject={ param($index) if ($index -eq $failureIndex) { throw 'injected skin restore failure' } }.GetNewClosure()
            Assert-SkinThrows { Invoke-SkinControl $f.Paths RestoreSkin $inject } 'injected skin restore failure'
            Assert-SkinSnapshot $f.Paths $before
        }
    }
    Run-SkinCase 'skin-backup-tamper-blocks-restore' {
        param($f)
        Invoke-SkinControl $f.Paths ApplySkin0
        $state=Read-SkinState $f.Paths @(Get-SkinIniTargets $f.Paths)
        Write-Text $state.Files[0].Backup 'TAMPERED'
        $before=Get-SkinSnapshot $f.Paths;Assert-SkinThrows { Invoke-SkinControl $f.Paths RestoreSkin } 'backup is missing or changed';Assert-SkinSnapshot $f.Paths $before
    }
    Run-SkinCase 'skin-running-game-and-missing-primary-stop-before-writing' {
        param($f)
        $script:SkinTestRunning=$true;$before=Get-SkinSnapshot $f.Paths
        Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'Close Cyberpunk';Assert-SkinSnapshot $f.Paths $before
        $script:SkinTestRunning=$false;Remove-Item -LiteralPath $f.Primary;$before=Get-SkinSnapshot $f.Paths
        Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'Existing primary NR INI';Assert-SkinSnapshot $f.Paths $before
    }
    Run-SkinCase 'skin-check-reports-defaults-and-remains-read-only' {
        param($f)
        $before=Get-SkinSnapshot $f.Paths
        $output=(@(Show-SkinSettings $f.Paths 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        Assert-SkinTest ($output.Contains('SkinStructure=-1; SkinStructurePresent=False; UseAutoMask=1; PreHistory=0; Temporal=1; RuntimeVerified=false')) 'Absent native defaults not reported accurately.'
        Assert-SkinTest ($output.Contains('SkinStructure=63; SkinStructurePresent=True')) 'Independent overwrite value not reported.'
        Assert-SkinSnapshot $f.Paths $before
    }
    Run-SkinCase 'skin-float-native-values-parse-invariantly-and-restore-byte-exact' {
        param($f)
        $original=[IO.File]::ReadAllText($f.Primary);$culture=[Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            foreach ($value in @('-1.000','0.500000','0.0','')) {
                Write-Text $f.Primary ($original.Replace('[DlssNrOnAmd]',('[DlssNrOnAmd]'+"`r`nSkinStructure="+$value)))
                if ($value -ceq '') { $settings=Get-SkinSettings $f.Primary;Assert-SkinTest ($settings.Skin.Present -and $settings.Skin.Value -eq -1.0) 'Blank native skin value must retain presence and resolve to minus one.' }
                $hash=Get-Hash $f.Primary;Invoke-SkinControl $f.Paths ApplySkin0;Assert-SkinTest ((Get-SkinSettings $f.Primary).Skin.Value -eq 0) 'Native float skin value was not controlled.'
                Invoke-SkinControl $f.Paths RestoreSkin;Assert-SkinTest ((Get-Hash $f.Primary) -ceq $hash) 'Float literal was not restored byte-exact.'
            }
            foreach ($value in @('NaN','Infinity','1e40','0,500')) {
                Write-Text $f.Primary ($original.Replace('[DlssNrOnAmd]',('[DlssNrOnAmd]'+"`r`nSkinStructure="+$value)))
                $before=Get-SkinSnapshot $f.Paths;Assert-SkinThrows { Invoke-SkinControl $f.Paths ApplySkin0 } 'Unrecognized finite';Assert-SkinSnapshot $f.Paths $before
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture=$culture }
    }
} finally {
    $script:SkinNrHash=$originalNrHash;$script:SkinAddonHash=$originalAddonHash
    Set-Item Function:\Assert-Stopped $originalStopped
    $out=Join-Path $skinTestComponentRoot 'test-results';New-Item -ItemType Directory -Path $out -Force | Out-Null
    $failed=@($results.ToArray() | Where-Object { $_.Status -ceq 'FAIL' }).Count
    $report=[pscustomobject]@{Suite='skin-control';PowerShellVersion=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51=($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);NativeWin32ApiVerified=$script:SkinNativeApiVerified;NativeWin32ApiSkipped=(-not $nativeWindows);Passed=($results.Count-$failed);Failed=$failed;GameRuntimeVerified=$false;Results=@($results.ToArray())}
    Write-Json (Join-Path $out 'skin-control-tests.json') $report
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
if ($failed) { exit 1 }
