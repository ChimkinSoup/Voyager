# QA driver for the running Voyager window. See qa/PROGRESS.md "Interaction method".
#
#   voy.ps1 status                      window state (hwnd, visible, fg, topmost, sizes, locked)
#   voy.ps1 activate                    bring Voyager to the foreground
#   voy.ps1 shot <name>                 client-area PNG -> qa/shots/<name>.png
#   voy.ps1 run <steps.txt>             run a scenario file in ONE process (preferred)
#   voy.ps1 do "<step>; <step>; ..."    same, inline
#
# -Profile <name> (else $env:VOYAGER_QA_PROFILE) drives that dev profile's
# window; without one, the normal instance's. Input only ever reaches the one
# voyager.exe picked (by the PID launch.ps1 recorded), never another instance.
#
# Two input modes. Each run starts in bg:
#   bg  Messages posted to Voyager's own window (Bg.cs). No foreground needed, works
#       covered, parked off-screen or locked, can't reach another app. Clicks/drags
#       are instant bursts: no hover, long-press or slow drags (use fg).
#   fg  Real OS input (Probe.cs), refused unless Voyager is the foreground window.
#       Takes over Juno's screen: only for focus/blur, hover, timed gestures,
#       global hotkeys and the "other app" forms.
#
# Step language (one per line, or ';'-separated with `do`; '#' starts a comment):
#   mode bg|fg                 switch input mode for the rest of the run
#   activate                   focus Voyager (fails the run if it can't); switches to fg
#   park | unpark              bg: move the window off-screen (client 2880x1800, same coords
#                              as maximized) / back to (0,0), never activating it
#   key <chord>                e.g. key ctrl+slash | key esc | key ctrl+shift+tab | key f5
#   type <text>                real VK typing; \n = Enter. Leading/trailing spaces kept after the first space.
#   click <x> <y> [right] [N]  physical client px (same as screenshot px); N = click count
#   tap <query> [#N] [right]   click the N-th clickable widget whose whole label is <query>:
#                              Text, tip:<tooltip> or key:<ValueKey value> (vm.ps1 locate)
#   find [query]               list on-screen texts/tooltips/keys with centre coords (vm.ps1 find)
#   field                      focused text field: selection|vimMode|length|text (vm.ps1 field)
#   move <x> <y> | wheel <x> <y> <notches> (+up/-down) | drag <x1> <y1> <x2> <y2> [holdMs]
#                              holdMs (fg only): press and hold that long before moving
#                              drag ... <holdMs> <endHoldMs> (fg only): also hold at the end before release
#   hotkey <chord>             fg: global hotkey (only sent if registered), e.g. hotkey ctrl+alt+t
#   wait <ms>                  sleep
#   at <unix-ms>               sleep until that instant (together.ps1 releases two runs at once)
#   shot <name>                client-area PNG (bg: VM-service frame grab; fg: PrintWindow)
#   status                     print window state
#   place <x> <y> <w> <h>      fg: restore + move/resize outer window (physical px)
#   maximize | restore | minimize (fg) | close (WM_CLOSE -> hides to tray) | tray-open | tray-quit (fg)
# "Another app" (OtherApp.cs, a WinForms form owned by this probe process; lives for the run):
#   other-open [x y w h]       open it topmost, raise it with a real click, then drop topmost
#   other-click [dx dy]        real click on it (centre, or offset from its top-left); guarded
#   other-type <text>          type into its textbox (only while it is foreground)
#   other-topmost on|off | other-close | ostatus (foreground owner, its text, hotkey hits)
#   otherb-open x y w h | otherb-click [dx dy] | otherb-close   a second probe form "B" (FV-7)
#   zorder                     top-to-bottom order of form A, form B and Voyager's main window
#   tray-menu                  fg: open the real tray context menu (posted right-click; activates Voyager)
#   other-grab <chord> [id]    register a global hotkey to it (another process owns the combo)
param([Parameter(Position = 0)][string]$Cmd = 'status', [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest, [string]$Profile)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$shots = Join-Path (Split-Path -Parent $here) 'shots'
New-Item -ItemType Directory -Force $shots | Out-Null
if (-not ('Bg' -as [type])) {
  Add-Type -Path (Join-Path $here 'Probe.cs'), (Join-Path $here 'OtherApp.cs'), (Join-Path $here 'Bg.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
$vm = Join-Path $here 'vm.ps1'
. (Join-Path $here 'instance.ps1')
$inst = Get-QaInstance $Profile
$procs = @(Get-QaProcess $inst)
if ($procs.Count -gt 1) { throw "more than one voyager.exe could be $($inst.Label) ($($procs.Id -join ', ')): stop the extras, or relaunch with launch.ps1" }
# -1 matches no process: with this instance not running, nothing is driven.
[Voy]::TargetPid = if ($procs.Count -eq 1) { $procs[0].Id } else { -1 }
$script:mode = 'bg'
$fgOnly = @('hotkey', 'place', 'maximize', 'restore', 'minimize', 'other-open', 'other-click', 'other-type', 'other-topmost',
  'otherb-open', 'otherb-click', 'zorder', 'other-grab', 'tray-open', 'tray-menu', 'tray-quit')

# Runs vm.ps1 and fails the run on a non-zero exit (stale vm_uri.txt, eval error, capture timeout).
function Invoke-Vm {
  $out = @(& $vm -Profile $inst.Arg @args)
  if ($LASTEXITCODE -ne 0) { throw "vm.ps1 $($args[0]): $($out -join "`n")" }
  $out
}

function Invoke-Step([string]$line) {
  $line = $line.Trim()
  if ($line -eq '' -or $line.StartsWith('#')) { return }
  $sp = $line.IndexOf(' ')
  $verb = if ($sp -lt 0) { $line } else { $line.Substring(0, $sp) }
  $arg = if ($sp -lt 0) { '' } else { $line.Substring($sp + 1) }
  $a = @($arg -split '\s+' | Where-Object { $_ -ne '' })
  $verb = $verb.ToLowerInvariant()
  if ($script:mode -eq 'bg' -and $fgOnly -contains $verb) { throw "'$verb' needs real input or activates the window: add 'mode fg' (takes Juno's screen) before it" }
  $bg = $script:mode -eq 'bg'
  switch ($verb) {
    'mode' {
      if ($a[0] -ne 'bg' -and $a[0] -ne 'fg') { throw "mode must be bg or fg: $line" }
      $script:mode = $a[0]
    }
    'activate' { $script:mode = 'fg'; if (-not [Voy]::Activate()) { throw "activate failed: $([Voy]::Status())" } }
    'park' { [Bg]::Park() }
    'unpark' { [Bg]::Unpark() }
    'key' { if ($bg) { [Bg]::Chord($arg.Trim()) } else { [Voy]::Chord($arg.Trim()) } }
    'type' { if ($bg) { [Bg]::Type($arg.Replace('\n', "`n")) } else { [Voy]::Type($arg.Replace('\n', "`n")) } }
    'click' {
      $right = $a -contains 'right'
      $n = 1; if ($a.Count -ge 3 -and $a[-1] -match '^\d+$') { $n = [int]$a[-1] }
      if ($bg) { [Bg]::Click([int]$a[0], [int]$a[1], $right, $n) } else { [Voy]::Click([int]$a[0], [int]$a[1], $right, $n) }
    }
    'tap' {
      $q = $arg.Trim(); $n = 1; $right = $false
      if ($q -match '\s+right$') { $right = $true; $q = $q -replace '\s+right$', '' }
      if ($q -match '\s+#(\d+)$') { $n = [int]$Matches[1]; $q = $q -replace '\s+#\d+$', '' }
      $q = $q.Trim('"', "'")
      $out = @(& $vm -Profile $inst.Arg locate $n $q)
      if ($LASTEXITCODE -ne 0) { throw "tap: $($out -join "`n")" }
      $xy = $out[-1].Split(' ')
      if ($bg) { [Bg]::Click([int]$xy[0], [int]$xy[1], $right, 1) } else { [Voy]::Click([int]$xy[0], [int]$xy[1], $right, 1) }
      Write-Output "tap '$q' #$n at $($out[-1])"
    }
    'find' { Invoke-Vm find $arg.Trim().Trim('"', "'") }
    'field' { Invoke-Vm field }
    'move' { if ($bg) { [Bg]::Move([int]$a[0], [int]$a[1]) } else { [Voy]::Move([int]$a[0], [int]$a[1]) } }
    'wheel' { if ($bg) { Invoke-Vm scroll $a[0] $a[1] $a[2] | Out-Null; Start-Sleep -Milliseconds 150 } else { [Voy]::Wheel([int]$a[0], [int]$a[1], [int]$a[2]) } }
    'drag' { $hold = if ($a.Count -gt 4) { [int]$a[4] } else { 0 }; $endHold = if ($a.Count -gt 5) { [int]$a[5] } else { 60 }; if ($bg) { if ($hold) { throw 'drag holdMs needs mode fg: bg presses are cancelled by WM_MOUSELEAVE' }; [Bg]::Drag([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3], 20) } else { [Voy]::Drag([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3], 20, $hold, $endHold) } }
    'hotkey' { [Voy]::GlobalHotkey($arg.Trim()) }
    'wait' { Start-Sleep -Milliseconds ([int]$a[0]) }
    'at' {
      # MD-3: sleep until a wall-clock instant (Unix ms), so two runs (together.ps1) start together.
      $ms = [int64]$a[0] - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
      Write-Output "at: released $([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    }
    'shot' {
      $p = Join-Path $shots ($a[0] + '.png')
      if ($bg) { Invoke-Vm shot $p }
      elseif ([Voy]::Shot($p)) { Write-Output "shot: $p" } else { Write-Output "shot FAILED ($($a[0])): $([Voy]::Status())" }
    }
    'status' { Write-Output ("mode=$($script:mode) " + [Voy]::Status()) }
    'place' { [Voy]::Place([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3]) }
    'maximize' { [Voy]::Maximize() }
    'restore' { [Voy]::Restore() }
    'close' { [Voy]::Close() }
    'tray-open' { [Voy]::Tray($true) }
    'tray-quit' { [Voy]::TrayQuit() }
    'minimize' { [Other]::MinimizeVoyager() }
    'other-open' {
      if ($a.Count -ge 4) { [Other]::Open([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3], $true) } else { [Other]::Open(60, 60, 900, 500, $true) }
      [Other]::Click(-1, -1); Start-Sleep -Milliseconds 200; [Other]::SetTopmost($false)
      Write-Output ([Other]::Status())
    }
    'other-click' { if ($a.Count -ge 2) { [Other]::Click([int]$a[0], [int]$a[1]) } else { [Other]::Click(-1, -1) } }
    'other-type' { [Other]::Type($arg.Replace('\n', "`n")) }
    'other-topmost' { [Other]::SetTopmost($a[0] -eq 'on') }
    'other-close' { [Other]::Close() }
    'otherb-open' {
      [OtherB]::Open([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3])
      [OtherB]::Click(-1, -1); Start-Sleep -Milliseconds 200; [OtherB]::SetTopmost($false)
    }
    'otherb-click' { if ($a.Count -ge 2) { [OtherB]::Click([int]$a[0], [int]$a[1]) } else { [OtherB]::Click(-1, -1) } }
    'otherb-close' { [OtherB]::Close() }
    'zorder' { Write-Output ([ZOrder]::Of()) }
    'ostatus' { Write-Output ([Other]::Status()); Write-Output ([Voy]::Status()); Write-Output ([Other]::Menu()) }
    'tray-menu' { [Voy]::Tray($false) }
    'other-grab' {
      $mods = 0; $key = 0
      foreach ($p in $a[0].Split('+')) { switch ($p.ToLowerInvariant()) { 'ctrl' { $mods = $mods -bor 2 } 'alt' { $mods = $mods -bor 1 } 'shift' { $mods = $mods -bor 4 } default { $key = [Voy]::VkFor($p) } } }
      $id = if ($a.Count -ge 2) { [int]$a[1] } else { 77 }
      Write-Output ("other-grab " + $a[0] + ": " + [Other]::Grab([uint32]$mods, [uint32]$key, $id))
    }
    default { throw "unknown step: $line" }
  }
}

[Bg]::KeepAwake()
switch ($Cmd) {
  'run' { foreach ($l in Get-Content -LiteralPath $Rest[0]) { Invoke-Step $l } }
  'do' { foreach ($l in (($Rest -join ' ') -split ';')) { Invoke-Step $l } }
  default { Invoke-Step (($Cmd, ($Rest -join ' ')) -join ' ') }
}
