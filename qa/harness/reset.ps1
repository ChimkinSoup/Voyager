# BASELINE RESET: quit Voyager, sign out of whatever account is persisted,
# and wipe every piece of local app state. The next launch shows the login
# page on an empty database; sign up/in a voyager-qa-* account from there
# (see qa/PROGRESS.md "Session start").
#
# Wiped (normal instance; -Profile <name> wipes that dev profile's instead,
# see instance.ps1):
#   %APPDATA%\Voyager\voyager            SQLite DB, media, drafts, prefs, auto-backups, session checkpoints
#                                        (profile: %APPDATA%\Voyager\voyager-profile-<name>, logs included)
#   %LOCALAPPDATA%\firestore\[DEFAULT]\voyager-db9de   Firestore SDK offline cache
#                                        (profile: firestore\voyager-<name>\voyager-db9de)
#   Credential Manager voyager-db9de.firebase.auth/[DEFAULT][n]   the persisted sign-in
#                                        (profile: .../voyager-<name>[n])
# Not touched: the Documents logs (voyager_errors.log, perf_stall.log, ...),
# the HKCU Run "Voyager" entry, anything in the cloud, and other instances'
# data. It stops only the instance it resets (`stop.ps1 -Profile`).
#
# Refuses to wipe a database that sync_gate.ps1 can't clear, before signing
# out or deleting anything. -Force skips the gate; session_end.ps1 passes it
# only once guard.ps1 has confirmed a QA account.
param([switch]$Force, [string]$Profile)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'instance.ps1')
$inst = Get-QaInstance $Profile
$data = $inst.DataDir
if (-not $Force) {
  # Gated before stop.ps1, whose force-kill would lose edits still in memory.
  # A running app can also write after the gate passes, so it must be closed
  # already, the way "Check, then quit" leaves it.
  if (Get-QaProcess $inst) {
    throw "reset: Voyager ($($inst.Label)) is running. In Voyager: Dev page -> 'Check, then quit (before a wipe)', then rerun."
  }
  & (Join-Path $here 'sync_gate.ps1') -DataDir $data
}
& (Join-Path $here 'stop.ps1') -Profile $inst.Arg | Out-Null

foreach ($i in 0..9) {
  $t = "$($inst.CredPrefix)[$i]"
  cmdkey /delete:$t 2>&1 | Out-Null
}
$left = cmdkey /list | Select-String -SimpleMatch "$($inst.CredPrefix)["
if ($left) { throw "sign-in credentials still present: $left" }

$fs = $inst.FirestoreDir
if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
if (Test-Path -LiteralPath $fs) { Remove-Item -LiteralPath $fs -Recurse -Force }
if ((Test-Path -LiteralPath $data) -or (Test-Path -LiteralPath $fs)) { throw 'local data still present' }
"reset ($($inst.Label)): app stopped, signed out, local data wiped"
