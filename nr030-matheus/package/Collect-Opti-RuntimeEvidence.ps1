#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Collect')][string]$Action='Collect',[string]$Mo2Root='C:\CYBERPUNK_ARK_PACK_MO2')
$runtimeRequestedRoot=$Mo2Root
. (Join-Path $PSScriptRoot 'Motion-Tuning.ps1') -Action Collect
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:RuntimeExpectedDxgiHash='ba4df99acf55278c617780d56b89847553063ebc8e521bf831e09d21d5c0b04b'

function Get-RuntimeSnapshot([string]$Path) {
    Assert-NoReparse $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Evidence source is not a file: '+$Path) }
    $before=Get-Item -LiteralPath $Path -Force
    $size=$before.Length;$modified=$before.LastWriteTimeUtc.ToString('o')
    $hash=Get-Hash $Path
    Assert-NoReparse $Path
    $after=Get-Item -LiteralPath $Path -Force
    if ($after.Length -ne $size -or $after.LastWriteTimeUtc.ToString('o') -cne $modified) { throw ('Evidence source changed while reading: '+$Path) }
    [pscustomobject]@{Source=$Path;Size=$size;Sha256=$hash;ModifiedUtc=$modified}
}
function Assert-RuntimeSnapshot($Before) {
    $after=Get-RuntimeSnapshot $Before.Source
    # PS 7 may deserialize ISO JSON timestamps as DateTime; PS 5.1 keeps strings.
    if ($after.Size -ne $Before.Size -or $after.Sha256 -cne $Before.Sha256 -or [DateTimeOffset]$after.ModifiedUtc -ne [DateTimeOffset]$Before.ModifiedUtc) { throw ('Evidence source changed during collection: '+$Before.Source) }
}
function Read-RuntimeZipText($Archive,[string]$Name) {
    $entry=$Archive.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose();$stream.Dispose() }
}
function Get-RuntimeEntryHash($Entry) {
    $stream=$Entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose();$stream.Dispose() }
}
function Assert-RuntimeZipInventory($Archive,$Inventory) {
    $seen=@{}
    foreach ($item in $Inventory) {
        if ($item -is [array]) { throw 'Evidence inventory contains a nested array instead of file records.' }
        $name=[string]$item.Entry
        if ($seen.ContainsKey($name)) { throw ('Duplicate evidence inventory entry: '+$name) }
        $seen[$name]=$true
        $entries=@($Archive.Entries | Where-Object { $_.FullName -ceq $name })
        if ($entries.Count -ne 1 -or $entries[0].Length -ne [long]$item.Size -or (Get-RuntimeEntryHash $entries[0]) -cne $item.Sha256) { throw ('Evidence ZIP verification failed: '+$name) }
    }
}
function Set-RuntimeZipJson($Archive,[string]$Name,$Value) {
    $old=$Archive.GetEntry($Name)
    if ($null -ne $old) { $old.Delete() }
    $entry=$Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal)
    $stream=$entry.Open();$writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($true)))
    try { $writer.Write(($Value | ConvertTo-Json -Depth 12)) } finally { $writer.Dispose();$stream.Dispose() }
}
function Get-RuntimeObservations($Archive,$Inventory) {
    $sessions=New-Object 'System.Collections.Generic.List[object]'
    $opti=New-Object 'System.Collections.Generic.List[object]'
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    $latest=[DateTimeOffset]::MinValue;$invalidSession=$false
    $style=[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    foreach ($side in @('ark','overwrite')) {
        $text=Read-RuntimeZipText $Archive ($side+'/MatheusNR030.log')
        if ($null -eq $text) { continue }
        # No install/source success is invented: retain observations from the existing parser.
        $summary=Get-AddonSessionSummary $text '' ''
        $time=[DateTimeOffset]::MinValue
        $valid=$summary.HeaderFound -and [DateTimeOffset]::TryParse($summary.SessionUtc,[Globalization.CultureInfo]::InvariantCulture,$style,[ref]$time)
        if (-not $valid) { $invalidSession=$true;$warnings.Add('INVALID_OR_MISSING_LATEST_ADDON_SESSION '+$side) }
        elseif ($time -gt $latest) { $latest=$time }
        $sessions.Add([pscustomobject]@{Side=$side;ValidLatestHeader=$valid;SessionUtc=$summary.SessionUtc;SourceCommit=$summary.SourceCommit;HookActive=$summary.HookActive;StatsFound=$summary.StatsFound;Seen=$summary.Seen;NrRecorded=$summary.NrRecorded;RuntimeValidated=$false})
    }
    $sessionUtc=$null
    if (-not $invalidSession -and $latest -ne [DateTimeOffset]::MinValue) { $sessionUtc=$latest.ToString('o') }
    foreach ($side in @('ark','overwrite')) {
        $ini=Read-RuntimeZipText $Archive ($side+'/OptiScaler.ini')
        if ($null -eq $ini) { continue }
        try {
            $toFile=Read-IniValue $ini 'Log' 'LogToFile';$level=Read-IniValue $ini 'Log' 'LogLevel'
            $single=Read-IniValue $ini 'Log' 'SingleFile';$filename=Read-IniValue $ini 'Log' 'LogFileName'
            if ($toFile -ine 'true') { $warnings.Add('OPTISCALER_FILE_LOGGING_NOT_EXPLICITLY_ENABLED '+$side+': LogToFile='+$toFile) }
            $names=@($side+'/OptiScaler.log')
            if ($filename -and $filename -ine 'auto') { $names += ('configured-'+$side+'/OptiScaler-configured.log') }
            foreach ($name in $names) {
                $records=@($Inventory | Where-Object { $_.Entry -ceq $name })
                $result='NOT_COLLECTED_OR_MISSING';$modified=$null
                if ($records.Count -eq 1) {
                    $modified=$records[0].ModifiedUtc;$time=[DateTimeOffset]::MinValue
                    $result='NO_SESSION_TIME_FOR_COMPARISON'
                    if ($modified -is [DateTime] -or $modified -is [DateTimeOffset]) { $modified=([DateTimeOffset]$modified).ToString('o') }
                    if ($sessionUtc -and [DateTimeOffset]::TryParse($modified,[Globalization.CultureInfo]::InvariantCulture,$style,[ref]$time)) {
                        $result='TIMESTAMP_COMPATIBLE_ONLY'
                        if ($time -lt $latest) { $result='STALE_BEFORE_ADDON_SESSION' }
                    }
                }
                if ($result -cne 'TIMESTAMP_COMPATIBLE_ONLY') { $warnings.Add($result+' '+$name) }
                $opti.Add([pscustomobject]@{Side=$side;Entry=$name;LogToFile=$toFile;LogLevel=$level;SingleFile=$single;LogFileName=$filename;ModifiedUtc=$modified;Result=$result;RuntimeValidated=$false})
            }
        } catch { $warnings.Add('OPTISCALER_LOG_CONFIGURATION_UNREADABLE '+$side+': '+$_.Exception.Message) }
    }
    [pscustomobject]@{ComparedAddonSessionUtc=$sessionUtc;AddonSessions=@($sessions.ToArray());OptiLogs=@($opti.ToArray());Warnings=@($warnings.ToArray());TimestampComparisonProvesRuntime=$false;GraphicsFixVerified=$false}
}
function Collect-OptiRuntimeEvidence($Paths) {
    Assert-Stopped
    $results=Join-Path $script:PackageRoot 'Results';Assert-NoReparse $results
    New-Item -ItemType Directory -Path $results -Force | Out-Null
    $name='MOTION_RUNTIME_EVIDENCE-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $stage=Join-Path $results ($name+'-stage');New-Item -ItemType Directory -Path $stage | Out-Null
    $pending=Join-Path $results ($name+'.pending');$final=Join-Path $results ($name+'.zip')
    $binaries=New-Object 'System.Collections.Generic.List[object]'
    $captured=New-Object 'System.Collections.Generic.List[object]'
    $completed=$false
    try {
        # Exactly these two loader locations; never search for or include NR model binaries.
        foreach ($location in @(@('ark',$Paths.Bin),@('overwrite',$Paths.OldBin))) {
            $source=Join-Path $location[1] 'dxgi.dll';Assert-NoReparse $source
            if (-not (Test-Path -LiteralPath $source)) {
                $binaries.Add([pscustomobject]@{Side=$location[0];Source=$source;Entry=$null;Status='MISSING';Size=$null;Sha256=$null;ExpectedSha256=$script:RuntimeExpectedDxgiHash;MatchesExpected=$false;LoadedByGameVerified=$false})
                continue
            }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('A directory occupies dxgi.dll: '+$source) }
            if ((Get-Item -LiteralPath $source).Length -gt 128MB) { throw ('dxgi.dll exceeds the 128 MiB diagnostic limit: '+$source) }
            $snapshot=Get-RuntimeSnapshot $source
            $copy=Join-Path $stage ($location[0]+'-dxgi.dll')
            Copy-Verified $source $copy
            Assert-RuntimeSnapshot $snapshot
            if ((Get-Item -LiteralPath $copy).Length -ne $snapshot.Size -or (Get-Hash $copy) -cne $snapshot.Sha256) { throw ('Copied dxgi.dll changed during collection: '+$source) }
            $entry=$location[0]+'/dxgi.dll'
            $captured.Add([pscustomobject]@{Source=$source;Entry=$entry;Size=$snapshot.Size;Sha256=$snapshot.Sha256;ModifiedUtc=$snapshot.ModifiedUtc;Copy=$copy})
            $binaries.Add([pscustomobject]@{Side=$location[0];Source=$source;Entry=$entry;Status='COPIED_AND_HASH_VERIFIED';Size=$snapshot.Size;Sha256=$snapshot.Sha256;ExpectedSha256=$script:RuntimeExpectedDxgiHash;MatchesExpected=($snapshot.Sha256 -ceq $script:RuntimeExpectedDxgiHash);LoadedByGameVerified=$false})
        }
        Assert-Stopped
        # Keep the existing full collector and its configured-path/missing-file notes.
        $baseZip=Collect-MotionEvidence $Paths 6>$null
        Assert-NoReparse $baseZip
        Copy-Verified $baseZip $pending
        $archive=[IO.Compression.ZipFile]::Open($pending,[IO.Compression.ZipArchiveMode]::Update)
        try {
            # Windows PowerShell 5.1 emits a JSON array as one pipeline object.
            # Assign before @() so both PS 5.1 and PS 7 produce flat file records.
            $parsedInventory=(Read-RuntimeZipText $archive 'inventory.json') | ConvertFrom-Json
            $inventory=@($parsedInventory)
            Assert-RuntimeZipInventory $archive $inventory
            foreach ($item in $captured.ToArray()) {
                $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$item.Copy,$item.Entry,[IO.Compression.CompressionLevel]::Optimal)
                $inventory += [pscustomobject]@{Source=$item.Source;Entry=$item.Entry;Size=$item.Size;Sha256=$item.Sha256;ModifiedUtc=$item.ModifiedUtc}
            }
            $observations=Get-RuntimeObservations $archive $inventory
            Set-RuntimeZipJson $archive 'inventory.json' @($inventory)
            Set-RuntimeZipJson $archive 'RUNTIME_EVIDENCE.json' ([pscustomobject]@{SchemaVersion=1;CollectionUtc=[DateTime]::UtcNow.ToString('o');Purpose='Read-only OptiScaler/XeFG diagnostics and exact loader binary identification';Binaries=@($binaries.ToArray());Observations=$observations;GameFilesChanged=$false;GraphicsFixVerified=$false})
        } finally { $archive.Dispose() }
        # Verification covers every archived source file, including copied DLLs.
        $verify=[IO.Compression.ZipFile]::OpenRead($pending)
        try { Assert-RuntimeZipInventory $verify $inventory } finally { $verify.Dispose() }
        Assert-Stopped
        foreach ($item in $inventory) { Assert-RuntimeSnapshot $item }
        foreach ($binary in $binaries.ToArray()) {
            Assert-NoReparse $binary.Source
            if ($binary.Status -ceq 'MISSING' -and (Test-Path -LiteralPath $binary.Source)) { throw ('Evidence source appeared during collection: '+$binary.Source) }
        }
        [IO.File]::Move($pending,$final);$completed=$true
        foreach ($warning in $observations.Warnings) { Write-Host ('EVIDENCE WARNING: '+$warning) }
        foreach ($binary in $binaries.ToArray()) {
            Write-Host ('dxgi.dll '+$binary.Side+': '+$binary.Status+'; matches previously observed hash='+$binary.MatchesExpected)
        }
        Write-Host ('Runtime evidence saved: '+$final)
        Write-Host 'Logs and exact dxgi.dll copies only. No game settings or binaries were changed. This does not verify a graphics fix.'
        return $final
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        if (-not $completed -and (Test-Path -LiteralPath $pending)) { Remove-Item -LiteralPath $pending -Force }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    try { $null=Collect-OptiRuntimeEvidence (Get-Paths $runtimeRequestedRoot);exit 0 }
    catch { Write-Host ('NOT COMPLETED: '+$_.Exception.Message) -ForegroundColor Red;exit 1 }
}
