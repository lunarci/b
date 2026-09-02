[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$UpstreamUrl = "https://github.com/psiberx/cp2077-archive-xl.git"
$UpstreamCommit = "55f48569f415b443debba4f4ad4cf241194cd06e"
$PrNumber = 22
$PrCommit = "c2513790d86ed58963060b7f79d23e3f15294732"
$ExpectedPatchSha256 = "616fd81751793ac4fd9231f13ee6d96d491fbe8351e2ced39dd3fabeac935814"
$ExpectedOfficialZipSha256 = "608b7b2fed4c35751cd264a87dcfe9d9074fb6d48458d29bde955f1c03dc0d5c"
$ExpectedOfficialDllSha256 = "cee7aaccfeaa19ae2f865bb80e08afdd63fa1f14968c44c0a0538bf0b8d931b2"
$CompatibleMimallocVersion = "2.2.4"
$DllRelativePath = "red4ext\plugins\ArchiveXL\ArchiveXL.dll"

$ExpectedSubmodules = [ordered]@{
    "vendor/RED4ext.SDK" = "8e58b13395c9be6725f6227e5f4fc7558ac27084"
    "vendor/wil" = "5bb5fbddf4b9c8e602c2da690f342839ad54084a"
    "vendor/semver" = "d3645f7b7d9c0d2d91c9a1e817c4d47ea4ccf514"
    "vendor/nameof" = "9494cbd4aadef3c34f7dccdc93d544b00c0a26b9"
}

$AllowedSubmoduleUrls = @(
    "https://github.com/psiberx/RED4ext.SDK.git"
    "https://github.com/microsoft/wil.git"
    "https://github.com/Neargye/semver.git"
    "https://github.com/Neargye/nameof.git"
)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$WorkRoot = Join-Path $RepoRoot "work"
$ArtifactRoot = Join-Path $RepoRoot "artifacts"
$LogRoot = Join-Path $ArtifactRoot "logs"
$ReportRoot = Join-Path $ArtifactRoot "reports"
$ControlSource = Join-Path $WorkRoot "source-control"
$PatchedSource = Join-Path $WorkRoot "source-patched"
$PackageStage = Join-Path $WorkRoot "package-stage"
$VerifyWork = Join-Path $WorkRoot "verify"
$PatchPath = Join-Path $RepoRoot "patches\pr22-appearance-readonly.patch"
$OfficialZip = Join-Path $RepoRoot "input\ArchiveXL-1.27.1-official.zip"
$PinnedLock = Join-Path $RepoRoot "locks\xmake-requires.lock"
$OutputPackage = Join-Path $ArtifactRoot "ArchiveXL-1.27.1-PR22-NDEBUG-Test.zip"

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

function Invoke-NativeLogged {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $LogPath
    )

    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Host
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "$FilePath failed with exit code $ExitCode. See $LogPath"
    }
}

function Get-GitOutput {
    param(
        [string] $WorkingTree,
        [string[]] $ArgumentList
    )

    $Output = & git -C $WorkingTree @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($ArgumentList -join ' ') failed in $WorkingTree.`n$($Output | Out-String)"
    }
    return ($Output | Out-String).Trim()
}

function Enable-NDebugForRelease {
    param(
        [string] $SourceDir,
        [string] $Label
    )

    $XmakePath = Join-Path $SourceDir "xmake.lua"
    $Text = Get-Content -LiteralPath $XmakePath -Raw
    $Needle = '    add_cxxflags("/Ob2")'
    $Insertion = "`n    " + 'add_defines("NDEBUG")'

    Assert-True ($Text.Contains($Needle)) `
        "$Label xmake.lua does not contain the expected Release flag block."
    Assert-True (-not $Text.Contains('add_defines("NDEBUG")')) `
        "$Label xmake.lua already defines NDEBUG unexpectedly."

    $Updated = $Text.Replace($Needle, "$Needle$Insertion")
    Assert-True (($Updated.Length - $Text.Length) -eq $Insertion.Length) `
        "$Label xmake.lua NDEBUG edit was not the expected single insertion."
    [IO.File]::WriteAllText($XmakePath, $Updated, [Text.UTF8Encoding]::new($false))

    $Written = Get-Content -LiteralPath $XmakePath -Raw
    Assert-True ($Written.Contains("$Needle$Insertion")) `
        "$Label xmake.lua did not retain the Release-only NDEBUG definition."
}

