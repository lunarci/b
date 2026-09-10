#requires -Version 5.1
<#
Pester-free safety checks using only disposable fixtures, never an installed game.
Run with Windows PowerShell 5.1:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-OverwriteHelper.ps1
Dummy DLL identity is accepted only through the helper's internal test seam.
#>
[CmdletBinding()]
param(
    [string]$HelperPath = (Join-Path $PSScriptRoot 'Manage-OptiScalerOverwrite.ps1'),
    [switch]$KeepFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OHTestPassed = 0
$script:OHTestFailed = 0
$script:OHTestSkipped = 0
$script:OHTestWindows = ($env:OS -eq 'Windows_NT')
$script:OHTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('OptiScalerOverwriteTests-' + [guid]::NewGuid().ToString('N'))

function Assert-OHTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-OHEqual {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) {
        throw ($Message + "`nExpected: " + $Expected + "`nActual:   " + $Actual)
    }
}

function Assert-OHThrows {
    param([scriptblock]$Operation, [string]$Message)
    $didThrow = $false
    try { $null = & $Operation } catch { $didThrow = $true }
    Assert-OHTrue $didThrow $Message
}

function Write-OHFile {
    param([string]$Path, [string]$Text)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-OHHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OHState {
    param([string]$Path)
    # Record empty directories as well as files. Never follow a reparse point.
    if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
    $records = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Path))
    $base = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            $relative = $entry.FullName.Substring($base.Length + 1).Replace('\', '/')
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $records.Add('L|' + $relative)
            } elseif ($entry.PSIsContainer) {
                $records.Add('D|' + $relative)
                $pending.Push($entry.FullName)
            } else {
                $records.Add('F|' + $relative + '|' + (Get-OHHash $entry.FullName))
            }
        }
    }
    return (@($records | Sort-Object) -join "`n")
}

function Get-OHUserState {
    param($Fixture)
    return ((Get-OHState $Fixture.Overwrite) + "`nGAME`n" +
        (Get-OHState $Fixture.Game) + "`nMODS`n" + (Get-OHState $Fixture.Mods))
}

function Save-OHManifest {
    param($Fixture, [System.Collections.IDictionary]$Files)
    $document = [ordered]@{ name = 'Disposable helper test'; files = $Files }
    Write-OHFile $Fixture.BuildManifest ($document | ConvertTo-Json -Depth 8)
}

function New-OHFixture {
    $root = Join-Path $script:OHTestRoot ([guid]::NewGuid().ToString('N'))
    $fixture = [pscustomobject]@{
        Root = $root
        Overwrite = Join-Path $root 'overwrite'
        Game = Join-Path $root 'game'
        Mods = Join-Path $root 'mods'
        BackupBase = Join-Path $root 'backups'
        BuildManifest = Join-Path $root 'BUILD.json'
        Selected = @(
            'Root/bin/x64/dxgi.dll',
            'Root/bin/x64/OptiScaler/amd_runtime.dll',
            'Root/bin/x64/OptiScaler/D3D12_OptiScaler/D3D12Core.dll'
        )
        OriginalHashes = @{}
    }
    $null = [IO.Directory]::CreateDirectory($fixture.Overwrite)
    $files = [ordered]@{}
    foreach ($relative in $fixture.Selected) {
        $file = Join-Path $fixture.Overwrite $relative
        Write-OHFile $file ('Original disposable binary: ' + $relative)
        $fixture.OriginalHashes[$relative] = Get-OHHash $file
        # Different from the original: identity verification must use the injected seam.
        $files[$relative] = ('a' * 64)
    }
    $preserved = @(
        'Root/bin/x64/OptiScaler.ini',
        'Root/bin/x64/OptiScaler/config.ini',
        'Root/bin/x64/OptiScaler/unlisted.dll',
        'Root/bin/x64/OptiScaler/Licenses/LICENSE.txt',
        'Root/bin/x64/plugins/cyber_engine_tweaks/bindings.json',
        'Root/bin/x64/ReShade.ini',
        'Root/bin/x64/reshade-shaders/Shaders/example.fx',
        'Root/bin/x64/winmm.dll',
        'Root/r6/scripts/other_mod.reds',
        'unrelated.txt'
    )
    foreach ($relative in $preserved) {
        Write-OHFile (Join-Path $fixture.Overwrite $relative) ('Keep this exact content: ' + $relative)
    }
    # Even listed settings and documentation must never become cleanup targets.
    $files['Root/bin/x64/OptiScaler.ini'] = ('b' * 64)
    $files['Root/bin/x64/OptiScaler/config.ini'] = ('b' * 64)
    $files['_PackageDocs/README_KO.md'] = ('b' * 64)
    Write-OHFile (Join-Path $fixture.Game 'bin/x64/dxgi.dll') 'Untouched game copy'
    Write-OHFile (Join-Path $fixture.Mods 'base/Root/bin/x64/dxgi.dll') 'Untouched MO2 mod copy'
    Save-OHManifest $fixture $files
    return $fixture
}

