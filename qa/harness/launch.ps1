# Launches Voyager as a debug `flutter run -d windows` in the background,
# logging to qa/logs/run-<timestamp>.log, and waits until the Dart VM service
# is up (its ws:// URI goes to qa/logs/vm_uri.txt for vm.dart, its PID to
# qa/logs/pid.txt for voy.ps1).
# The first build after a code change takes a few minutes.
# The Geoapify map key is read from <repo>\dart_defines.json (git-ignored,
# outside qa/) and passed as a --dart-define; it is never written to qa/.
# -NoMapKey launches without it (Phase 19B "no key" checks).
# Sets VOYAGER_QA_PARKED: the window starts off-screen and never activates, so
# it doesn't cover Juno's windows; voy.ps1's `park` sizes it before any input.
#
# -Profile <name> (else $env:VOYAGER_QA_PROFILE) launches a dev profile beside
# the normal instance (DEV_PROFILE_HLD.md): the already-built debug exe, run
# directly with VOYAGER_PROFILE set and the VM service on a fixed port, then a
# `flutter attach` to it for expression evaluation. Files get the name:
# run-<name>-*.exe.log (the app's own output: debugPrint, evalc's SEED-OK),
# run-<name>-*.log (attach), vm_uri_<name>.txt, pid_<name>.txt.
# -Build builds that exe first (needs every debug voyager.exe stopped: the
# build replaces the exe they run from). -ExePath runs a profile from another
# debug build instead (gaia.ps1 passes it through).
param([int]$TimeoutSec = 900, [switch]$NoMapKey, [string]$Profile, [switch]$Build, [string]$ExePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'instance.ps1')
$inst = Get-QaInstance $Profile
$qa = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $qa
$logs = Join-Path $qa 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
if (Get-QaProcess $inst) { throw "Voyager ($($inst.Label)) is already running; run qa/harness/stop.ps1 first" }
Remove-Item -LiteralPath $inst.VmUriFile, $inst.PidFile -ErrorAction SilentlyContinue
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = if ($inst.Profile) { "$($inst.Profile)-$stamp" } else { $stamp }
$log = Join-Path $logs "run-$tag.log"
$err = Join-Path $logs "run-$tag.err.log"
$defines = ''
$definesFile = Join-Path $repo 'dart_defines.json'
if (-not $NoMapKey -and (Test-Path -LiteralPath $definesFile)) {
  $mapKey = (Get-Content -Raw -LiteralPath $definesFile | ConvertFrom-Json).GEOAPIFY_API_KEY
  if ($mapKey -match '^[A-Za-z0-9]+$') { $defines = " --dart-define=GEOAPIFY_API_KEY=$mapKey" }
}

