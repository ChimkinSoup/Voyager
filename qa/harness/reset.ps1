# BASELINE RESET: quit Voyager, sign out of whatever account is persisted,
# and wipe every piece of local app state. The next launch shows the login
# page on an empty database; sign up/in a voyager-qa-* account from there
# (see qa/PROGRESS.md "Session start").
#
# Wiped:
#   %APPDATA%\Voyager\voyager            SQLite DB, media, drafts, prefs, auto-backups, session checkpoints
#   %LOCALAPPDATA%\firestore\[DEFAULT]\voyager-db9de   Firestore SDK offline cache
#   Credential Manager voyager-db9de.firebase.auth/[DEFAULT][n]   the persisted sign-in
# Not touched: the Documents logs (voyager_errors.log, perf_stall.log, ...),
# the HKCU Run "Voyager" entry, and anything in the cloud.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here 'stop.ps1') | Out-Null

foreach ($i in 0..9) {
  $t = "voyager-db9de.firebase.auth/[DEFAULT][$i]"
  cmdkey /delete:$t 2>&1 | Out-Null
}
$left = cmdkey /list | Select-String 'voyager-db9de\.firebase\.auth'
if ($left) { throw "sign-in credentials still present: $left" }

$data = Join-Path $env:APPDATA 'Voyager\voyager'
$fs = Join-Path $env:LOCALAPPDATA 'firestore\[DEFAULT]\voyager-db9de'
if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
if (Test-Path -LiteralPath $fs) { Remove-Item -LiteralPath $fs -Recurse -Force }
if ((Test-Path -LiteralPath $data) -or (Test-Path -LiteralPath $fs)) { throw 'local data still present' }
'reset: app stopped, signed out, local data wiped'
