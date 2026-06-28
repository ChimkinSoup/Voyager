param(
    [switch]$LocalOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not $LocalOnly) {
    Write-Host @"
Purge out-of-sync journal entries
=================================

Recommended (Firestore + local, while Voyager is running and you are signed in):
  1. Open Voyager -> Developer tools
  2. Scroll to "Purge out-of-sync journal entries"
  3. Confirm the delete

Local-only (close Voyager first so voyager.sqlite is not locked):
  .\scripts\purge_out_of_sync_journal_entries.ps1 -LocalOnly

Entries targeted:
  - test
  - 4 untitled entries from the latest sync_compare.log run

"@
    exit 0
}

Write-Host "Purging local journal rows only (close Voyager first)..."
flutter test test/tool/purge_out_of_sync_journal_entries_test.dart
Write-Host ""
Write-Host "Done. Re-open Voyager and run a sync compare to verify."
Write-Host "For Firestore cleanup, use Developer tools -> Purge out-of-sync journal entries."