function Initialize-UpstreamSource {
    param(
        [string] $Destination,
        [string] $Label
    )

    $LogPath = Join-Path $LogRoot "$Label-source.log"
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("init", $Destination) -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("-C", $Destination, "config", "core.autocrlf", "false") -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("-C", $Destination, "config", "core.eol", "lf") -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("-C", $Destination, "remote", "add", "origin", $UpstreamUrl) -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("-C", $Destination, "fetch", "--depth=1", "origin", $UpstreamCommit) -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @("-C", $Destination, "checkout", "--detach", "FETCH_HEAD") -LogPath $LogPath

    $Head = Get-GitOutput -WorkingTree $Destination -ArgumentList @("rev-parse", "HEAD")
    Assert-True ($Head -eq $UpstreamCommit) "$Label source HEAD mismatch: $Head"

    $GitModulesOutput = Get-GitOutput -WorkingTree $Destination -ArgumentList @(
        "config", "--file", ".gitmodules", "--get-regexp", "^submodule\..*\.url$"
    )
    $ConfiguredUrls = @(
        $GitModulesOutput -split "`r?`n" |
            ForEach-Object { ($_ -split "\s+", 2)[1] }
    )

    Assert-True ($ConfiguredUrls.Count -eq $AllowedSubmoduleUrls.Count) `
        "$Label has an unexpected number of submodule URLs."
    foreach ($Url in $ConfiguredUrls) {
        Assert-True ($Url -in $AllowedSubmoduleUrls) "$Label has an unapproved submodule URL: $Url"
    }

    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $Destination, "submodule", "sync", "--recursive"
    ) -LogPath $LogPath
    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $Destination, "submodule", "update", "--init", "--recursive"
    ) -LogPath $LogPath

    $SubmoduleStatus = Get-GitOutput -WorkingTree $Destination -ArgumentList @("submodule", "status", "--recursive")
    Assert-True (-not ($SubmoduleStatus -match "(?m)^[+\-U]")) `
        "$Label has an uninitialized or mismatched submodule.`n$SubmoduleStatus"
    $SubmoduleStatus | Set-Content -LiteralPath (Join-Path $ReportRoot "$Label-submodules.txt") -Encoding utf8

    foreach ($Entry in $ExpectedSubmodules.GetEnumerator()) {
        $ActualCommit = Get-GitOutput -WorkingTree (Join-Path $Destination $Entry.Key) -ArgumentList @("rev-parse", "HEAD")
        Assert-True ($ActualCommit -eq $Entry.Value) `
            "$Label submodule $($Entry.Key) mismatch: expected $($Entry.Value), got $ActualCommit"
    }

    $ProjectText = Get-Content -LiteralPath (Join-Path $Destination "xmake.lua") -Raw
    Assert-True ($ProjectText.Contains('set_version("1.27.1"')) `
        "$Label source does not declare ArchiveXL 1.27.1."

    $TargetFile = Join-Path $Destination "src\App\Extensions\ResourcePatch\Extension.cpp"
    $TargetText = Get-Content -LiteralPath $TargetFile -Raw
    Assert-True ($TargetText.Contains("return appearances[{}];")) `
        "$Label source does not contain the expected pre-PR #22 statement."
    Assert-True (-not $TargetText.Contains("auto defaultIt = appearances.find({});")) `
        "$Label source unexpectedly already contains the PR #22 change."

    $TrackedStatus = Get-GitOutput -WorkingTree $Destination -ArgumentList @("status", "--porcelain", "--untracked-files=no")
    Assert-True (-not $TrackedStatus) "$Label source is not clean after checkout.`n$TrackedStatus"
}

function Build-ArchiveXL {
    param(
        [string] $SourceDir,
        [ValidateSet("release", "releasedbg")]
        [string] $Mode,
        [string] $Label
    )

    $LogPath = Join-Path $LogRoot "$Label-$Mode-build.log"
    Push-Location $SourceDir
    try {
        Invoke-NativeLogged -FilePath "xmake" -ArgumentList @(
            "f", "-c", "-p", "windows", "-a", "x64", "-m", $Mode,
            "--policies=package.requires_lock,package.precompiled:n", "-y"
        ) -LogPath $LogPath
        Invoke-NativeLogged -FilePath "xmake" -ArgumentList @(
            "-r", "-vD", "-y", "ArchiveXL"
        ) -LogPath $LogPath
    }
    finally {
        Pop-Location
    }

    $OutputDll = Join-Path $SourceDir "build\windows\x64\$Mode\ArchiveXL.dll"
    Assert-True (Test-Path -LiteralPath $OutputDll) "$Label $Mode DLL was not produced at $OutputDll."
    return $OutputDll
}

function Assert-CompatibleDependencyLock {
    param([string] $LockPath)

    Assert-True (Test-Path -LiteralPath $LockPath) "Xmake dependency lock is missing: $LockPath"
    $LockText = Get-Content -LiteralPath $LockPath -Raw
    Assert-True ($LockText -match '(?s)__meta__\s*=\s*\{.*?version\s*=\s*"1\.0"') `
        "Xmake dependency lock has no supported metadata block."

    $MimallocMatches = [regex]::Matches(
        $LockText,
        '(?s)\["[^"]*mimalloc[^"]*"\]\s*=\s*\{.*?version\s*=\s*"([^"]+)"'
    )
    Assert-True ($MimallocMatches.Count -gt 0) "Xmake dependency lock has no mimalloc entry."
    foreach ($Match in $MimallocMatches) {
        $LockedVersion = $Match.Groups[1].Value
        Assert-True ($LockedVersion -eq "v$CompatibleMimallocVersion") `
            "Incompatible mimalloc lock entry: $LockedVersion"
    }
}

