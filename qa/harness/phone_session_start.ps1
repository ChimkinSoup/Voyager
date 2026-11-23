# Phone SESSION START (MOBILE_TEST_PLAN.md "SESSION WORKFLOW" step 3):
# wait for the phone (USB) → standard configuration (records Juno's DND and
# stay-awake, then DND on, screen kept on) → logcat to
# qa/logs/logcat-<timestamp>.txt → guard → phone_launch.ps1 (build, install,
# VM service) → sign in (phone_login.ps1) unless the app already holds this
# account → guard → print the build and the app settings to check.
#   phone_session_start.ps1 -Email voyager-qa-NNN@example.com [-SignUp]
# Refuses if the app holds another account: run phone_session_end.ps1 first.
param([Parameter(Mandatory)][string]$Email, [switch]$SignUp, [string]$Password = 'qavoyager2026')
$ErrorActionPreference = 'Stop'
if ($Email -cnotmatch '^voyager-qa-\d+@example\.com$') { throw "refusing: $Email is not a voyager-qa-NNN@example.com account" }
$sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$h = $PSScriptRoot
$qa = Split-Path -Parent $h
$repo = Split-Path -Parent $qa
$logs = Join-Path $qa 'logs'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$serial = (Get-Content -LiteralPath (Join-Path $h 'phone_serial.txt') -TotalCount 1).Trim()
$env:ANDROID_SERIAL = $serial
$t = Get-Date
while (-not ("$(& $adb devices)" -match "$serial\s+device")) {
  if ("$(& $adb devices)" -match "$serial\s+unauthorized") { throw "the phone shows as unauthorized: ask Juno to accept the USB-debugging prompt" }
  if (((Get-Date) - $t).TotalSeconds -gt 30) { throw "phone $serial not in adb devices: ask Juno to check the cable and the USB mode" }
  Start-Sleep 2
}
& (Join-Path $h 'phone_standard.ps1')

& $adb logcat -c
$logcat = Join-Path $logs "logcat-$stamp.txt"
# Errors from every tag (FATAL EXCEPTION, ANR in …) and all flutter lines:
# the full log on Juno's phone ran ~2 MB a minute, nearly all other apps'.
# FlutterErrors aren't in logcat at all: they're in the flutter run log and
# app_flutter/voyager_errors.log.
$lc = Start-Process -FilePath $adb -ArgumentList 'logcat', '-v', 'time', '*:E', 'flutter:V' -WindowStyle Hidden -PassThru -RedirectStandardOutput $logcat -RedirectStandardError "$logcat.err"
Set-Content -LiteralPath (Join-Path $logs 'phone_logcat_pid.txt') -Value $lc.Id -Encoding ascii
"logcat: $logcat"

"guard: $(& (Join-Path $h 'phone.ps1') check)"
& (Join-Path $h 'phone_launch.ps1')
if ($LASTEXITCODE -ne 0) { throw 'phone_launch.ps1 failed' }
$who = "$(& (Join-Path $h 'vm.ps1') -Profile phone whoami)".Trim()
if ($who -eq 'SIGNED-OUT') {
  if ($SignUp) { & (Join-Path $h 'phone_login.ps1') -Email $Email -Password $Password -SignUp }
  else { & (Join-Path $h 'phone_login.ps1') -Email $Email -Password $Password }
} elseif ($who -ne $Email) {
  throw "the app is signed in as $who, not ${Email}: run phone_session_end.ps1 first"
} else { "already signed in as $Email" }
"guard: $(& (Join-Path $h 'phone.ps1') check)"

Push-Location $repo
try { "build: $(git log -1 --oneline)"; 'lib changes:'; git status --short lib/ } finally { Pop-Location }
Start-Sleep 5   # the startup pull writes settings_table
$uri = & (Join-Path $h 'phone_db.ps1')
python -c "import sqlite3,sys; print('settings (want dark,1,0,15.0):', sqlite3.connect(sys.argv[1],uri=True).execute('select theme_mode, geometric_wave_scatter_mode, geometric_wave_enabled, geometric_texture_scale from settings_table where id=1').fetchone())" $uri
"error log: app_flutter/voyager_errors.log is $("$(& $adb shell 'run-as com.example.voyager sh -c ''wc -c < app_flutter/voyager_errors.log''')".Trim()) bytes (read only what this session appends)"
