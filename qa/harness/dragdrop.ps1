# Phase 7: drag files from a probe-owned window (DragSource.cs) onto Voyager.
#   dragdrop.ps1 -Files <path>[,<path>] -X <clientX> -Y <clientY> [-HoverMs 600]
# X/Y are Voyager client px (same as screenshots). The form opens at the
# bottom-right of the screen; keep Voyager placed away from it (e.g.
# `place 200 100 2000 1100`). Releases only over voyager.exe (see DragSource.cs).
param([Parameter(Mandatory)][string[]]$Files, [Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [int]$HoverMs = 600, [int]$FormX = 2380, [int]$FormY = 1400)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not ('Voy' -as [type])) {
  Add-Type -Path (Join-Path $here 'Probe.cs'), (Join-Path $here 'OtherApp.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
if (-not ('DragSource' -as [type])) {
  Add-Type -Path (Join-Path $here 'DragSource.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
foreach ($f in $Files) { if (-not (Test-Path -LiteralPath $f)) { throw "no such file: $f" } }
$st = [Voy]::Status()
if ($st -notmatch 'rect=(-?\d+),(-?\d+) ') { throw "no Voyager window: $st" }
# Client origin = window rect + border; ask Windows directly.
Add-Type @'
using System; using System.Runtime.InteropServices;
public class DdPt { [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@ -ErrorAction SilentlyContinue
[DdPt]::SetProcessDPIAware() | Out-Null
$hwnd = [IntPtr]([Convert]::ToInt64(($st -replace '^hwnd=0x([0-9A-F]+).*$', '$1'), 16))
$p = New-Object DdPt+P; $p.X = $X; $p.Y = $Y
[DdPt]::ClientToScreen($hwnd, [ref]$p) | Out-Null
$full = @($Files | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
# Raise Voyager so the drop point isn't under another app (DragSource re-checks before releasing).
if (-not [Voy]::Activate()) { throw "activate failed: $([Voy]::Status())" }
$result = [DragSource]::Run($full, $FormX, $FormY, $p.X, $p.Y, $HoverMs)
Write-Output ("drag -> screen {0},{1}: {2}" -f $p.X, $p.Y, $result)
