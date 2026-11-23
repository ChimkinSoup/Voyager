# Phone SESSION END (MOBILE_TEST_PLAN.md "SESSION WORKFLOW" step 6):
# guard → wait (≤ -DrainSec) for the outbox to drain → sign out in the app
# (the Settings tile's own signOutPausingSync) → pm clear (uninstall if
# OxygenOS refuses it) → guard says signed out / not installed → stop the flutter run and logcat → Juno's own settings back
# (DND and stay-awake as recorded at session start). Prints SIGNED-OUT.
# Refuses (nothing wiped) if the outbox won't drain.
param([int]$DrainSec = 120)
$ErrorActionPreference = 'Stop'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$h = $PSScriptRoot
$env:ANDROID_SERIAL = (Get-Content -LiteralPath (Join-Path $h 'phone_serial.txt') -TotalCount 1).Trim()
$logs = Join-Path (Split-Path -Parent $h) 'logs'

# Stops a process and everything it started (flutter run → dart → adb forward).
function Stop-Tree([int]$Id) {
  Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" | ForEach-Object { Stop-Tree $_.ProcessId }
  Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}
function Get-Outbox {
  $uri = & (Join-Path $h 'phone_db.ps1')
  [int]"$(python -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1],uri=True).execute('select count(*) from pending_uploads_table').fetchone()[0])" $uri)".Trim()
}

$state = & (Join-Path $h 'phone.ps1') check   # throws for a non-qa account
"guard: $state"
& $adb shell 'run-as com.example.voyager test -f files/voyager.sqlite'
if ($LASTEXITCODE -eq 0) {
  $deadline = (Get-Date).AddSeconds($DrainSec)
  while (($n = Get-Outbox) -gt 0) {
    if ((Get-Date) -gt $deadline) { throw "outbox still holds $n rows after $DrainSec s: not wiping. Bring the phone online and run this again." }
    "outbox: $n, waiting"
    Start-Sleep 5
  }
  'outbox: 0'
}
$uriFile = Join-Path $logs 'vm_uri_phone.txt'
if ($state -ne 'ok: signed out' -and (Test-Path -LiteralPath $uriFile)) {
  & (Join-Path $h 'evalc.ps1') -Profile phone -Lib features/settings/account_section.dart -Tag phone-signout -BodyFile (Join-Path (Split-Path -Parent $h) 'steps\phone-signout.dart.txt')
  Start-Sleep 3
} elseif ($state -ne 'ok: signed out') {
  'no VM service (phone_launch.ps1 not running): skipping the in-app sign-out; pm clear signs it out'
}
& $adb shell 'pm clear com.example.voyager'
# OxygenOS refuses pm clear (no CLEAR_APP_USER_DATA) while its permission
# monitoring is on; uninstalling wipes the same data (Juno: fine).
if ($LASTEXITCODE -ne 0) { 'pm clear refused: uninstalling instead'; & $adb shell 'pm uninstall com.example.voyager' }
$after = & (Join-Path $h 'phone.ps1') check
if ($after -notin 'ok: signed out', 'ok: not installed') { throw "after the wipe the guard says '$after'" }

foreach ($f in 'phone_run_pid.txt', 'phone_logcat_pid.txt') {
  $p = Join-Path $logs $f
  if (Test-Path -LiteralPath $p) { Stop-Tree ([int](Get-Content -LiteralPath $p)); Remove-Item -LiteralPath $p }
}
Remove-Item -LiteralPath $uriFile -ErrorAction SilentlyContinue
& (Join-Path $h 'phone_standard.ps1') -Juno
'SIGNED-OUT'
