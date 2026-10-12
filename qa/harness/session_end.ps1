# SESSION END: let the QA account's queued writes reach its cloud copy (so a
# later session can reuse its data), then quit the QA instance, sign it out and
# wipe its local state, so nothing of the QA account is left behind.
#
# Dev profile 'qa' by default, like session_start.ps1; -Profile default ends a
# session run in the normal instance.
param([int]$DrainTimeoutSec = 120, [string]$Profile = 'qa')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'instance.ps1')
$inst = Get-QaInstance $Profile
$Profile = $inst.Arg
$db = Join-Path $inst.DataDir 'voyager.sqlite'
# QA data may be wiped without reset.ps1's sync gate, but only once the running
# app is confirmed signed into a QA account. Anything else goes through it.
# The account can only be read from a running app, so one that crashed or was
# closed is relaunched first (the persisted sign-in survives). If that fails,
# the gate decides, and refuses without a sync check report.
$qaAccount = $false
if ((Test-Path -LiteralPath $db) -and -not (Get-QaProcess $inst)) {
  "Voyager ($($inst.Label)) is not running; relaunching it to confirm which account this data belongs to"
  try { & (Join-Path $here 'launch.ps1') -Profile $Profile } catch { "relaunch failed: $_" }
}
if (Get-QaProcess $inst) {
  # A just-launched app may not have restored its sign-in yet; exit 3 (a real
  # account) is final.
  for ($i = 0; $i -lt 10; $i++) {
    & (Join-Path $here 'guard.ps1') -Profile $Profile
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) { break }
    Start-Sleep -Seconds 3
  }
  $qaAccount = $LASTEXITCODE -eq 0
}
if ((Get-QaProcess $inst) -and (Test-Path -LiteralPath $db)) {
  $deadline = (Get-Date).AddSeconds($DrainTimeoutSec)
  do {
    $n = python -c "import sqlite3,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); print(c.execute('select count(*) from pending_uploads_table').fetchone()[0])" $db
    if ($n -eq '0') { break }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  "outbox rows left before quitting: $n"
}
& (Join-Path $here 'reset.ps1') -Force:$qaAccount -Profile $Profile
& (Join-Path $here 'whoami.ps1') -Profile $Profile
