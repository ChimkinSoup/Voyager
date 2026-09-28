# Refuses (throws) unless the local data in -DataDir is safe to wipe: the app's
# own whole-account check (Dev page -> "Check, then quit (before a wipe)")
# found nothing the cloud lacks, and the database hasn't been written since.
#
# The outbox can't vouch for this on its own: a write lost without a trace, or
# a migration that never uploaded, leaves it empty while the cloud is behind.
# That is how the 2026-09-27 wipe lost changes from 2026-09-15/16.
param([Parameter(Mandatory)][string]$DataDir)
$ErrorActionPreference = 'Stop'
$db = Join-Path $DataDir 'voyager.sqlite'
if (-not (Test-Path -LiteralPath $db)) { 'sync gate: no database, nothing to protect'; exit 0 }

$howTo = "In Voyager: Dev page -> 'Check, then quit (before a wipe)', then rerun."
$report = Join-Path $DataDir 'sync_check.json'
if (-not (Test-Path -LiteralPath $report)) { throw "sync gate: no sync check has been run. $howTo" }
$check = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
if (-not $check.safeToWipe) {
  $unreadable = @($check.unreadable.PSObject.Properties).Count
  throw "sync gate: the check at $($check.checkedAt) found $($check.unsynced) record(s) not in the cloud and $unreadable collection(s) it could not read. Details: $report"
}

# A leftover journal means a write was cut off mid-commit: the header can't be
# trusted until the app has opened the database again.
if (Test-Path -LiteralPath "$db-journal") { throw "sync gate: the database has an unfinished write. $howTo" }

# SQLite's file change counter (header bytes 24-27, big-endian) moves on every
# committed write. The app stamps it into the report after checking.
$stream = [IO.File]::Open($db, 'Open', 'Read', 'ReadWrite')
try {
  $null = $stream.Seek(24, 'Begin')
  $b = New-Object byte[] 4
  $null = $stream.Read($b, 0, 4)
} finally { $stream.Dispose() }
$counter = ([long]$b[0] -shl 24) -bor ([long]$b[1] -shl 16) -bor ([long]$b[2] -shl 8) -bor [long]$b[3]
if ($counter -ne [long]$check.dbChangeCounter) {
  throw "sync gate: the database changed after the check at $($check.checkedAt). $howTo"
}
"sync gate: OK, nothing unsynced as of $($check.checkedAt)"
