# Juno's phone settings around a test session (MOBILE_TEST_PLAN.md DEVICE,
# PROGRESS.md §1b). Prints the result.
#   phone_standard.ps1         the plan's standard test configuration, undoing
#                              any toolbox change a dead session left; records
#                              Juno's Do Not Disturb, stay-awake and timezone (once,
#                              in qa/logs/phone_juno_state.txt), then DND on and
#                              screen kept on over USB. Run by session start.
#   phone_standard.ps1 -Juno   Juno's own values back, DND and stay-awake from
#                              that file. Run by session end.
# Juno's values were recorded in M0 (2026-11-22); if they change, change $juno.
param([switch]$Juno)
$ErrorActionPreference = 'Stop'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$env:ANDROID_SERIAL = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phone_serial.txt') -TotalCount 1).Trim()
$state = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\phone_juno_state.txt'

# Both lists undo every toolbox change; they differ only where the plan's
# standard and Juno's phone differ.
$common = @(
  'wm size reset', 'wm density reset',
  'settings put system font_scale 1.0',
  'settings put system accelerometer_rotation 0', 'settings put system user_rotation 0',
  'cmd uimode night yes',
  'cmd connectivity airplane-mode disable', 'svc wifi enable', 'svc data enable',
  'dumpsys deviceidle unforce', 'dumpsys battery reset',
  'am set-inactive com.example.voyager false',
  'settings put global always_finish_activities 0',
  'settings put global auto_time 1', 'settings put global auto_time_zone 1'
)

if ($Juno) {
  # zen_mode 0..3 -> cmd notification set_dnd's names.
  $zen, $stay, $tz = '0', '15', ''
  if (Test-Path -LiteralPath $state) { $zen, $stay, $tz = @(Get-Content -LiteralPath $state) + '' }
  $dnd = @('off', 'priority', 'none', 'alarms')[[int]$zen]
  # auto_time_zone 1 alone took a while to bring the zone back (M0).
  $restore = $common + "settings put global stay_on_while_plugged_in $([int]$stay)", "cmd notification set_dnd $dnd"
  if ($tz -match '^[A-Za-z_]+(/[A-Za-z_+-]+)*$') { $restore += "cmd alarm set-timezone $tz" }
  & $adb shell ($restore -join '; ') | Out-Null
  Remove-Item -LiteralPath $state -ErrorAction SilentlyContinue
} else {
  if (-not (Test-Path -LiteralPath $state)) {
    $now = "$(& $adb shell 'settings get global zen_mode; settings get global stay_on_while_plugged_in; getprop persist.sys.timezone')" -split '\s+' | Where-Object { $_ }
    Set-Content -LiteralPath $state -Value $now -Encoding ascii
  }
  & $adb shell (($common + 'svc power stayon usb', 'cmd notification set_dnd on') -join '; ') | Out-Null
}
& $adb shell 'wm size; wm density; echo font_scale=$(settings get system font_scale) rotation=$(settings get system accelerometer_rotation)/$(settings get system user_rotation) always_finish=$(settings get global always_finish_activities) airplane=$(settings get global airplane_mode_on) zen=$(settings get global zen_mode) stay_on=$(settings get global stay_on_while_plugged_in) tz=$(getprop persist.sys.timezone); cmd uimode night; date'