$exe = Join-Path $repo 'build\windows\x64\runner\Debug\voyager.exe'
if ($ExePath) {
  if (-not $inst.Profile -or $Build) { throw '-ExePath is for a profile launch of an existing build' }
  $exe = (Resolve-Path -LiteralPath $ExePath).Path
}
# Both `flutter run` and -Build rebuild the exe every debug instance runs
# from, which fails (or swaps files under a live app) while one is running.
if (-not $inst.Profile -or $Build) {
  $running = @(Get-Process voyager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
  if ($running) { throw "a debug voyager.exe is running from $exe (PID $($running.Id -join ', ')), and this launch would rebuild it; stop it first (stop.ps1 -Profile <name>)" }
}

if (-not $inst.Profile) {
  $run = "flutter run -d windows --debug$defines"
  if ($defines) { 'map key: passed' } else { 'map key: NOT passed' }
  # The app inherits it through flutter run (see the profile launch below).
  $savedParked = $env:VOYAGER_QA_PARKED
  $env:VOYAGER_QA_PARKED = '1'
  try {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $run `
      -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  } finally { $env:VOYAGER_QA_PARKED = $savedParked }
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $text = Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue
    if ($text -match 'Dart VM Service on Windows is available at: (http://127\.0\.0\.1:\d+/[^/\s]+/)') {
      $ws = $Matches[1] -replace '^http', 'ws'
      Set-Content -LiteralPath $inst.VmUriFile -Value "${ws}ws" -Encoding ascii
      $appPid = @(& (Join-Path $PSScriptRoot 'vm.ps1') -Profile default pid)[-1]
      if ($LASTEXITCODE -ne 0 -or $appPid -notmatch '^\d+$') { throw "launched, but could not read the app's PID: $appPid" }
      Save-QaPid $inst.PidFile (Get-Process -Id ([int]$appPid))
      "launched; log: $log"
      "vm: ${ws}ws"
      "pid: $appPid"
      exit 0
    }
    if ($text -match 'Error: |Build process failed|Exception: ') { "BUILD/RUN FAILED - see $log and $err"; exit 1 }
  }
  "timed out after $TimeoutSec s; see $log"
  exit 1
}

if ($Build) {
  if ($defines) { 'map key: passed' } else { 'map key: NOT passed' }
  Push-Location $repo
  try {
    $out = cmd /c "flutter build windows --debug$defines 2>&1"
    if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 20; throw 'flutter build windows --debug failed' }
  } finally { Pop-Location }
} elseif (-not (Test-Path -LiteralPath $exe)) {
  throw "no debug build at $exe; pass -Build"
} else {
  'using the existing debug build (its map key is whatever it was built with); -Build rebuilds it'
}

$exeLog = Join-Path $logs "run-$tag.exe.log"
$exeErr = Join-Path $logs "run-$tag.exe.err.log"
# A free port, fixed before launch, so the VM service URI is known without a
# `flutter run` to print it. Auth codes off, so the URI is just the port.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$vars = @{
  VOYAGER_PROFILE         = $inst.Profile
  # Window starts off-screen and never activates (windows/runner/utils.h).
  VOYAGER_QA_PARKED       = '1'
  FLUTTER_ENGINE_SWITCHES = '2'
  FLUTTER_ENGINE_SWITCH_1 = "vm-service-port=$port"
  FLUTTER_ENGINE_SWITCH_2 = 'disable-service-auth-codes'
}
# Start-Process in Windows PowerShell 5.1 has no -Environment: the child
# inherits this process's, which is put back straight after.
$saved = @{}
foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
try {
  $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru `
    -RedirectStandardOutput $exeLog -RedirectStandardError $exeErr
} finally {
  foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}
Save-QaPid $inst.PidFile $proc
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$up = $false
while (-not $up -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 1
  if ($proc.HasExited) { Remove-Item -LiteralPath $inst.PidFile -ErrorAction SilentlyContinue; "EXITED with code $($proc.ExitCode) - see $exeLog and $exeErr"; exit 1 }
  $client = [Net.Sockets.TcpClient]::new()
  try { $client.Connect('127.0.0.1', $port); $up = $true } catch { } finally { $client.Dispose() }
}
if (-not $up) { "VM service not up on port $port after $TimeoutSec s; see $exeLog"; exit 1 }

# The exe alone can't evaluate expressions: the compiler for that lives in
# flutter_tools, which `flutter attach` brings, as `flutter run` does for the
# normal instance. vm.dart then talks to the URI attach prints.
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "flutter attach -d windows --debug-url http://127.0.0.1:$port/$defines" `
  -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  if ($proc.HasExited) { "EXITED with code $($proc.ExitCode) - see $exeLog and $log"; exit 1 }
  $text = Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue
  if ($text -match 'Dart VM Service on Windows is available at: (http://127\.0\.0\.1:\d+/[^/\s]+/)') {
    $ws = $Matches[1] -replace '^http', 'ws'
    Set-Content -LiteralPath $inst.VmUriFile -Value "${ws}ws" -Encoding ascii
    "launched $($inst.Label); log: $log"
    "vm: ${ws}ws"
    "pid: $($proc.Id)"
    exit 0
  }
  if ($text -match 'Error: |Exception: ') { "ATTACH FAILED - see $log and $err"; exit 1 }
}
"timed out after $TimeoutSec s; see $log"
exit 1
