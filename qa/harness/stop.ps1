# Fully quits Voyager: every voyager.exe (debug run, dev profile or the
# installed release) plus the `flutter run` / `flutter attach` tool processes
# that launch.ps1 started, and waits for what each stopped voyager.exe started
# (Gaia's companion and its CLIs) to be gone too. Leaves other Dart processes
# (e.g. the Dart language server) alone.
#
# -Profile <name> (else $env:VOYAGER_QA_PROFILE) stops only that dev profile's
# voyager.exe (by the PID launch.ps1 recorded) and its `flutter attach`, and
# leaves every other instance running. -Profile default stops only the normal
# instance (and its `flutter run`), leaving the profiles.
param([string]$Profile)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'instance.ps1')
$logs = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'

# Everything started under $RootIds: Gaia's companion and the CLIs it runs. A
# child must have started after its parent, so a reused PID can't pull in an
# unrelated process.
function Get-ChildTree([int[]]$RootIds) {
  $all = @(Get-CimInstance Win32_Process)
  $started = @{}
  foreach ($p in $all) { $started[[int]$p.ProcessId] = $p.CreationDate }
  $ids = [System.Collections.Generic.List[int]]::new([int[]]$RootIds)
  for ($i = 0; $i -lt $ids.Count; $i++) {
    foreach ($p in $all) {
      if ($p.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$p.ProcessId) -and $p.CreationDate -ge $started[$ids[$i]]) {
        $ids.Add([int]$p.ProcessId)
      }
    }
  }
  @($ids | Select-Object -Skip $RootIds.Count | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
}

# The companion exits, killing its CLIs, once the main instance's pipe closes:
# a moment after the main instance. Until then the CLIs hold the profile's
# gaia\ws open, and reset.ps1 deletes it straight after.
function Stop-ChildTree($Procs) {
  for ($i = 0; $i -lt 50 -and @($Procs | Where-Object { -not $_.HasExited }).Count; $i++) { Start-Sleep -Milliseconds 100 }
  $Procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 50 -and @($Procs | Where-Object { -not $_.HasExited }).Count; $i++) { Start-Sleep -Milliseconds 100 }
  $left = @($Procs | Where-Object { -not $_.HasExited })
  if ($left) { throw "still running under voyager.exe: $(($left | ForEach-Object { "$($_.ProcessName) $($_.Id)" }) -join ', ')" }
}

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
  $children = if ($procs) { Get-ChildTree @($procs | ForEach-Object { $_.Id }) } else { @() }
  foreach ($proc in $procs) {
    $proc | Stop-Process -Force
    # Gone from the process list, not just exited: until then it can still hold
    # the database open, and reset.ps1 deletes it straight after.
    for ($i = 0; $i -lt 50 -and (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { throw "voyager.exe ($($inst.Label)) is still running" }
  }
  Stop-ChildTree $children
  Remove-Item -LiteralPath $inst.VmUriFile, $inst.PidFile -ErrorAction SilentlyContinue
  "stopped $($inst.Label)"
  exit 0
}
$voyagers = @(Get-Process voyager -ErrorAction SilentlyContinue)
$children = if ($voyagers) { Get-ChildTree @($voyagers | ForEach-Object { $_.Id }) } else { @() }
$voyagers | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" |
  Where-Object { $_.CommandLine -match 'flutter_tools' -and $_.CommandLine -match '\s(run|attach)\s' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
for ($i = 0; $i -lt 50 -and (Get-Process voyager -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
if (Get-Process voyager -ErrorAction SilentlyContinue) { throw 'voyager.exe is still running' }
Stop-ChildTree $children
Get-ChildItem -LiteralPath $logs -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^(vm_uri|pid)(_[a-z0-9]+)?\.txt$' } |
  Remove-Item -ErrorAction SilentlyContinue
'stopped'
