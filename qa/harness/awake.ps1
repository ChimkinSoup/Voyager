# Keep the screen usable for a live run without giving up Juno's OLED screen saver.
#
#   awake.ps1 on       (or voy.ps1 awake on) screen saver, display-off and sleep held off,
#                      brightness dimmed to 0. Already on: just resets the timer.
#   awake.ps1 off      restore now
#   awake.ps1 status
#
# A hidden holder process does the work and restores Juno's settings (screen saver
# state, brightness) once qa/logs/awake.json is 20 minutes old or deleted. Every
# voy.ps1 and vm.ps1 call touches that file, so active testing never times out.
# The screen saver is switched off for this logon only (never written to the
# registry), so a reboot or sign-out restores it even if the holder is killed.
param([Parameter(Position = 0)][string]$Cmd = 'status')
$ErrorActionPreference = 'Stop'
$state = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\awake.json'
$idleMinutes = 20

if (-not ('AwakeNative' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AwakeNative {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref bool pv, uint winIni);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint winIni);
    // SPI_GETSCREENSAVEACTIVE / SPI_SETSCREENSAVEACTIVE; winIni 0 = this logon only.
    public static bool ScreenSaverActive() { bool on = false; SystemParametersInfo(0x10, 0, ref on, 0); return on; }
    public static void SetScreenSaverActive(bool on) { SystemParametersInfo(0x11, on ? 1u : 0u, IntPtr.Zero, 0); }
}
'@
}

function Get-Brightness { [int](Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness).CurrentBrightness }
function Set-Brightness([int]$level) {
  Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods |
    Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]0; Brightness = [byte]$level } | Out-Null
}
# The holder rewrites the file once (ready): a read caught mid-write retries.
function Read-State {
  for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $state); $i++) {
    try { $s = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json; if ($s) { return $s } } catch {}
    Start-Sleep -Milliseconds 100
  }
}
function Test-Holder($s) { $s -and (Get-Process -Id $s.pid -ErrorAction SilentlyContinue) }
function Restore($s) {
  [AwakeNative]::SetScreenSaverActive([bool]$s.screenSaver)
  # Re-check once: a change still in flight can land after the first set.
  for ($i = 0; $i -lt 3 -and (Get-Brightness) -ne $s.brightness; $i++) { Set-Brightness $s.brightness; Start-Sleep -Seconds 1 }
}

switch ($Cmd) {
  'hold' {
    $s = [pscustomobject]@{ pid = $PID; brightness = (Get-Brightness); screenSaver = [AwakeNative]::ScreenSaverActive(); ready = $false }
    $s | ConvertTo-Json | Set-Content -LiteralPath $state -Encoding UTF8
    try {
      [AwakeNative]::SetScreenSaverActive($false)
      Get-Process | Where-Object { $_.Name -like 'scrnsave*' } | Stop-Process -Force -ErrorAction SilentlyContinue
      Set-Brightness 0
      # ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED, held while this process lives.
      [AwakeNative]::SetThreadExecutionState([uint32]'0x80000003') | Out-Null
      # 'on' waits for this, so an 'off' right after it can't race the dimming above.
      $s.ready = $true
      $s | ConvertTo-Json | Set-Content -LiteralPath $state -Encoding UTF8
      while ((Test-Path -LiteralPath $state) -and ((Get-Date) - (Get-Item -LiteralPath $state).LastWriteTime).TotalMinutes -lt $idleMinutes) {
        Start-Sleep -Seconds 5
      }
    } finally {
      Restore $s
      Remove-Item -LiteralPath $state -ErrorAction SilentlyContinue
    }
  }
  'on' {
    $old = Read-State
    if (Test-Holder $old) { (Get-Item -LiteralPath $state).LastWriteTime = Get-Date; 'awake: on (timer reset)'; break }
    # A holder that was killed left Juno's settings changed: put them back before reading them again.
    if ($old) { Restore $old; Remove-Item -LiteralPath $state }
    Start-Process powershell -WindowStyle Hidden -RedirectStandardError ($state -replace '\.json$', '-err.log') -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, 'hold'
    for ($i = 0; $i -lt 40 -and -not ((Read-State).ready -and (Test-Holder (Read-State))); $i++) { Start-Sleep -Milliseconds 250 }
    if ((Read-State).ready -and (Test-Holder (Read-State))) { "awake: on (restores $idleMinutes min after the last voy.ps1/vm.ps1 call, or on 'awake off')" } else { throw 'awake: holder did not start' }
  }
  'off' {
    $s = Read-State
    if (-not $s) { 'awake: already off'; break }
    Remove-Item -LiteralPath $state
    if (Test-Holder $s) { Wait-Process -Id $s.pid -Timeout 20 } else { Restore $s }
    "awake: off (screen saver $(if ($s.screenSaver) { 'on' } else { 'off' }), brightness $($s.brightness))"
  }
  'status' {
    $s = Read-State
    if (Test-Holder $s) {
      $left = $idleMinutes - ((Get-Date) - (Get-Item -LiteralPath $state).LastWriteTime).TotalMinutes
      'awake: on, {0:N1} min left' -f $left
    } else { 'awake: off' }
  }
  default { throw "usage: awake.ps1 on | off | status" }
}