function Invoke-OHFixture {
    param(
        $Fixture,
        [ValidateSet('Check', 'Apply', 'Restore')][string]$Action,
        [string]$BackupManifestPath,
        [scriptblock]$IdentityVerifier = { param($path, $knownHash) return $true },
        [scriptblock]$GameRunningCheck = { return $false }
    )
    $parameters = @{
        Action = $Action
        BackupBase = $Fixture.BackupBase
        IdentityVerifier = $IdentityVerifier
        GameRunningCheck = $GameRunningCheck
    }
    if ($Action -eq 'Restore') {
        $parameters.BackupManifestPath = $BackupManifestPath
    } else {
        $parameters.OverwritePath = $Fixture.Overwrite
        $parameters.BuildManifestPath = $Fixture.BuildManifest
    }
    return Invoke-OverwriteOperation @parameters
}

function Test-OHCase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:OHTestPassed++
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:OHTestFailed++
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
}

function Skip-OHCase {
    param([string]$Name, [string]$Reason)
    $script:OHTestSkipped++
    Write-Host ('SKIP ' + $Name + ': ' + $Reason)
}

function Remove-OHFixtureTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName) }
        else { [IO.File]::Delete($item.FullName) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
            Remove-OHFixtureTree $entry.FullName
        }
        [IO.Directory]::Delete($item.FullName)
    } else {
        [IO.File]::Delete($item.FullName)
    }
}

