#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Enable','Restore','Status')][string]$Action='Status',
    [string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2'
)
$optiLogRequestedAction=$Action;$optiLogRequestedRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Complete-Setup.ps1') -Action Check
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:OptiLogKeys=@('LogToFile','LogLevel','LogFileName')

function Get-OptiLogPaths($Paths) {
    if ($Paths.Root -match '[\r\n;#]') { throw 'The selected MO2 root cannot be represented safely as an INI log path.' }
    $folder=Join-Path $Paths.Root 'Matheus_NR030_OptiLog_Backup'
    $diagnostic=Join-Path $Paths.Root 'Matheus_NR030_Diagnostic'
    [pscustomobject]@{Folder=$folder;State=(Join-Path $folder 'active-install.json');Diagnostic=$diagnostic;Log=(Join-Path $diagnostic 'OptiScaler-current.log')}
}
function Get-OptiLogTargets($Paths) {
    $primary=Join-Path $Paths.Bin 'OptiScaler.ini';Assert-NoReparse $primary
    if (-not (Test-Path -LiteralPath $primary -PathType Leaf)) { throw ('Existing ARK OptiScaler.ini is required: '+$primary) }
    $primary
    $secondary=Join-Path $Paths.OldBin 'OptiScaler.ini';Assert-NoReparse $secondary
    if (Test-Path -LiteralPath $secondary) {
        if (-not (Test-Path -LiteralPath $secondary -PathType Leaf)) { throw ('OptiScaler.ini path is not a file: '+$secondary) }
        $secondary
    }
}
function Get-OptiLogSettings([string]$Path) {
    Assert-NoReparse $Path;$hash=Get-Hash $Path;$text=[IO.File]::ReadAllText($Path)
    if ((Get-Hash $Path) -cne $hash) { throw ('INI changed while reading logging settings: '+$Path) }
    if ([regex]::Matches($text,'(?im)^\s*\[Log\]\s*(?:[;#][^\r\n]*)?\r?$').Count -ne 1) { throw ('Exactly one [Log] section is required: '+$Path) }
    $values=@{}
    foreach ($key in $script:OptiLogKeys) {
        $value=Read-IniValue $text 'Log' $key
        if ([string]::IsNullOrWhiteSpace($value)) { throw ('Existing nonempty [Log] '+$key+' is required: '+$Path) }
        $values[$key]=$value
    }
    [pscustomobject]@{Path=$Path;Text=$text;Values=$values;Hash=$hash}
}
function Get-OptiLogExpected($Paths) {
    @{LogToFile='true';LogLevel='1';LogFileName=(Get-OptiLogPaths $Paths).Log}
}
function Assert-OptiLogOwned($Paths,$Settings) {
    $expected=Get-OptiLogExpected $Paths
    foreach ($setting in $Settings) {
        foreach ($key in $script:OptiLogKeys) {
            if ($setting.Values[$key] -cne $expected[$key]) { throw ('Logging setting changed after enable; automatic restore/apply is blocked: '+$setting.Path+' [Log] '+$key) }
        }
    }
}
function Read-OptiLogState($Paths,[string[]]$Targets) {
    $control=Get-OptiLogPaths $Paths;Assert-NoReparse $control.Folder;Assert-NoReparse $control.State
    if (-not (Test-Path -LiteralPath $control.State)) { return $null }
    $state=Read-Json $control.State
    if ((Get-Value $state 'SchemaVersion') -ne 1 -or (Get-Value $state 'Name') -cne 'MatheusNR030OptiLog' -or -not (Same-Path ([string](Get-Value $state 'Root')) $Paths.Root)) { throw 'Invalid OptiScaler logging record.' }
    $files=@(Get-Value $state 'Files');$seen=@{}
    if ($files.Count -ne $Targets.Count) { throw 'OptiScaler INI inventory changed after logging enable. No settings were changed.' }
    $prefix=(Full-Path $control.Folder)+[IO.Path]::DirectorySeparatorChar
    foreach ($entry in $files) {
        $path=[string](Get-Value $entry 'Path');Assert-CompleteTarget $path $Targets
        if ($seen.ContainsKey((Full-Path $path))) { throw 'Duplicate logging destination.' };$seen[(Full-Path $path)]=$true
        $backup=[string](Get-Value $entry 'Backup');Assert-NoReparse $backup
        if (-not (Full-Path $backup).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [string](Get-Value $entry 'BeforeHash') -notmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Hash $backup) -cne $entry.BeforeHash) { throw 'Original logging backup is missing or changed.' }
        $null=Get-OptiLogSettings $backup
    }
    return $state
}
function Show-OptiLogStatus($Paths) {
    $targets=@(Get-OptiLogTargets $Paths);$settings=@($targets | ForEach-Object { Get-OptiLogSettings $_ })
    $state=Read-OptiLogState $Paths $targets
    foreach ($setting in $settings) { Write-Host ('OptiScaler log settings: '+$setting.Path+'; LogToFile='+$setting.Values.LogToFile+'; LogLevel='+$setting.Values.LogLevel+'; LogFileName='+$setting.Values.LogFileName) }
    Write-Host ('Diagnostic logging backup active: '+($null -ne $state)+'. Configuration status only; game logging is not verified.')
}
function Assert-OptiLogSnapshot($Snapshot) {
    Assert-NoReparse $Snapshot.Path
    if ($Snapshot.Existed) {
        if (-not (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) -or (Get-Hash $Snapshot.Path) -cne $Snapshot.BeforeHash) { throw ('File changed during logging preparation: '+$Snapshot.Path) }
    } elseif (Test-Path -LiteralPath $Snapshot.Path) { throw ('File appeared during logging preparation: '+$Snapshot.Path) }
}
function Invoke-OptiLogControl($Paths,[ValidateSet('Enable','Restore')][string]$Mode,[scriptblock]$BeforeOperation=$null) {
    Assert-Stopped
    $targets=@(Get-OptiLogTargets $Paths);$settings=@($targets | ForEach-Object { Get-OptiLogSettings $_ })
    $control=Get-OptiLogPaths $Paths
    foreach ($path in @($control.Folder,$control.State,$control.Diagnostic,$control.Log)) { Assert-NoReparse $path }
    if ((Test-Path -LiteralPath $control.Log) -and -not (Test-Path -LiteralPath $control.Log -PathType Leaf)) { throw 'The diagnostic log path is occupied by a directory.' }
    $state=Read-OptiLogState $Paths $targets
    if ($null -ne $state) { Assert-OptiLogOwned $Paths $settings }
    if ($Mode -ceq 'Enable' -and $null -ne $state) { Write-Host 'Diagnostic logging is already enabled. The original logging backup was preserved.';return }
    if ($Mode -ceq 'Restore' -and $null -eq $state) { throw 'No active diagnostic logging backup exists. No settings were changed.' }
    $texts=@{};$expected=Get-OptiLogExpected $Paths
    foreach ($setting in $settings) {
        $values=$expected
        if ($Mode -ceq 'Restore') {
            $entry=@($state.Files | Where-Object { Same-Path $_.Path $setting.Path })[0]
            $values=(Get-OptiLogSettings $entry.Backup).Values
        }
        $text=$setting.Text
        foreach ($key in $script:OptiLogKeys) { $text=Set-CompleteIniValue $text 'Log' $key $values[$key] }
        $texts[$setting.Path]=$text
    }
    # Both INIs and all original values were parsed before any mutation.
    $folder=Join-Path $control.Folder ($Mode.ToLowerInvariant()+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $snapshots=@(New-CompleteSnapshots ($targets+@($control.State)) $folder)
    foreach ($setting in $settings) {
        $snapshot=@($snapshots | Where-Object { Same-Path $_.Path $setting.Path })[0]
        if ($snapshot.BeforeHash -cne $setting.Hash) { throw ('INI changed while preparing logging settings: '+$setting.Path) }
    }
    $operations=New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $targets) {
        $source=Join-Path $folder ('setting-'+$operations.Count+'.ini')
        # OptiScaler uses CSimpleIniA, whose file format is MBCS/UTF-8.
        # UTF-8 BOM matches the user INI; UTF-16 would hide all settings.
        [IO.File]::WriteAllText($source,$texts[$path],(New-Object Text.UTF8Encoding($true)))
        $operations.Add([pscustomobject]@{Path=$path;Action='Copy';Source=$source;InstalledHash=(Get-Hash $source)})
    }
    if ($Mode -ceq 'Enable') {
        $source=Join-Path $folder 'logging-state.json'
        Write-Json $source ([pscustomobject]@{SchemaVersion=1;Name='MatheusNR030OptiLog';Root=$Paths.Root;EnabledUtc=[DateTime]::UtcNow.ToString('o');Files=@($snapshots | Where-Object { $targets -contains $_.Path });RuntimeVerified=$false})
        $operations.Add([pscustomobject]@{Path=$control.State;Action='Copy';Source=$source;InstalledHash=(Get-Hash $source)})
    } else { $operations.Add([pscustomobject]@{Path=$control.State;Action='Delete';Source=$null;InstalledHash=$null}) }
    $applied=New-Object 'System.Collections.Generic.List[object]';$journal=Join-Path $folder 'transaction.json'
    Write-Json $journal ([pscustomobject]@{Status='prepared';Mode=$Mode;Files=$snapshots})
    try {
        $index=0
        foreach ($op in $operations.ToArray()) {
            if ($null -ne $BeforeOperation) { & $BeforeOperation $index };$index++
            Assert-Stopped
            # Recheck all not-yet-written targets so a concurrent edit is never
            # accepted as our original baseline or overwritten by a later step.
            foreach ($snapshot in $snapshots) {
                $done=@($applied.ToArray() | Where-Object { Same-Path $_.Path $snapshot.Path })
                if ($done.Count -eq 0) { Assert-OptiLogSnapshot $snapshot }
                elseif ($done[0].Action -ceq 'Copy' -and (Get-Hash $snapshot.Path) -cne $done[0].InstalledHash) { throw ('File changed during logging transaction: '+$snapshot.Path) }
            }
            if ($Mode -ceq 'Enable') { New-Item -ItemType Directory -Path $control.Diagnostic -Force | Out-Null }
            if ($op.Action -ceq 'Copy') {
                if ((Get-Hash $op.Source) -cne $op.InstalledHash) { throw 'Prepared logging file changed.' }
                # Staging and destination are under the same MO2 root. Atomic
                # replace avoids a truncated existing INI if a write fails.
                if (Test-Path -LiteralPath $op.Path -PathType Leaf) { [IO.File]::Replace($op.Source,$op.Path,($op.Source+'.replaced')) }
                else { [IO.File]::Move($op.Source,$op.Path) }
            } else { Remove-Item -LiteralPath $op.Path -Force }
            $applied.Add($op)
            if ($op.Action -ceq 'Copy' -and (Get-Hash $op.Path) -cne $op.InstalledHash) { throw 'Installed logging file hash verification failed.' }
        }
        Write-Json $journal ([pscustomobject]@{Status='completed';Mode=$Mode;Files=$snapshots})
    } catch {
        $failure=$_;$rollback=New-Object 'System.Collections.Generic.List[object]';$conflicts=@()
        foreach ($op in $applied.ToArray()) {
            $matches=if ($op.Action -ceq 'Copy') { (Test-Path -LiteralPath $op.Path -PathType Leaf) -and (Get-Hash $op.Path) -ceq $op.InstalledHash } else { -not (Test-Path -LiteralPath $op.Path) }
            if ($matches) { $rollback.Add(@($snapshots | Where-Object { Same-Path $_.Path $op.Path })[0]) } else { $conflicts += $op.Path }
        }
        Restore-CompleteSnapshots @($rollback.ToArray())
        Write-Json $journal ([pscustomobject]@{Status='rolled-back';Mode=$Mode;Files=$snapshots;PreservedConcurrentEdits=$conflicts})
        if ($conflicts.Count) { throw ('Logging transaction stopped; concurrent edits were preserved: '+($conflicts -join ', ')+'. Original failure: '+$failure.Exception.Message) }
        throw $failure
    }
    if ($Mode -ceq 'Enable') { Write-Host ('Diagnostic logging enabled for the next game session: '+$control.Log);Write-Host 'This only enables debug logging. It does not change NR, upscaling or frame generation and does not fix graphics artifacts.' }
    else { Write-Host 'The original three logging settings were restored. Later edits to other settings were preserved.' }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $paths=Get-Paths $optiLogRequestedRoot
        if ($optiLogRequestedAction -ceq 'Status') { Show-OptiLogStatus $paths }
        else { Invoke-OptiLogControl $paths $optiLogRequestedAction }
    } catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
