# Runs Voyager on Juno's phone (serial in phone_serial.txt) as a debug `flutter run` in the
# background (it builds, installs with -r and starts the app), logging to
# qa/logs/run-phone-<timestamp>.log, and waits for the Dart VM service. Its ws
# URI goes to qa/logs/vm_uri_phone.txt, so `vm.ps1 -Profile phone` and
# `evalc.ps1 -Profile phone` reach the phone (vm.ps1 runs phone.ps1's guard
# first). The flutter tool's PID goes to qa/logs/phone_run_pid.txt for
# phone_session_end.ps1.
# An install keeps the old sign-in, so the guard runs once the app is up.
# A warm build takes ~1.5 minutes. The Geoapify map key is passed as on
# desktop (launch.ps1); -NoMapKey leaves it out.
# -Attach reconnects to the app already running on the phone (after process
# death, a force-stop or a reboot, which drop the VM service): `flutter
# attach`, no build or install. Start the app first (phone.ps1 launch).
param([int]$TimeoutSec = 900, [switch]$NoMapKey, [switch]$Attach)
$ErrorActionPreference = 'Stop'
$Device = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phone_serial.txt') -TotalCount 1).Trim()
$env:ANDROID_SERIAL = $Device
$qa = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $qa
$logs = Join-Path $qa 'logs'
$uriFile = Join-Path $logs 'vm_uri_phone.txt'
$pidFile = Join-Path $logs 'phone_run_pid.txt'
if ((Test-Path -LiteralPath $pidFile) -and (Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue)) {
  throw "a phone flutter run is already going (PID $(Get-Content -LiteralPath $pidFile)); phone_session_end.ps1 stops it"
}
Remove-Item -LiteralPath $uriFile, $pidFile -ErrorAction SilentlyContinue
$log = Join-Path $logs "run-phone-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$err = $log -replace '\.log$', '.err.log'
$defines = ''
$definesFile = Join-Path $repo 'dart_defines.json'
if (-not $NoMapKey -and (Test-Path -LiteralPath $definesFile)) {
  $mapKey = (Get-Content -Raw -LiteralPath $definesFile | ConvertFrom-Json).GEOAPIFY_API_KEY
  if ($mapKey -match '^[A-Za-z0-9]+$') { $defines = " --dart-define=GEOAPIFY_API_KEY=$mapKey" }
}
if ($defines) { 'map key: passed' } else { 'map key: NOT passed' }
$verb = if ($Attach) { 'attach' } else { 'run' }
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "flutter $verb -d $Device --debug$defines" `
  -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
Set-Content -LiteralPath $pidFile -Value $proc.Id -Encoding ascii
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $text = Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue
  if ($text -match 'Dart VM Service on .+ is available at: (http://127\.0\.0\.1:\d+/[^/\s]+/)') {
    Set-Content -LiteralPath $uriFile -Value "$($Matches[1] -replace '^http', 'ws')ws" -Encoding ascii
    "launched on $Device; log: $log"
    "vm: $(Get-Content -LiteralPath $uriFile)"
    & (Join-Path $PSScriptRoot 'phone.ps1') check
    exit 0
  }
  if ($proc.HasExited -or $text -match 'Error: |Build process failed|Exception: ') { "BUILD/RUN FAILED - see $log and $err"; exit 1 }
}
"timed out after $TimeoutSec s; see $log"
exit 1
