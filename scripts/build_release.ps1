# Release build with the version, commit and date baked in (Settings -> About).
#   .\scripts\build_release.ps1
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
$sha = (git rev-parse --short HEAD).Trim()
# Uncommitted changes mean the build doesn't match the commit.
if (git status --porcelain) { $sha = "$sha-dirty" }
$date = Get-Date -Format "yyyy-MM-dd"

Write-Host "Building $version · $sha · $date"
flutter build windows --release `
    --dart-define=BUILD_VERSION=$version `
    --dart-define=BUILD_SHA=$sha `
    --dart-define=BUILD_DATE=$date