function New-CompatibleDependencyLock {
    param([string] $SourceDir)

    $LogPath = Join-Path $LogRoot "dependency-lock.log"
    $ProjectPath = Join-Path $SourceDir "xmake.lua"
    $OriginalProjectText = [IO.File]::ReadAllText($ProjectPath)
    $RequireLine = 'add_requires("hopscotch-map", "minhook", "spdlog", "tiltedcore", "yaml-cpp")'
    $CompatibilityLine = `
        "add_requireconfs(`"*.mimalloc`", { version = `"$CompatibleMimallocVersion`", override = true })"

    Assert-True ($OriginalProjectText.Contains($RequireLine)) `
        "ArchiveXL xmake.lua does not contain the expected dependency declaration."
    Assert-True (-not $OriginalProjectText.Contains('add_requireconfs("*.mimalloc"')) `
        "ArchiveXL xmake.lua unexpectedly already pins transitive mimalloc."

    $TemporaryProjectText = $OriginalProjectText.Replace(
        $RequireLine,
        "$RequireLine`n$CompatibilityLine"
    )
    $Utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($ProjectPath, $TemporaryProjectText, $Utf8NoBom)

    try {
        Push-Location $SourceDir
        try {
            Invoke-NativeLogged -FilePath "xmake" -ArgumentList @(
                "f", "-c", "-p", "windows", "-a", "x64", "-m", "release",
                "--policies=package.requires_lock,package.precompiled:n", "-y"
            ) -LogPath $LogPath
        }
        finally {
            Pop-Location
        }
    }
    finally {
        [IO.File]::WriteAllText($ProjectPath, $OriginalProjectText, $Utf8NoBom)
    }

    $LockPath = Join-Path $SourceDir "xmake-requires.lock"
    Assert-CompatibleDependencyLock -LockPath $LockPath
    $TrackedStatus = Get-GitOutput -WorkingTree $SourceDir -ArgumentList @(
        "status", "--porcelain", "--untracked-files=no"
    )
    Assert-True (-not $TrackedStatus) `
        "Temporary dependency-lock configuration changed tracked source files.`n$TrackedStatus"
}

foreach ($Path in @($WorkRoot, $ArtifactRoot)) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $WorkRoot, $ArtifactRoot, $LogRoot, $ReportRoot | Out-Null

$TranscriptActive = $false
Start-Transcript -LiteralPath (Join-Path $LogRoot "full-transcript.log") | Out-Null
$TranscriptActive = $true

try {
    Assert-True (Test-Path -LiteralPath $PatchPath) "Patch is missing: $PatchPath"
    Assert-True (Test-Path -LiteralPath $OfficialZip) "Official package input is missing: $OfficialZip"

    $PatchSha256 = Get-Sha256 -Path $PatchPath
    $OfficialZipSha256 = Get-Sha256 -Path $OfficialZip
    Assert-True ($PatchSha256 -eq $ExpectedPatchSha256) `
        "Vendored patch SHA-256 mismatch. Expected $ExpectedPatchSha256, got $PatchSha256."
    Assert-True ($OfficialZipSha256 -eq $ExpectedOfficialZipSha256) `
        "Official ZIP SHA-256 mismatch. Expected $ExpectedOfficialZipSha256, got $OfficialZipSha256."

    Initialize-UpstreamSource -Destination $ControlSource -Label "control"
    Initialize-UpstreamSource -Destination $PatchedSource -Label "patched"
    Enable-NDebugForRelease -SourceDir $ControlSource -Label "control"

    $ControlLock = Join-Path $ControlSource "xmake-requires.lock"
    $PatchedLock = Join-Path $PatchedSource "xmake-requires.lock"
    if (Test-Path -LiteralPath $PinnedLock) {
        Write-Host "Using the repository-pinned xmake dependency lock."
        Copy-Item -LiteralPath $PinnedLock -Destination $ControlLock
    }
    else {
        Write-Warning (
            "No repository-pinned xmake lock exists yet. Generating one with mimalloc " +
            "$CompatibleMimallocVersion, the version required by TiltedCore v0.2.9."
        )
        New-CompatibleDependencyLock -SourceDir $ControlSource
    }

    Assert-CompatibleDependencyLock -LockPath $ControlLock
    Copy-Item -LiteralPath $ControlLock -Destination $PatchedLock -Force
    Copy-Item -LiteralPath $ControlLock -Destination (Join-Path $ArtifactRoot "xmake-requires.lock") -Force

    $ControlBuiltDll = Build-ArchiveXL -SourceDir $ControlSource -Mode "release" -Label "control"
    $ControlOutputDir = Join-Path $ArtifactRoot "control-DO-NOT-INSTALL"
    New-Item -ItemType Directory -Force -Path $ControlOutputDir | Out-Null
    $ControlDll = Join-Path $ControlOutputDir "ArchiveXL.dll"
    Copy-Item -LiteralPath $ControlBuiltDll -Destination $ControlDll

    Assert-True (Test-Path -LiteralPath $ControlLock) `
        "Xmake did not generate xmake-requires.lock for the control build."
    Assert-CompatibleDependencyLock -LockPath $ControlLock
    Copy-Item -LiteralPath $ControlLock -Destination (Join-Path $ArtifactRoot "xmake-requires.lock")
    Copy-Item -LiteralPath $ControlLock -Destination $PatchedLock -Force
    if (Test-Path -LiteralPath $PinnedLock) {
        Assert-True ((Get-Sha256 -Path $ControlLock) -eq (Get-Sha256 -Path $PinnedLock)) `
            "Xmake changed the repository-pinned dependency lock during configuration."
    }

    $PatchLog = Join-Path $LogRoot "apply-pr22.log"
    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $PatchedSource, "apply", "--check", $PatchPath
    ) -LogPath $PatchLog
    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $PatchedSource, "apply", $PatchPath
    ) -LogPath $PatchLog
    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $PatchedSource, "diff", "--check"
    ) -LogPath $PatchLog
    Invoke-NativeLogged -FilePath "git" -ArgumentList @(
        "-C", $PatchedSource, "apply", "--reverse", "--check", $PatchPath
    ) -LogPath $PatchLog

    $ChangedFilesOutput = Get-GitOutput -WorkingTree $PatchedSource -ArgumentList @("diff", "--name-only")
    $ChangedFiles = @($ChangedFilesOutput -split "`r?`n")
    Assert-True ($ChangedFiles.Count -eq 1) "Patch changed $($ChangedFiles.Count) tracked files."
    Assert-True ($ChangedFiles[0] -eq "src/App/Extensions/ResourcePatch/Extension.cpp") `
        "Patch changed an unexpected tracked file: $($ChangedFiles[0])"

    $NumStat = Get-GitOutput -WorkingTree $PatchedSource -ArgumentList @("diff", "--numstat")
    $NumStatFields = @($NumStat -split "\s+")
    Assert-True (
        $NumStatFields.Count -eq 3 -and
        $NumStatFields[0] -eq "5" -and
        $NumStatFields[1] -eq "1" -and
        $NumStatFields[2] -eq "src/App/Extensions/ResourcePatch/Extension.cpp"
    ) "Patch diff is not exactly one file with +5/-1: $NumStat"

    $AppliedDiff = Get-GitOutput -WorkingTree $PatchedSource -ArgumentList @("diff", "--binary")
    $AppliedDiff | Set-Content -LiteralPath (Join-Path $ReportRoot "applied-pr22.diff") -Encoding utf8
    Copy-Item -LiteralPath $PatchPath -Destination (Join-Path $ReportRoot "vendored-pr22.patch")

    Enable-NDebugForRelease -SourceDir $PatchedSource -Label "patched"
    $PatchedBuiltDll = Build-ArchiveXL -SourceDir $PatchedSource -Mode "release" -Label "patched"
    Assert-True (Test-Path -LiteralPath $PatchedLock) "Patched build dependency lock is missing."
    Assert-CompatibleDependencyLock -LockPath $PatchedLock
    Assert-True ((Get-Sha256 -Path $PatchedLock) -eq (Get-Sha256 -Path $ControlLock)) `
        "Patched Release build changed the control dependency lock."
    $PatchedOutputDir = Join-Path $ArtifactRoot "patched-release"
    New-Item -ItemType Directory -Force -Path $PatchedOutputDir | Out-Null
    $PatchedDll = Join-Path $PatchedOutputDir "ArchiveXL.dll"
    Copy-Item -LiteralPath $PatchedBuiltDll -Destination $PatchedDll

    $ReleaseDbgBuiltDll = Build-ArchiveXL -SourceDir $PatchedSource -Mode "releasedbg" -Label "patched"
    Assert-True ((Get-Sha256 -Path $PatchedLock) -eq (Get-Sha256 -Path $ControlLock)) `
        "Patched ReleaseDbg build changed the control dependency lock."
    $ReleaseDbgBuiltPdb = Join-Path $PatchedSource "build\windows\x64\releasedbg\ArchiveXL.pdb"
    Assert-True (Test-Path -LiteralPath $ReleaseDbgBuiltPdb) "ReleaseDbg PDB was not produced."
    $ReleaseDbgOutputDir = Join-Path $ArtifactRoot "releasedbg-diagnostic-pair"
    New-Item -ItemType Directory -Force -Path $ReleaseDbgOutputDir | Out-Null
    Copy-Item -LiteralPath $ReleaseDbgBuiltDll -Destination (Join-Path $ReleaseDbgOutputDir "ArchiveXL.dll")
    Copy-Item -LiteralPath $ReleaseDbgBuiltPdb -Destination (Join-Path $ReleaseDbgOutputDir "ArchiveXL.pdb")

    Expand-Archive -LiteralPath $OfficialZip -DestinationPath $PackageStage
    $StageDll = Join-Path $PackageStage $DllRelativePath
    $StageLicenseRoot = Join-Path $PackageStage "red4ext\plugins\ArchiveXL"
    Assert-True (Test-Path -LiteralPath $StageDll) "Official package DLL path is missing: $DllRelativePath"
    Assert-True ((Get-Sha256 -Path $StageDll) -eq $ExpectedOfficialDllSha256) `
        "Official package DLL does not match the expected 1.27.1 baseline."
    Copy-Item -LiteralPath $PatchedDll -Destination $StageDll -Force
    Copy-Item -LiteralPath (Join-Path $StageLicenseRoot "LICENSE") `
        -Destination (Join-Path $ArtifactRoot "ArchiveXL-LICENSE")
    Copy-Item -LiteralPath (Join-Path $StageLicenseRoot "THIRD_PARTY_LICENSES") `
        -Destination (Join-Path $ArtifactRoot "ArchiveXL-THIRD_PARTY_LICENSES")

    Compress-Archive -Path (Join-Path $PackageStage "*") -DestinationPath $OutputPackage -CompressionLevel Optimal

    & (Join-Path $PSScriptRoot "verify.ps1") `
        -OfficialZip $OfficialZip `
        -CustomZip $OutputPackage `
        -ControlDll $ControlDll `
        -PatchedDll $PatchedDll `
        -ReportDir $ReportRoot `
        -VerifyWorkDir $VerifyWork

    $XmakeVersion = (& xmake --version 2>&1 | Out-String).Trim()
    $GitVersion = (& git --version 2>&1 | Out-String).Trim()
    $OsCaption = (Get-CimInstance Win32_OperatingSystem).Caption
    $VsWhere = Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) `
        "Microsoft Visual Studio\Installer\vswhere.exe"
    $VsInstall = (& $VsWhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath | Select-Object -First 1).Trim()
    $MsvcVersions = (Get-ChildItem -LiteralPath (Join-Path $VsInstall "VC\Tools\MSVC") -Directory |
        Select-Object -ExpandProperty Name | Sort-Object) -join ", "
    $LatestMsvcToolset = Get-ChildItem -LiteralPath (Join-Path $VsInstall "VC\Tools\MSVC") -Directory |
        Sort-Object Name -Descending | Select-Object -First 1
    $ClExe = Join-Path $LatestMsvcToolset.FullName "bin\Hostx64\x64\cl.exe"
    $LinkExe = Join-Path $LatestMsvcToolset.FullName "bin\Hostx64\x64\link.exe"
    $DumpbinExe = Join-Path $LatestMsvcToolset.FullName "bin\Hostx64\x64\dumpbin.exe"
    $ClVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($ClExe).FileVersion
    $LinkVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($LinkExe).FileVersion
    $DumpbinVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($DumpbinExe).FileVersion
    $SdkVersions = (Get-ChildItem -LiteralPath (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10\bin") `
        -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object) -join ", "

    $LockSha256 = Get-Sha256 -Path (Join-Path $ArtifactRoot "xmake-requires.lock")
    $ControlDllSha256 = Get-Sha256 -Path $ControlDll
    $PatchedDllSha256 = Get-Sha256 -Path $PatchedDll
    $PackageSha256 = Get-Sha256 -Path $OutputPackage

    $Manifest = @(
        "ArchiveXL 1.27.1 + PR #22 custom test build"
        ""
        "Build UTC: $([DateTime]::UtcNow.ToString('o'))"
        "Upstream repository: $UpstreamUrl"
        "Pinned 1.27.1 source commit: $UpstreamCommit"
        "PR number: $PrNumber"
        "PR provenance commit: $PrCommit"
        "Release assertion policy: NDEBUG explicitly defined for release mode"
        "Vendored patch SHA-256: $PatchSha256"
        "Xmake 3.0.9 archive SHA-256: 0f2c57a29f358e4f9f059cd823f40c3213750dcb13d5b6e9f6e5b29910992d65"
        "Official input ZIP SHA-256: $OfficialZipSha256"
        "Official input DLL SHA-256: $ExpectedOfficialDllSha256"
        "Xmake lock SHA-256: $LockSha256"
        "Mimalloc compatibility lock: v$CompatibleMimallocVersion (TiltedCore v0.2.9 upstream requirement)"
        "Control DLL SHA-256: $ControlDllSha256"
        "Patched Release DLL SHA-256: $PatchedDllSha256"
        "Final package SHA-256: $PackageSha256"
        ""
        "Runner ImageOS: $env:ImageOS"
        "Runner ImageVersion: $env:ImageVersion"
        "Operating system: $OsCaption"
        "PowerShell: $($PSVersionTable.PSVersion)"
        "Git: $GitVersion"
        "Xmake: $XmakeVersion"
        "Visual Studio: $VsInstall"
        "MSVC toolsets: $MsvcVersions"
        "cl.exe FileVersion: $ClVersion"
        "link.exe FileVersion: $LinkVersion"
        "dumpbin.exe FileVersion: $DumpbinVersion"
        "Windows SDK directories: $SdkVersions"
        "Builder commit: $env:GITHUB_SHA"
        "GitHub run ID: $env:GITHUB_RUN_ID"
        "GitHub run number: $env:GITHUB_RUN_NUMBER"
        ""
        "Note: dependency versions are captured in xmake-requires.lock."
        "Note: the DLL contains a build timestamp, and runner/toolchain images can change; this is provenance-reproducible, not guaranteed bit-for-bit reproducible."
        "Note: CI performs compilation and static checks only. It does not prove in-game stability."
    )
    $Manifest += "Submodule vendor/RED4ext.SDK: $($ExpectedSubmodules['vendor/RED4ext.SDK'])"
    $Manifest += "Submodule vendor/wil: $($ExpectedSubmodules['vendor/wil'])"
    $Manifest += "Submodule vendor/semver: $($ExpectedSubmodules['vendor/semver'])"
    $Manifest += "Submodule vendor/nameof: $($ExpectedSubmodules['vendor/nameof'])"
    $Manifest | Set-Content -LiteralPath (Join-Path $ArtifactRoot "BUILD_MANIFEST.txt") -Encoding utf8

    @(
        "설치할 파일: ArchiveXL-1.27.1-PR22-NDEBUG-Test.zip"
        ""
        "1. MO2에서 기존 ArchiveXL을 비활성화합니다."
        "2. 위 ZIP을 별도 모드로 설치하고 활성화합니다."
        "3. control-DO-NOT-INSTALL 폴더의 DLL은 설치하지 마십시오."
        "4. releasedbg-diagnostic-pair는 함수명 있는 크래시 덤프가 필요할 때만 DLL과 PDB를 한 쌍으로 사용합니다. 메인 Release ZIP과 PDB가 서로 일치하는 것은 아닙니다."
        "5. 원래 ArchiveXL로 돌아가려면 시험 모드를 비활성화하고 기존 ArchiveXL을 다시 활성화합니다."
        ""
        "이 빌드는 55f48569(실제 1.27.1 소스)에 PR #22의 +5/-1 변경만 적용했습니다."
        "Release DLL은 공식 배포 동작과 맞추기 위해 NDEBUG를 명시하며, _wassert import가 남으면 검증에서 실패합니다."
        "GitHub Actions의 PASS는 정적 검증 통과를 뜻하며 게임 내 안정성을 보증하지 않습니다."
    ) | Set-Content -LiteralPath (Join-Path $ArtifactRoot "INSTALL-KO.txt") -Encoding utf8

    Stop-Transcript | Out-Null
    $TranscriptActive = $false

    $HashLines = foreach ($File in Get-ChildItem -LiteralPath $ArtifactRoot -File -Recurse |
        Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
        Sort-Object FullName) {
        $RelativePath = [IO.Path]::GetRelativePath($ArtifactRoot, $File.FullName).Replace("\", "/")
        "{0}  {1}" -f (Get-Sha256 -Path $File.FullName), $RelativePath
    }
    $HashLines | Set-Content -LiteralPath (Join-Path $ArtifactRoot "SHA256SUMS.txt") -Encoding ascii

    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            "## ArchiveXL 1.27.1 + PR #22 build"
            ""
            "- Verification: **PASS**"
            "- Base commit: ``$UpstreamCommit``"
            "- Patch provenance: ``$PrCommit``"
            "- Package SHA-256: ``$PackageSha256``"
            "- Install: ``ArchiveXL-1.27.1-PR22-NDEBUG-Test.zip``"
            ""
            "> This run compiled and statically verified the package; it did not perform an in-game test."
        ) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }

    Write-Host "Build and verification completed successfully."
    Write-Host "Package: $OutputPackage"
    Write-Host "Package SHA-256: $PackageSha256"
}
catch {
    foreach ($UnsafeOutput in @(
        $OutputPackage,
        (Join-Path $ArtifactRoot "patched-release"),
        (Join-Path $ArtifactRoot "releasedbg-diagnostic-pair"),
        (Join-Path $ArtifactRoot "control-DO-NOT-INSTALL")
    )) {
        if (Test-Path -LiteralPath $UnsafeOutput) {
            Remove-Item -LiteralPath $UnsafeOutput -Recurse -Force
        }
    }

    @(
        "BUILD FAILED - DO NOT INSTALL ANY OUTPUT FROM THIS RUN"
        ""
        "Error: $($_.Exception.Message)"
        "See the logs directory and the failed GitHub Actions step for details."
    ) | Set-Content -LiteralPath (Join-Path $ArtifactRoot "BUILD_FAILED_DO_NOT_INSTALL.txt") -Encoding utf8

    throw
}
finally {
    if ($TranscriptActive) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning "Transcript was not active: $($_.Exception.Message)"
        }
    }
}
