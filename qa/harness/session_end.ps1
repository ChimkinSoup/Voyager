# SESSION END: let the QA account's queued writes reach its cloud copy (so a
# later session can reuse its data), then quit Voyager, sign out and wipe all
# local state, so Juno's next sign-in can't merge QA rows into the real account.
param([int]$DrainTimeoutSec = 120)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$db = Join-Path $env:APPDATA 'Voyager\voyager\voyager.sqlite'
if ((Get-Process voyager -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $db)) {
  $deadline = (Get-Date).AddSeconds($DrainTimeoutSec)
  do {
    $n = python -c "import sqlite3,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); print(c.execute('select count(*) from pending_uploads_table').fetchone()[0])" $db
    if ($n -eq '0') { break }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  "outbox rows left before quitting: $n"
}
& (Join-Path $here 'reset.ps1')
& (Join-Path $here 'whoami.ps1')
