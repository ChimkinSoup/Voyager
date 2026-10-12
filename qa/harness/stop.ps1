# Fully quits Voyager: every voyager.exe (debug run, dev profile or the
# installed release) plus the `flutter run` / `flutter attach` tool processes
# that launch.ps1 started. Leaves other Dart processes (e.g. the Dart language
# server) alone.
#
# -Profile <name> (else $env:VOYAGER_QA_PROFILE) stops only that dev profile's
# voyager.exe (by the PID launch.ps1 recorded) and its `flutter attach`, and
# leaves every other instance running. -Profile default stops only the normal
# instance (and its `flutter run`), leaving the profiles.
param([string]$Profile)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'instance.ps1')
$logs = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
$explicitDefault = $Profile -eq 'default'
$Profile = Resolve-QaProfile $Profile
if ($Profile -or $explicitDefault) {
  $inst = Get-QaInstance $(if ($Profile) { $Profile } else { 'default' })
  $procs = @(Get-QaProcess $inst)
  # The instance's tool process: a profile's `flutter attach` (launch.ps1),
  # found by the VM service port it was given, or the normal instance's
  # `flutter run`. Either would also quit by itself once the app is gone.
  $ports = @($procs | ForEach-Object { Get-NetTCPConnection -OwningProcess $_.Id -State Listen -ErrorAction SilentlyContinue } | ForEach-Object { $_.LocalPort })
  Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" |
    Where-Object {
      $_.CommandLine -match 'flutter_tools' -and $(if ($Profile) {
          $_.CommandLine -match '--debug-url http://127\.0\.0\.1:(\d+)/' -and $ports -contains [int]$Matches[1]
        } else { $_.CommandLine -match '\srun\s' })
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($proc in $procs) {
    $proc | Stop-Process -Force
    # Gone from the process list, not just exited: until then it can still hold
    # the database open, and reset.ps1 deletes it straight after.
    for ($i = 0; $i -lt 50 -and (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { throw "voyager.exe ($($inst.Label)) is still running" }
  }
  Remove-Item -LiteralPath $inst.VmUriFile, $inst.PidFile -ErrorAction SilentlyContinue
  "stopped $($inst.Label)"
  exit 0
}
Get-Process voyager -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" |
  Where-Object { $_.CommandLine -match 'flutter_tools' -and $_.CommandLine -match '\s(run|attach)\s' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
for ($i = 0; $i -lt 50 -and (Get-Process voyager -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
if (Get-Process voyager -ErrorAction SilentlyContinue) { throw 'voyager.exe is still running' }
Get-ChildItem -LiteralPath $logs -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^(vm_uri|pid)(_[a-z0-9]+)?\.txt$' } |
  Remove-Item -ErrorAction SilentlyContinue
'stopped'
