[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OfficialZip,

    [Parameter(Mandatory = $true)]
    [string] $CustomZip,

    [Parameter(Mandatory = $true)]
    [string] $ControlDll,

    [Parameter(Mandatory = $true)]
    [string] $PatchedDll,

    [Parameter(Mandatory = $true)]
    [string] $ReportDir,

    [Parameter(Mandatory = $true)]
    [string] $VerifyWorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExpectedOfficialZipSha256 = "608b7b2fed4c35751cd264a87dcfe9d9074fb6d48458d29bde955f1c03dc0d5c"
$ExpectedOfficialDllSha256 = "cee7aaccfeaa19ae2f865bb80e08afdd63fa1f14968c44c0a0538bf0b8d931b2"
$DllRelativePath = "red4ext\plugins\ArchiveXL\ArchiveXL.dll"
$ExpectedFileCount = 27
$ExpectedExports = @("Main", "Query", "Supports")

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-Sha256 {
    param([string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-FileMap {
    param([string] $Root)

    $Map = @{}
    foreach ($File in Get-ChildItem -LiteralPath $Root -File -Recurse) {
        $RelativePath = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace("/", "\")
        $Map[$RelativePath] = Get-Sha256 -Path $File.FullName
    }

    return $Map
}

function Find-Dumpbin {
    $ProgramFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
    $VsWhere = Join-Path $ProgramFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
    Assert-True (Test-Path -LiteralPath $VsWhere) "vswhere.exe was not found."

    $InstallPath = (& $VsWhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath | Select-Object -First 1).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $InstallPath) "Visual Studio C++ tools were not found."

    $ToolsetsRoot = Join-Path $InstallPath "VC\Tools\MSVC"
    $Toolset = Get-ChildItem -LiteralPath $ToolsetsRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    Assert-True ($null -ne $Toolset) "No MSVC toolset directory was found."

    $Dumpbin = Join-Path $Toolset.FullName "bin\Hostx64\x64\dumpbin.exe"
    Assert-True (Test-Path -LiteralPath $Dumpbin) "dumpbin.exe was not found at $Dumpbin."
    return $Dumpbin
}

function Get-PeFacts {
    param(
        [string] $Label,
        [string] $DllPath,
        [string] $DumpbinPath,
        [string] $OutputDir
    )

    $Headers = (& $DumpbinPath /nologo /headers $DllPath 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "dumpbin /headers failed for $Label."
    $Exports = (& $DumpbinPath /nologo /exports $DllPath 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "dumpbin /exports failed for $Label."
    $Dependents = (& $DumpbinPath /nologo /dependents $DllPath 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "dumpbin /dependents failed for $Label."
    $Imports = (& $DumpbinPath /nologo /imports $DllPath 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "dumpbin /imports failed for $Label."

    $Headers | Set-Content -LiteralPath (Join-Path $OutputDir "$Label-headers.txt") -Encoding utf8
    $Exports | Set-Content -LiteralPath (Join-Path $OutputDir "$Label-exports.txt") -Encoding utf8
    $Dependents | Set-Content -LiteralPath (Join-Path $OutputDir "$Label-dependents.txt") -Encoding utf8
    $Imports | Set-Content -LiteralPath (Join-Path $OutputDir "$Label-imports.txt") -Encoding utf8

    Assert-True ($Headers -match "(?im)^\s*8664 machine \(x64\)") "$Label is not an x64 PE image."

    $ExportNames = [regex]::Matches(
        $Exports,
        "(?m)^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+([^\s=]+)(?:\s+=.*)?\s*$"
    ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

    $Dependencies = [regex]::Matches(
        $Dependents,
        "(?im)^\s+([A-Za-z0-9_.-]+\.dll)\s*$"
    ) | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique

    $ImportModules = [regex]::Matches(
        $Imports,
        "(?im)^\s+([A-Za-z0-9_.-]+\.dll)\s*$"
    ) | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique

    $VersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($DllPath)
    $Signature = Get-AuthenticodeSignature -LiteralPath $DllPath

    return [pscustomobject]@{
        Label = $Label
        Path = $DllPath
        Sha256 = Get-Sha256 -Path $DllPath
        ProductVersion = $VersionInfo.ProductVersion
        FileVersion = $VersionInfo.FileVersion
        ProductName = $VersionInfo.ProductName
        SignatureStatus = $Signature.Status.ToString()
        Exports = @($ExportNames)
        Dependencies = @($Dependencies)
        ImportModules = @($ImportModules)
    }
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

if (Test-Path -LiteralPath $VerifyWorkDir) {
    Remove-Item -LiteralPath $VerifyWorkDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $VerifyWorkDir | Out-Null

$OfficialStage = Join-Path $VerifyWorkDir "official"
$CustomStage = Join-Path $VerifyWorkDir "custom"

try {
    Assert-True (Test-Path -LiteralPath $OfficialZip) "Official ZIP is missing: $OfficialZip"
    Assert-True (Test-Path -LiteralPath $CustomZip) "Custom ZIP is missing: $CustomZip"
    Assert-True (Test-Path -LiteralPath $ControlDll) "Control DLL is missing: $ControlDll"
    Assert-True (Test-Path -LiteralPath $PatchedDll) "Patched DLL is missing: $PatchedDll"

    $OfficialZipSha = Get-Sha256 -Path $OfficialZip
    Assert-True ($OfficialZipSha -eq $ExpectedOfficialZipSha256) `
        "Official ZIP SHA-256 mismatch. Expected $ExpectedOfficialZipSha256, got $OfficialZipSha."

    Expand-Archive -LiteralPath $OfficialZip -DestinationPath $OfficialStage
    Expand-Archive -LiteralPath $CustomZip -DestinationPath $CustomStage

    $OfficialMap = Get-FileMap -Root $OfficialStage
    $CustomMap = Get-FileMap -Root $CustomStage

    Assert-True ($OfficialMap.Count -eq $ExpectedFileCount) `
        "Official package has $($OfficialMap.Count) files; expected $ExpectedFileCount."
    Assert-True ($CustomMap.Count -eq $ExpectedFileCount) `
        "Custom package has $($CustomMap.Count) files; expected $ExpectedFileCount."

    $MissingPaths = @($OfficialMap.Keys | Where-Object { -not $CustomMap.ContainsKey($_) })
    $ExtraPaths = @($CustomMap.Keys | Where-Object { -not $OfficialMap.ContainsKey($_) })
    Assert-True ($MissingPaths.Count -eq 0) "Custom package is missing paths: $($MissingPaths -join ', ')"
    Assert-True ($ExtraPaths.Count -eq 0) "Custom package has extra paths: $($ExtraPaths -join ', ')"

    foreach ($RelativePath in $OfficialMap.Keys) {
        if ($RelativePath -ne $DllRelativePath) {
            Assert-True ($OfficialMap[$RelativePath] -eq $CustomMap[$RelativePath]) `
                "Non-DLL package file changed unexpectedly: $RelativePath"
        }
    }

    $OfficialDll = Join-Path $OfficialStage $DllRelativePath
    $CustomDll = Join-Path $CustomStage $DllRelativePath
    $OfficialDllSha = Get-Sha256 -Path $OfficialDll
    $PatchedDllSha = Get-Sha256 -Path $PatchedDll
    $CustomDllSha = Get-Sha256 -Path $CustomDll
    $ControlDllSha = Get-Sha256 -Path $ControlDll

    Assert-True ($OfficialDllSha -eq $ExpectedOfficialDllSha256) `
        "Official DLL SHA-256 mismatch. Expected $ExpectedOfficialDllSha256, got $OfficialDllSha."
    Assert-True ($CustomDllSha -eq $PatchedDllSha) "Packaged DLL does not match the patched Release DLL."
    Assert-True ($PatchedDllSha -ne $OfficialDllSha) "Patched DLL unexpectedly matches the official DLL."
    Assert-True ($PatchedDllSha -ne $ControlDllSha) "Patched DLL unexpectedly matches the control build."

    $Dumpbin = Find-Dumpbin
    $OfficialFacts = Get-PeFacts -Label "official" -DllPath $OfficialDll -DumpbinPath $Dumpbin -OutputDir $ReportDir
    $ControlFacts = Get-PeFacts -Label "control" -DllPath $ControlDll -DumpbinPath $Dumpbin -OutputDir $ReportDir
    $PatchedFacts = Get-PeFacts -Label "patched" -DllPath $PatchedDll -DumpbinPath $Dumpbin -OutputDir $ReportDir

    foreach ($Facts in @($OfficialFacts, $ControlFacts, $PatchedFacts)) {
        Assert-True (($Facts.Exports -join ",") -eq ($ExpectedExports -join ",")) `
            "$($Facts.Label) exports are unexpected: $($Facts.Exports -join ', ')"
        Assert-True ($Facts.ProductName -eq "ArchiveXL") `
            "$($Facts.Label) ProductName is unexpected: $($Facts.ProductName)"
        Assert-True ($Facts.ProductVersion -eq "1.27.1") `
            "$($Facts.Label) ProductVersion is not 1.27.1: $($Facts.ProductVersion)"
    }

    Assert-True (($PatchedFacts.Dependencies -join ",") -eq ($ControlFacts.Dependencies -join ",")) `
        "Patched and control DLL dependency lists differ."
    Assert-True (($PatchedFacts.ImportModules -join ",") -eq ($ControlFacts.ImportModules -join ",")) `
        "Patched and control DLL import-module sets differ."
    Assert-True ($OfficialFacts.SignatureStatus -eq "NotSigned") `
        "Official DLL Authenticode status is unexpected: $($OfficialFacts.SignatureStatus)"
    Assert-True ($PatchedFacts.SignatureStatus -eq "NotSigned") `
        "Patched DLL Authenticode status is unexpected: $($PatchedFacts.SignatureStatus)"

    $OfficialDependencyComparison = if (
        ($PatchedFacts.Dependencies -join ",") -eq ($OfficialFacts.Dependencies -join ",")
    ) {
        "MATCH"
    }
    else {
        "DIFFERENT (informational: compiler/toolchain versions can change system imports)"
    }

    $InventoryLines = foreach ($RelativePath in ($OfficialMap.Keys | Sort-Object)) {
        "{0}  {1}" -f $OfficialMap[$RelativePath], $RelativePath
    }
    $InventoryLines | Set-Content -LiteralPath (Join-Path $ReportDir "official-package-files.sha256") -Encoding utf8

    $VerificationLines = @(
        "VERIFICATION: PASS"
        ""
        "Official ZIP SHA-256: $OfficialZipSha"
        "Official DLL SHA-256: $OfficialDllSha"
        "Control DLL SHA-256: $ControlDllSha"
        "Patched DLL SHA-256: $PatchedDllSha"
        "Package file count: $ExpectedFileCount"
        "Only changed package path: $DllRelativePath"
        "Exports: $($PatchedFacts.Exports -join ', ')"
        "Dependencies: $($PatchedFacts.Dependencies -join ', ')"
        "Import modules: $($PatchedFacts.ImportModules -join ', ')"
        "Official dependency comparison: $OfficialDependencyComparison"
        "Patched ProductName: $($PatchedFacts.ProductName)"
        "Patched ProductVersion: $($PatchedFacts.ProductVersion)"
        "Patched FileVersion: $($PatchedFacts.FileVersion)"
        "Patched Authenticode: $($PatchedFacts.SignatureStatus)"
        "dumpbin: $Dumpbin"
    )
    $VerificationLines | Set-Content -LiteralPath (Join-Path $ReportDir "VERIFICATION.txt") -Encoding utf8

    Write-Host "All package and PE verification checks passed."
}
finally {
    if (Test-Path -LiteralPath $VerifyWorkDir) {
        Remove-Item -LiteralPath $VerifyWorkDir -Recurse -Force
    }
}