try {
    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        throw ('Helper script does not exist: ' + $HelperPath)
    }
    $null = [IO.Directory]::CreateDirectory($script:OHTestRoot)
    . $HelperPath -LoadFunctionsOnly -Headless
    $null = Get-Command Invoke-OverwriteOperation -CommandType Function -ErrorAction Stop

    Test-OHCase 'LoadFunctionsOnly performs no action' {
        $fixture = New-OHFixture
        $before = Get-OHState $fixture.Root
        . $HelperPath -LoadFunctionsOnly -Headless -Action Apply `
            -OverwritePath $fixture.Overwrite -BuildManifestPath $fixture.BuildManifest `
            -BackupBase $fixture.BackupBase
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Dot-sourcing mutated a fixture.'
    }

    Test-OHCase 'Identity and process test seams are absent from the public CLI' {
        $command = Get-Command -Name $HelperPath -CommandType ExternalScript
        Assert-OHTrue (-not $command.Parameters.ContainsKey('IdentityVerifier')) 'Identity bypass is exposed on the CLI.'
        Assert-OHTrue (-not $command.Parameters.ContainsKey('GameRunningCheck')) 'Process bypass is exposed on the CLI.'
    }

    Test-OHCase 'Check is read-only and identifies only the three eligible files' {
        $fixture = New-OHFixture
        $before = Get-OHState $fixture.Root
        $result = Invoke-OHFixture $fixture Check
        Assert-OHEqual 3 $result.Count 'Check selected the wrong number of files.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Check changed files or created directories.'
    }

    Test-OHCase 'Apply backs up and removes exactly the selected files; Restore round-trips them' {
        $fixture = New-OHFixture
        $before = Get-OHUserState $fixture
        $result = Invoke-OHFixture $fixture Apply
        Assert-OHEqual 3 $result.Count 'Apply selected the wrong number of files.'
        Assert-OHTrue (Test-Path -LiteralPath $result.BackupManifestPath -PathType Leaf) 'Backup manifest was not created.'
        $null = Get-Content -LiteralPath $result.BackupManifestPath -Raw | ConvertFrom-Json
        foreach ($relative in $fixture.Selected) {
            Assert-OHTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.Overwrite $relative))) ('Selected source remains: ' + $relative)
        }
        $backupFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $result.BackupManifestPath) -Recurse -File |
            Where-Object { $_.FullName -ne $result.BackupManifestPath })
        Assert-OHEqual 3 $backupFiles.Count 'Backup includes unselected files or is missing a selected file.'
        $backupHashes = @($backupFiles | ForEach-Object { Get-OHHash $_.FullName })
        foreach ($relative in $fixture.Selected) {
            $matching = @($backupHashes | Where-Object { $_ -eq $fixture.OriginalHashes[$relative] })
            Assert-OHEqual 1 $matching.Count ('Original was not backed up exactly once: ' + $relative)
        }
        $after = Get-OHUserState $fixture
        $expected = @($before -split "`n" | Where-Object {
            $line = $_
            $selectedLine = $false
            foreach ($relative in $fixture.Selected) {
                if ($line -ceq ('F|' + $relative + '|' + $fixture.OriginalHashes[$relative])) { $selectedLine = $true }
            }
            -not $selectedLine
        }) -join "`n"
        Assert-OHEqual $expected $after 'Apply changed an INI, CET, ReShade, unlisted DLL, mod file, game file, or directory.'
        $restore = Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath
        Assert-OHEqual 3 $restore.Count 'Restore selected the wrong number of files.'
        Assert-OHEqual $before (Get-OHUserState $fixture) 'Restore did not reproduce the original user files.'
    }

    Test-OHCase 'Identity failure aborts before any mutation' {
        $fixture = New-OHFixture
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Invoke-OHFixture $fixture Apply -IdentityVerifier { param($path, $knownHash) return $false } } 'Unknown identity was accepted.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Identity failure changed files or created backup directories.'
    }

    Test-OHCase 'Running-game detection aborts before any mutation' {
        $fixture = New-OHFixture
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Invoke-OHFixture $fixture Apply -GameRunningCheck { return $true } } 'Apply proceeded with a running game.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Running-game rejection mutated the fixture.'
    }

    Test-OHCase 'Missing candidate files are a read-only zero-match Check' {
        $fixture = New-OHFixture
        foreach ($relative in $fixture.Selected) { [IO.File]::Delete((Join-Path $fixture.Overwrite $relative)) }
        $before = Get-OHState $fixture.Root
        $result = Invoke-OHFixture $fixture Check
        Assert-OHEqual 0 $result.Count 'Missing candidates produced a nonzero count.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Check created missing files or backup directories.'
    }

    Test-OHCase 'Missing overwrite root is rejected without creating it' {
        $fixture = New-OHFixture
        $fixture.Overwrite = Join-Path $fixture.Root 'missing/overwrite'
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Invoke-OHFixture $fixture Apply } 'A nonexistent overwrite root was accepted.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Missing-root rejection created or changed paths.'
    }

    foreach ($badPath in @(
        'Root/bin/x64/',
        'Root/bin/x64/../x64/dxgi.dll',
        'Root/bin/x64/OptiScaler/../../dxgi.dll',
        'Root\bin\x64\OptiScaler\..\dxgi.dll',
        '/Root/bin/x64/dxgi.dll',
        'C:\Root\bin\x64\dxgi.dll'
    )) {
        Test-OHCase ('Malformed manifest path is rejected: ' + $badPath) {
            $fixture = New-OHFixture
            $files = [ordered]@{ 'Root/bin/x64/dxgi.dll' = ('a' * 64) }
            $files[$badPath] = ('a' * 64)
            Save-OHManifest $fixture $files
            $before = Get-OHState $fixture.Root
            Assert-OHThrows { Invoke-OHFixture $fixture Apply } ('Malformed target path was accepted: ' + $badPath)
            Assert-OHEqual $before (Get-OHState $fixture.Root) 'Manifest validation happened after mutation.'
        }
    }

    Test-OHCase 'Restore refuses an occupied destination and preserves its new contents' {
        $fixture = New-OHFixture
        $result = Invoke-OHFixture $fixture Apply
        Write-OHFile (Join-Path $fixture.Overwrite $fixture.Selected[0]) 'New user data after Apply'
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath } 'Restore overwrote a newly created file.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Failed Restore partially restored or overwrote files.'
    }

    Test-OHCase 'RemovalPending with an absent source recovers a deletion interrupted before journaling' {
        $fixture = New-OHFixture
        $original = Get-OHUserState $fixture
        $result = Invoke-OHFixture $fixture Apply
        $journal = Get-Content -LiteralPath $result.BackupManifestPath -Raw | ConvertFrom-Json
        $journal.Files[0].Status = 'RemovalPending'
        $journal.State = 'BackedUp'
        Write-OHFile $result.BackupManifestPath ($journal | ConvertTo-Json -Depth 12)
        Assert-OHTrue (-not (Test-Path -LiteralPath $journal.Files[0].SourcePath)) 'Interrupted-deletion fixture source should be absent.'
        $restored = Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath
        Assert-OHEqual 3 $restored.Count 'Restore skipped a RemovalPending entry.'
        Assert-OHEqual $original (Get-OHUserState $fixture) 'Interrupted deletion did not recover every original.'
    }

    Test-OHCase 'RemovalPending with an unchanged source is safely idempotent' {
        $fixture = New-OHFixture
        $original = Get-OHUserState $fixture
        $result = Invoke-OHFixture $fixture Apply
        $journal = Get-Content -LiteralPath $result.BackupManifestPath -Raw | ConvertFrom-Json
        $pending = $journal.Files[1]
        $pending.Status = 'RemovalPending'
        $journal.State = 'BackedUp'
        $saved = Join-Path (Split-Path -Parent $result.BackupManifestPath) ('files/' + $pending.RelativePath)
        [IO.File]::Copy($saved, $pending.SourcePath, $false)
        # A stable timestamp also detects unnecessary rewrites of the existing file.
        [IO.File]::SetLastWriteTimeUtc($pending.SourcePath, [datetime]'2001-01-01T00:00:00Z')
        $originalWriteTime = [IO.File]::GetLastWriteTimeUtc($pending.SourcePath)
        Write-OHFile $result.BackupManifestPath ($journal | ConvertTo-Json -Depth 12)
        $restored = Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath
        Assert-OHEqual 3 $restored.Count 'Restore did not account for the existing RemovalPending source.'
        Assert-OHEqual $originalWriteTime ([IO.File]::GetLastWriteTimeUtc($pending.SourcePath)) 'Restore rewrote an unchanged existing source.'
        Assert-OHEqual $original (Get-OHUserState $fixture) 'Pending-entry recovery changed user data.'
        $repeated = Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath
        Assert-OHEqual 0 $repeated.Count 'A repeated completed Restore was not idempotent.'
        Assert-OHEqual $original (Get-OHUserState $fixture) 'Repeated Restore changed the recovered originals.'
    }

    Test-OHCase 'A corrupt later backup aborts Restore before any source is restored' {
        $fixture = New-OHFixture
        $result = Invoke-OHFixture $fixture Apply
        $journal = Get-Content -LiteralPath $result.BackupManifestPath -Raw | ConvertFrom-Json
        $last = $journal.Files[$journal.Files.Count - 1]
        $saved = Join-Path (Split-Path -Parent $result.BackupManifestPath) ('files/' + $last.RelativePath)
        Write-OHFile $saved 'Deliberately corrupted disposable backup'
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath } 'Restore accepted a corrupt backup.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Backup corruption was detected only after mutation.'
        foreach ($relative in $fixture.Selected) {
            Assert-OHTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.Overwrite $relative))) ('Restore partially created a source before rejecting corruption: ' + $relative)
        }
    }

    Test-OHCase 'Atomic restore rejects a wrong hash without a final file or staging debris' {
        $fixture = New-OHFixture
        $source = Join-Path $fixture.Overwrite $fixture.Selected[0]
        $targetDirectory = Join-Path $fixture.Root 'atomic-target'
        $null = [IO.Directory]::CreateDirectory($targetDirectory)
        $target = Join-Path $targetDirectory 'dxgi.dll'
        $before = Get-OHState $fixture.Root
        Assert-OHThrows { Restore-FileAtomic $source $target ('0' * 64) } 'Atomic restore accepted the wrong expected hash.'
        Assert-OHTrue (-not (Test-Path -LiteralPath $target)) 'Atomic restore left a partial final file.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Atomic restore left staging debris or changed its backup.'
    }

    Test-OHCase 'Failure on the second atomic restore rolls back the first and retains usable backups' {
        $fixture = New-OHFixture
        $original = Get-OHUserState $fixture
        $result = Invoke-OHFixture $fixture Apply
        $before = Get-OHState $fixture.Root
        $script:OHTestOriginalRestoreAtomic = (Get-Command Restore-FileAtomic -CommandType Function).ScriptBlock
        $script:OHTestRestoreAtomicCalls = 0
        $script:OHTestFirstRestoreCompleted = $false
        $mock = {
            param([string]$BackupPath, [string]$TargetPath, [string]$ExpectedHash)
            $script:OHTestRestoreAtomicCalls++
            if ($script:OHTestRestoreAtomicCalls -eq 2) { throw 'Injected second-restore failure' }
            & $script:OHTestOriginalRestoreAtomic $BackupPath $TargetPath $ExpectedHash
            $script:OHTestFirstRestoreCompleted = (Test-Path -LiteralPath $TargetPath -PathType Leaf)
        }
        Set-Item -Path Function:script:Restore-FileAtomic -Value $mock
        try {
            Assert-OHThrows { Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath } 'The injected Restore failure did not propagate.'
        } finally {
            Set-Item -Path Function:script:Restore-FileAtomic -Value $script:OHTestOriginalRestoreAtomic
        }
        Assert-OHEqual 2 $script:OHTestRestoreAtomicCalls 'The failure was not injected on the second restore.'
        Assert-OHTrue $script:OHTestFirstRestoreCompleted 'The first file was never restored, so rollback was not exercised.'
        Assert-OHEqual $before (Get-OHState $fixture.Root) 'Failed Restore left a partial source, changed its journal, or lost backup data.'
        $retried = Invoke-OHFixture $fixture Restore -BackupManifestPath $result.BackupManifestPath
        Assert-OHEqual 3 $retried.Count 'Retained backups could not complete a subsequent Restore.'
        Assert-OHEqual $original (Get-OHUserState $fixture) 'Restore retry did not recover the exact originals.'
    }

    $linkFixture = New-OHFixture
    $linkPath = Join-Path $linkFixture.Overwrite 'Root/bin/x64/OptiScaler'
    $linkTarget = Join-Path $linkFixture.Root 'junction-target'
    [IO.Directory]::Move($linkPath, $linkTarget)
    $linkCreated = $false
    try {
        $linkType = 'SymbolicLink'
        if ($script:OHTestWindows) { $linkType = 'Junction' }
        $null = New-Item -ItemType $linkType -Path $linkPath -Target $linkTarget -ErrorAction Stop
        $linkCreated = $true
    } catch {
        Skip-OHCase 'Reparse-point target rejected before mutation' ('Cannot create a disposable link: ' + $_.Exception.Message)
    }
    if ($linkCreated) {
        Test-OHCase 'Reparse-point target rejected before mutation' {
            $before = Get-OHState $linkFixture.Root
            Assert-OHThrows { Invoke-OHFixture $linkFixture Apply } 'Apply followed a reparse point.'
            Assert-OHEqual $before (Get-OHState $linkFixture.Root) 'Reparse-point rejection changed a source or its external target.'
        }
    }

    if ($script:OHTestWindows) {
        Test-OHCase 'Locked source causes failure with every original source preserved' {
            $fixture = New-OHFixture
            $before = Get-OHUserState $fixture
            $lockedPath = Join-Path $fixture.Overwrite $fixture.Selected[2]
            $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                Assert-OHThrows { Invoke-OHFixture $fixture Apply } 'Apply succeeded despite a delete-denying source handle.'
            } finally {
                $handle.Dispose()
            }
            Assert-OHEqual $before (Get-OHUserState $fixture) 'A locked-file failure left a partial removal or altered unrelated files.'
        }
    } else {
        Skip-OHCase 'Locked source causes failure with every original source preserved' 'Windows delete-sharing semantics are required.'
    }
} catch {
    $script:OHTestFailed++
    Write-Host ('FATAL ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
} finally {
    if ($KeepFixtures) {
        Write-Host ('Disposable fixtures retained at: ' + $script:OHTestRoot)
    } else {
        try { Remove-OHFixtureTree $script:OHTestRoot }
        catch {
            $script:OHTestFailed++
            Write-Host ('FAIL fixture cleanup: ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

Write-Host ('Results: {0} passed, {1} failed, {2} skipped.' -f $script:OHTestPassed, $script:OHTestFailed, $script:OHTestSkipped)
if ($script:OHTestFailed -gt 0) { exit 1 }
exit 0
