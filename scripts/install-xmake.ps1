[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$XmakeVersion = "3.0.9"
$ExpectedSha256 = "0f2c57a29f358e4f9f059cd823f40c3213750dcb13d5b6e9f6e5b29910992d65"
$DownloadUrl = "https://github.com/xmake-io/xmake/releases/download/v$XmakeVersion/xmake-v$XmakeVersion.win64.zip"

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ToolsRoot = Join-Path $RepoRoot ".tools"
$ArchivePath = Join-Path $ToolsRoot "xmake-v$XmakeVersion.win64.zip"
$ExtractPath = Join-Path $ToolsRoot "xmake-$XmakeVersion"

New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

Write-Host "Downloading Xmake $XmakeVersion from the official release..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath

$ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
if ($ActualSha256 -ne $ExpectedSha256) {
    throw "Xmake archive SHA-256 mismatch. Expected $ExpectedSha256, got $ActualSha256."
}

if (Test-Path -LiteralPath $ExtractPath) {
    Remove-Item -LiteralPath $ExtractPath -Recurse -Force
}

Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractPath
$XmakeExe = Get-ChildItem -LiteralPath $ExtractPath -Filter "xmake.exe" -File -Recurse |
    Select-Object -First 1

if (-not $XmakeExe) {
    throw "xmake.exe was not found in the verified archive."
}

$XmakeBin = $XmakeExe.Directory.FullName
$env:PATH = "$XmakeBin;$env:PATH"

if ($env:GITHUB_PATH) {
    $XmakeBin | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
}

& $XmakeExe.FullName --version
if ($LASTEXITCODE -ne 0) {
    throw "xmake --version failed with exit code $LASTEXITCODE."
}

Write-Host "Verified Xmake SHA-256: $ActualSha256"
Write-Host "Xmake bin directory: $XmakeBin"
