# Launches Voyager as a debug `flutter run -d windows` in the background,
# logging to qa/logs/run-<timestamp>.log, and waits until the Dart VM service
# is up (its ws:// URI goes to qa/logs/vm_uri.txt for vm.dart).
# The first build after a code change takes a few minutes.
param([int]$TimeoutSec = 900)
$ErrorActionPreference = 'Stop'
$qa = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repo = Split-Path -Parent $qa
$logs = Join-Path $qa 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
if (Get-Process voyager -ErrorAction SilentlyContinue) { throw 'Voyager is already running; run qa/harness/stop.ps1 first' }
Remove-Item (Join-Path $logs 'vm_uri.txt') -ErrorAction SilentlyContinue
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logs "run-$stamp.log"
$err = Join-Path $logs "run-$stamp.err.log"
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'flutter run -d windows --debug' `
  -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $text = Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue
  if ($text -match 'Dart VM Service on Windows is available at: (http://127\.0\.0\.1:\d+/[^/\s]+/)') {
    $ws = $Matches[1] -replace '^http', 'ws'
    Set-Content -LiteralPath (Join-Path $logs 'vm_uri.txt') -Value "${ws}ws" -Encoding ascii
    "launched; log: $log"
    "vm: ${ws}ws"
    exit 0
  }
  if ($text -match 'Error: |Build process failed|Exception: ') { "BUILD/RUN FAILED - see $log and $err"; exit 1 }
}
"timed out after $TimeoutSec s; see $log"
exit 1
