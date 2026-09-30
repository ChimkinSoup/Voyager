# QA driver for the running Voyager window. See qa/PROGRESS.md "Interaction method".
#
#   voy.ps1 status                      window state (hwnd, visible, fg, topmost, sizes, locked)
#   voy.ps1 activate                    bring Voyager to the foreground
#   voy.ps1 shot <name>                 client-area PNG -> qa/shots/<name>.png
#   voy.ps1 run <steps.txt>             run a scenario file in ONE process (preferred)
#   voy.ps1 do "<step>; <step>; ..."    same, inline
#
# Step language (one per line, or ';'-separated with `do`; '#' starts a comment):
#   activate                   focus Voyager (fails the run if it can't)
#   key <chord>                e.g. key ctrl+slash | key esc | key ctrl+shift+tab | key f5
#   type <text>                real VK typing; \n = Enter. Leading/trailing spaces kept after the first space.
#   click <x> <y> [right] [N]  physical client px (same as screenshot px); N = click count
#   move <x> <y> | wheel <x> <y> <notches> (+up/-down) | drag <x1> <y1> <x2> <y2>
#   hotkey <chord>             global hotkey (only sent if registered), e.g. hotkey ctrl+alt+t
#   wait <ms>                  sleep
#   shot <name>                client-area PNG
#   status                     print window state
#   place <x> <y> <w> <h>      restore + move/resize outer window (physical px)
#   maximize | restore | minimize | close (WM_CLOSE -> hides to tray) | tray-open | tray-quit
# "Another app" (OtherApp.cs, a WinForms form owned by this probe process; lives for the run):
#   other-open [x y w h]       open it topmost, raise it with a real click, then drop topmost
#   other-click [dx dy]        real click on it (centre, or offset from its top-left); guarded
#   other-type <text>          type into its textbox (only while it is foreground)
#   other-topmost on|off | other-close | ostatus (foreground owner, its text, hotkey hits)
#   tray-menu                  open the real tray context menu (posted right-click)
#   other-grab <chord> [id]    register a global hotkey to it (another process owns the combo)
param([Parameter(Position = 0)][string]$Cmd = 'status', [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$shots = Join-Path (Split-Path -Parent $here) 'shots'
New-Item -ItemType Directory -Force $shots | Out-Null
if (-not ('Voy' -as [type])) {
  Add-Type -Path (Join-Path $here 'Probe.cs'), (Join-Path $here 'OtherApp.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

function Invoke-Step([string]$line) {
  $line = $line.Trim()
  if ($line -eq '' -or $line.StartsWith('#')) { return }
  $sp = $line.IndexOf(' ')
  $verb = if ($sp -lt 0) { $line } else { $line.Substring(0, $sp) }
  $arg = if ($sp -lt 0) { '' } else { $line.Substring($sp + 1) }
  $a = @($arg -split '\s+' | Where-Object { $_ -ne '' })
  switch ($verb.ToLowerInvariant()) {
    'activate' { if (-not [Voy]::Activate()) { throw "activate failed: $([Voy]::Status())" } }
    'key' { [Voy]::Chord($arg.Trim()) }
    'type' { [Voy]::Type($arg.Replace('\n', "`n")) }
    'click' {
      $right = $a -contains 'right'
      $n = 1; if ($a.Count -ge 3 -and $a[-1] -match '^\d+$') { $n = [int]$a[-1] }
      [Voy]::Click([int]$a[0], [int]$a[1], $right, $n)
    }
    'move' { [Voy]::Move([int]$a[0], [int]$a[1]) }
    'wheel' { [Voy]::Wheel([int]$a[0], [int]$a[1], [int]$a[2]) }
    'drag' { [Voy]::Drag([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3], 20) }
    'hotkey' { [Voy]::GlobalHotkey($arg.Trim()) }
    'wait' { Start-Sleep -Milliseconds ([int]$a[0]) }
    'shot' {
      $p = Join-Path $shots ($a[0] + '.png')
      if ([Voy]::Shot($p)) { Write-Output "shot: $p" } else { Write-Output "shot FAILED ($($a[0])): $([Voy]::Status())" }
    }
    'status' { Write-Output ([Voy]::Status()) }
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

switch ($Cmd) {
  'run' { foreach ($l in Get-Content -LiteralPath $Rest[0]) { Invoke-Step $l } }
  'do' { foreach ($l in (($Rest -join ' ') -split ';')) { Invoke-Step $l } }
  default { Invoke-Step (($Cmd, ($Rest -join ' ')) -join ' ') }
}
